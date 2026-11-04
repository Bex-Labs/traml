'use strict';
// Provision one dedicated synthetic local test identity through Auth Admin.
// No invitation, email send, hosted request, password export or role reassignment
// for an unrelated identity. Repeat runs reuse only this marked fixture.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {randomBytes}=require('node:crypto');
const {spawnSync}=require('node:child_process');
const {ROOT,DB,API,BANK,run,query,assertLocal,lit}=require('./aml-compatible-db.cjs');
const EMAIL='case_claim_peer@coreaml-local.test',MARKER='coreaml_case_claim_peer_v1';
const read=sql=>query('BEGIN TRANSACTION READ ONLY;'+sql+'COMMIT;');
const uuid=x=>typeof x==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(x);
function isAdminKey(value){
 if(typeof value!=='string'||/[\s${}]/.test(value))return false;
 if(/^sb_secret_[A-Za-z0-9_-]+$/.test(value))return true;
 try{return JSON.parse(Buffer.from(value.split('.')[1],'base64url').toString()).role==='service_role'&&value.split('.').length===3;}catch{return false;}
}
function extractAdminKey(environment,yaml=''){
 const env=Object.fromEntries(environment.map(value=>{const index=value.indexOf('=');return [value.slice(0,index),value.slice(index+1)];}));
 for(const key of ['SUPABASE_SERVICE_KEY','SUPABASE_SERVICE_ROLE_KEY','SERVICE_ROLE_KEY','SUPABASE_SECRET_KEY'])if(isAdminKey(env[key]))return env[key];
 // Only inspect credentials attached to the named service_role consumer.
 const lines=yaml.split(/\r?\n/);let active=false,indent=-1;
 for(const line of lines){
  const consumer=line.match(/^(\s*)-\s*username:\s*["']?([^"'\s#]+)["']?\s*$/);
  if(consumer){if(active&&consumer[1].length===indent)break;active=consumer[2]==='service_role';indent=consumer[1].length;continue;}
  if(active&&line.trim()&&line.match(/^\S/))break;
  if(active){const key=line.match(/^\s*-?\s*key:\s*["']?([^"'\s#]+)["']?\s*$/);if(key&&isAdminKey(key[1]))return key[1];}
 }
 throw Error('Configured local Admin credential unavailable; no account creation was attempted. Do not share keys in chat.');
}
function statusAdminKey(invoke){
 const help=invoke(['--help']);if(!/\bstatus\b/.test(help))throw Error('Installed CLI does not advertise local status');
 const statusHelp=invoke(['status','--help']);
 if(!statusHelp.includes('--output')||!/\bjson\b/.test(statusHelp))throw Error('Installed CLI does not advertise JSON status output');
 let status;try{status=JSON.parse(invoke(['status','--output','json']).replace(/^\uFEFF/,''));}catch{throw Error('Local CLI status did not return valid JSON; no account creation attempted');}
 const reported=status.API_URL||status.api_url;
 if(typeof reported!=='string'||reported.replace(/\/$/,'')!==API)throw Error('CLI status is not the sentinel-aml API on port 55321; refusing its credentials');
 for(const name of ['SERVICE_ROLE_KEY','SECRET_KEY','service_role_key','secret_key'])if(isAdminKey(status[name]))return status[name];
 throw Error('Local CLI status did not contain a recognized Admin credential; do not share its output or keys');
}
function cliAdminKey(){
 // Launch binaries or installed JS entry points directly: no shell interpolation or downloads.
 const executables=[path.join(ROOT,'node_modules/supabase/bin/supabase.exe'),path.join(ROOT,'node_modules/supabase/bin/supabase'),path.join(ROOT,'.coreaml-test-tools/node_modules/supabase/bin/supabase.exe'),path.join(ROOT,'.coreaml-test-tools/node_modules/supabase/bin/supabase'),'supabase'];
 const candidates=executables.map(command=>({command,prefix:[]}));
 const scripts=[path.join(ROOT,'node_modules/supabase/dist/supabase.js'),path.join(ROOT,'.coreaml-test-tools/node_modules/supabase/dist/supabase.js')];
 if(process.env?.APPDATA)scripts.push(path.join(process.env.APPDATA,'npm/node_modules/supabase/dist/supabase.js'));
 candidates.unshift(...scripts.filter(file=>fs.existsSync(file)).map(file=>({command:process.execPath,prefix:[file]})));
 const npmCLI=path.join(path.dirname(process.execPath),'node_modules/npm/bin/npm-cli.js');
 if(fs.existsSync(npmCLI))candidates.push({command:process.execPath,prefix:[npmCLI,'exec','--offline','--no','--','supabase']});
 for(const candidate of candidates){
  const invoke=args=>{
   const result=spawnSync(candidate.command,[...candidate.prefix,...args],{cwd:ROOT,encoding:'utf8',timeout:20000,maxBuffer:2*1024*1024,windowsHide:true});
   if(result.error)throw Error('Local CLI unavailable');
   if(result.status!==0){
    // Some CLI versions still emit valid status JSON when an optional service is stopped.
    if(args[0]!=='status'||!args.includes('json'))throw Error('Local CLI help unavailable');
    try{JSON.parse(result.stdout);}catch{throw Error('Local CLI status unavailable');}
   }
   return result.stdout;
  };
  try{return statusAdminKey(invoke);}catch{ /* Never print CLI output: it can contain credentials. */ }
 }
 throw Error('No installed or cached CLI provided verified local Admin credentials. Run supabase --help and share only the help output, never status output or keys.');
}
function accountMatches(account){return account&&uuid(account.id)&&account.email===EMAIL
 &&account.metadata?.fixture===MARKER&&account.metadata?.role==='compliance_officer'&&account.metadata?.tenant_id===BANK;}
