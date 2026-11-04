import {createClient} from 'npm:@supabase/supabase-js@2.118.0';
import * as lib from 'npm:libxml2-wasm@0.7.2';
import {schemaManifest,schemaFiles} from './schema-bundle.mjs';
import {validateOperation,validateXmlAgainstSource,sha256,exact,canonical} from './core.mjs';
const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const origins=(Deno.env.get('COREAML_FILING_ORIGINS')||'http://127.0.0.1:5520,http://localhost:5520').split(',').map(x=>x.trim()).filter(Boolean);
const headers=(origin:string)=>({'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin','Content-Type':'application/json','Cache-Control':'no-store'});
// Validation is synchronous after schema files have loaded. No await occurs while global XML IO is registered.
async function schemaProfile(tenant:string,mode:string){
 const manifest=schemaManifest;
 const profile=manifest.profiles?.find((p:any)=>p.tenant_id===tenant&&p.mode===mode);
 if(!profile)throw Error('No schema profile is configured for this bank and mode.');
 if(mode==='LIVE'&&Deno.env.get('COREAML_FILING_ALLOW_LIVE')!=='true')throw Error('Live report export is not enabled.');
 const files:Record<string,string>={};let size=0;
 for(const [name,hash]of Object.entries(profile.files||{})){
  if(!/^[A-Za-z0-9_./-]+\.xsd$/.test(name)||name.includes('..')||name.startsWith('/')||Object.keys(files).length>=20)throw Error('Invalid schema bundle path.');
  const text=(schemaFiles as Record<string,string>)[name];if(typeof text!=='string')throw Error('Schema file is not in the generated bundle. Run the schema bundling script.');size+=new TextEncoder().encode(text).length;
  if(size>4194304||await sha256(text)!==hash||/<!DOCTYPE|<!ENTITY/i.test(text))throw Error('Schema bundle hash, size or content check failed.');files[name]=text;
 }
 if(!files[profile.entry])throw Error('Schema entry file is missing.');
 const hash=await sha256(JSON.stringify(Object.entries(profile.files).sort()));
 return {profile,files,hash};
}
Deno.serve(async req=>{
 const origin=req.headers.get('Origin')||'';if(!origins.includes(origin))return new Response(JSON.stringify({error:'Origin not allowed'}),{status:403,headers:{'Content-Type':'application/json'}});
 const reply=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:headers(origin)});
 if(req.method==='OPTIONS')return reply({});if(req.method!=='POST')return reply({error:'POST required',definitive:true},405);
 let uncertain=false;
 try{
  const token=req.headers.get('Authorization')||'';if(!/^Bearer \S+$/.test(token))return reply({error:'Sign in required',definitive:true},401);
  const userClient=createClient(url,anon,{global:{headers:{Authorization:token}},auth:{persistSession:false}});
  const {data:auth,error:authError}=await userClient.auth.getUser();if(authError||!auth?.user)return reply({error:'Sign in required',definitive:true},401);
  // Bound the body while streaming; do not trust Content-Length.
  const reader=req.body?.getReader();let bytes=0,raw='';const decoder=new TextDecoder();if(reader){while(true){const {value,done}=await reader.read();if(done)break;bytes+=value.length;if(bytes>1200000){await reader.cancel();throw Error('Report request exceeds size limit.');}raw+=decoder.decode(value,{stream:true});}raw+=decoder.decode();}
  const b=validateOperation(JSON.parse(raw));
  const {data:ctx,error:readError}=await userClient.rpc('coreaml_filing_read_v2',{p_report_id:b.report_id,p_offset:0,p_case_reference:null,p_queue:'ALL'});
  if(readError||!ctx||ctx.actor_id!==auth.user.id||ctx.source?.report_id!==b.report_id)throw Error('Authorized approved report required.');
  if(b.action==='PROFILE'){
   exact(b.payload,['mode']);const {profile}=await schemaProfile(ctx.tenant_id,b.payload.mode);
   return reply({actor_id:ctx.actor_id,tenant_id:ctx.tenant_id,mode:profile.mode,rentity_id:profile.rentity_id,currency:profile.currency,label:profile.label,authority:profile.authority});
  }
  const officerAction=['SAVE','SUBMIT_REPORT'].includes(b.action),headAction=['APPROVE_REPORT','RETURN_REPORT','CONFIRM_OUTCOME'].includes(b.action);
  if(officerAction?(ctx.role!=='compliance_officer'||ctx.source.owner_id!==auth.user.id):headAction?ctx.role!=='head_of_compliance':!['head_of_compliance','compliance_officer'].includes(ctx.role))throw Error(officerAction?'Assigned preparing officer required.':headAction?'Independent Head of Compliance action required.':'Authorized reporting user required.');
  const admin=createClient(url,key,{auth:{persistSession:false}});
  const clientHash=await sha256(JSON.stringify(canonical(b)));
  const {data:previous,error:receiptError}=await admin.rpc('coreaml_filing_receipt',{p_actor:auth.user.id,p_report_id:b.report_id,p_request_id:b.request_id,p_client_hash:clientHash});
  if(receiptError){uncertain=!/^(?:[0-9A-Z]{5}|PGRST\d+)$/.test(receiptError.code||'');throw Error('Request receipt could not be confirmed.');}
  if(previous)return reply(previous);
  if(b.source_hash!==ctx.source_hash||(ctx.draft?.revision||0)!==b.revision)throw Error('Source or reporting revision changed. Reload the saved report.');
  let payload=b.payload,exportXml:string|undefined;
  if(b.action==='SAVE'&&payload.mode==='LIVE'&&Deno.env.get('COREAML_FILING_ALLOW_LIVE')!=='true')throw Error('Live preparation is not enabled.');
  if(['EXPORT','SUBMIT_REPORT','APPROVE_REPORT'].includes(b.action)){
   if(!ctx.draft)throw Error('Save a reporting preparation first.');
   const {profile,files,hash}=await schemaProfile(ctx.tenant_id,ctx.draft.mode);
   validateXmlAgainstSource(ctx.draft.xml_content,ctx.draft,ctx.source,profile,lib,files);
   const savedXml=ctx.draft.xml_content;if(b.action==='EXPORT')exportXml=savedXml;
   payload={...b.payload,xml_hash:await sha256(savedXml),schema_hash:hash,schema_label:profile.label};
  }
  payload={...payload,client_request_hash:clientHash};
  uncertain=true;
  const {data:ack,error}=await admin.rpc('coreaml_filing_commit',{p_actor:auth.user.id,p_report_id:b.report_id,p_request_id:b.request_id,p_action:b.action,p_revision:b.revision,p_source_hash:b.source_hash,p_payload:payload});
  if(error){uncertain=!/^(?:[0-9A-Z]{5}|PGRST\d+)$/.test(error.code||'');throw Error(error.message||'Reporting operation was not confirmed.');}
  if(!ack||ack.request_id!==b.request_id||ack.actor_id!==auth.user.id||ack.report_id!==b.report_id)throw Error('Reporting acknowledgement was not confirmed.');
  uncertain=false;
  return reply({...ack,...(exportXml?{xml:exportXml,xml_hash:payload.xml_hash}:{} )});
 }catch(error){
  // Errors may include report field values from the XML engine. Do not log report contents.
  const message=String(error instanceof Error?error.message:'Reporting operation failed').slice(0,1500);
  return reply({error:message,definitive:!uncertain},400);
 }
});