function account(){return JSON.parse(read(`SELECT coalesce((SELECT jsonb_build_object('id',id,'email',email,'metadata',raw_app_meta_data) FROM auth.users WHERE lower(email)=lower(${lit(EMAIL)})),'null'::jsonb)::text;`));}
function peers(){return JSON.parse(read(`SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) FROM (SELECT p.id,u.email FROM public.user_profiles p JOIN auth.users u ON u.id=p.id WHERE p.tenant_id=${lit(BANK)} AND p.role='compliance_officer' AND p.is_active IS TRUE AND u.email LIKE '%@coreaml-local.test' ORDER BY p.id) p;`));}
function fingerprint(excluded){return read(`SELECT md5(jsonb_build_object(
 'profiles',(SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.user_profiles p WHERE id<>${lit(excluded)}::uuid),
 'alerts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.alerts a),
 'customers',(SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM public.customers c),
 'accounts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.accounts a),
 'transactions',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.transactions t),
 'risk',(SELECT jsonb_agg(to_jsonb(h) ORDER BY id) FROM public.risk_score_history h)
 )::text);`);}
function profileSQL(id){
 assert(uuid(id));
 return `BEGIN;
 DO $identity$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id=${lit(id)}::uuid AND email=${lit(EMAIL)}
  AND raw_app_meta_data->>'fixture'=${lit(MARKER)} AND raw_app_meta_data->>'tenant_id'=${lit(BANK)}
  AND raw_app_meta_data->>'role'='compliance_officer') THEN RAISE EXCEPTION 'Fixture identity mismatch; refusing profile change'; END IF;
 END $identity$;
 INSERT INTO public.user_profiles(id,tenant_id,role,full_name,is_active)
 VALUES (${lit(id)}::uuid,${lit(BANK)},'compliance_officer','Synthetic case claim peer',true)
 ON CONFLICT (id) DO UPDATE SET tenant_id=excluded.tenant_id,role=excluded.role,full_name=excluded.full_name,is_active=excluded.is_active;
 COMMIT;`;
}
async function main(){
 assertLocal();assert.equal(DB,'supabase_db_sentinel-aml');assert.equal(API,'http://127.0.0.1:55321');
 let candidates=peers();assert(candidates.some(p=>p.email==='compliance_officer@coreaml-local.test'),'Primary synthetic officer unavailable');
 let current=account(),created=false;
 if(candidates.length<2){
  if(current&&!accountMatches(current))throw Error('The fixture email belongs to an unrecognized identity; no account or role changed.');
  const before=fingerprint(current?.id||'00000000-0000-0000-0000-000000000000');
  if(!current){
   const details=JSON.parse(run('docker',['inspect','supabase_kong_sentinel-aml']))[0];
   let key;
   try{key=extractAdminKey(details.Config?.Env||[]);}catch{
    try{const yaml=run('docker',['exec','supabase_kong_sentinel-aml','cat','/home/kong/kong.yml']);key=extractAdminKey(details.Config?.Env||[],yaml);}
    catch{key=cliAdminKey();}
   }
   const health=await fetch(API+'/auth/v1/health',{redirect:'error',signal:AbortSignal.timeout(10000)});assert.equal(health.status,200,'Local Auth health failed');await health.body?.cancel();
   // Random password stays in process memory; the peer is used by database-role tests.
   const response=await fetch(API+'/auth/v1/admin/users',{method:'POST',redirect:'error',signal:AbortSignal.timeout(15000),headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({email:EMAIL,password:'CaseTest!'+randomBytes(32).toString('base64url'),email_confirm:true,app_metadata:{fixture:MARKER,role:'compliance_officer',tenant_id:BANK},user_metadata:{full_name:'Synthetic case claim peer'}})});
   key=undefined;
   if(!response.ok){await response.body?.cancel();throw Error('Local Auth Admin returned HTTP '+response.status+'; preserve this output. No existing account was reassigned.');}
   await response.body?.cancel();created=true;current=account();
  }
  assert(accountMatches(current),'Marked test account could not be verified; no profile change attempted');
  query(profileSQL(current.id));assert.equal(fingerprint(current.id),before,'Existing profiles, alerts or financial state changed; inspect before proceeding');candidates=peers();
 }
 assert(candidates.length>=2,'A second active same-bank test officer is still unavailable');
 const peer=candidates.find(p=>p.email!== 'compliance_officer@coreaml-local.test');assert(peer&&uuid(peer.id));
 const report={generated_at:new Date().toISOString(),scope:'Local case concurrency test identity readiness',ready:true,created,peer_id:peer.id,fixture_email:peer.email,limitations:['Only the sentinel-aml local stack was used.','Dedicated marked peer accounts are retained; their random passwords and Admin credentials are not exported.','No acceptance alerts, deposits, claims, evaluations or filings were created by this setup.']};
 const output=path.join(ROOT,'.coreaml-local/case-claim-peer-setup.json');fs.mkdirSync(path.dirname(output),{recursive:true});if(fs.existsSync(output))fs.copyFileSync(output,output.replace(/\.json$/,'-before-'+Date.now()+'.json'));fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');
 console.log(created?'Dedicated local synthetic peer created and verified.':'Existing local synthetic peer verified.');console.log('Two active same-bank synthetic officers are available.');console.log('Report: .coreaml-local/case-claim-peer-setup.json');
}
if(require.main===module)main().catch(error=>{const detail=String(error.message).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g,'[JWT removed]').replace(/sb_secret_[\w-]+/g,'[secret removed]').slice(0,700);console.error('Local peer setup did not complete: '+detail);console.error('No keys or passwords were exported. Unrelated accounts were not reassigned. Do not rerun acceptance yet; share this output.');process.exitCode=1;});
module.exports={extractAdminKey,statusAdminKey,accountMatches,profileSQL,EMAIL,MARKER,main};
