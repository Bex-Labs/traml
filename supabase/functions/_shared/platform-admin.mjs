// The user-scoped client authorizes/reserves each request; service credentials never reach the browser.
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(v);
export function createPlatformAdminHandler({createClient,env,kind}){
 return async req=>{
  const origin=req.headers.get('origin'),configured=(env('COREAML_APP_ORIGINS')||'http://127.0.0.1:5520,http://localhost:5520').split(',').map(x=>x.trim()).filter(Boolean);
  const headers={'content-type':'application/json','vary':'Origin','access-control-allow-headers':'authorization,apikey,content-type,x-client-info','access-control-allow-methods':'POST, OPTIONS'};
  if(origin&&configured.includes(origin))headers['access-control-allow-origin']=origin;
  const reply=(body,status=200)=>new Response(JSON.stringify(body),{status,headers});
  if(origin&&!configured.includes(origin))return reply({error:'Origin not allowed'},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});if(req.method!=='POST')return reply({error:'POST required'},405);
  let reserved=null;
  try{
   const authorization=req.headers.get('authorization');if(!/^Bearer\s+\S+$/i.test(authorization||''))return reply({error:'Authentication required'},401);
   const url=env('SUPABASE_URL'),anon=env('SUPABASE_ANON_KEY'),secret=env('SUPABASE_SERVICE_ROLE_KEY');if(!url||!anon||!secret)throw Error('Server configuration unavailable');
   const client=createClient(url,anon,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
   const auth=await client.auth.getUser();if(auth.error||!auth.data?.user?.id)return reply({error:'Authentication required'},401);
   const actor=auth.data.user.id,body=await req.json(),requestId=body.request_id;
   if(!uuid(requestId))return reply({error:'A retained request_id is required'},400);
   let action,payload;
   if(kind==='invite'){
    action='INVITE';payload={email:String(body.email||'').trim().toLowerCase(),role:body.role,tenant_id:body.tenantId||null};
   }else{
    if(!['deactivate','restore'].includes(body.action))return reply({error:'Supported actions are deactivate and restore. Password recovery uses the sign-in recovery flow; no recovery email was sent.'},400);
    if(!uuid(body.targetUserId))return reply({error:'Valid target user required'},400);
    action=body.action.toUpperCase();payload={target_id:body.targetUserId};
   }
   if(action==='INVITE'&&(!env('COREAML_APP_URL')||!/^https?:\/\//.test(env('COREAML_APP_URL'))))return reply({error:'Set COREAML_APP_URL before inviting users. No invitation was sent.',code:'CONFIG_REQUIRED'},400);
   const reservation=await client.rpc('coreaml_admin_reserve',{p_action:action,p_payload:payload,p_request_id:requestId});
   if(reservation.error)return reply({error:reservation.error.message||'Not authorized',code:reservation.error.code},reservation.error.code==='42501'?403:409);
   reserved=reservation.data;
   if(reserved?.request_id!==requestId||reserved.actor_id!==actor||reserved.action!==action)return reply({error:'Reservation was not confirmed'},409);
   if(reserved.state==='COMPLETED')return reply({...reserved.result,replayed:true});
   if(!reserved.dispatch)return reply({error:'The earlier invitation is unconfirmed. Inspect Requests and the Auth user directory before taking further action. The invitation was not resent.',request_id:requestId,state:reserved.state},409);
   const admin=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
   let target=reserved.target_id;
   if(action==='INVITE'){
    // No repeated email when a response was lost. Once the Auth identity is journalled, provisioning can resume.
    if(!target){
     const redirect=env('COREAML_APP_URL');if(!redirect||!/^https?:\/\//.test(redirect))return reply({error:'Set COREAML_APP_URL to your frontend origin before inviting users. No invitation was sent.'},503);
     const invite=await admin.auth.admin.inviteUserByEmail(payload.email,{redirectTo:redirect.replace(/\/$/,'')+'/setup-account.html',data:{}});
     if(invite.error||!invite.data?.user?.id)return reply({error:'Invitation outcome not confirmed. Check Requests and Auth before retrying with another request.',request_id:requestId,state:'UNCONFIRMED'},409);
     target=invite.data.user.id;
     const checkpoint=await admin.rpc('coreaml_admin_auth_checkpoint',{p_actor:actor,p_request_id:requestId,p_target:target});if(checkpoint.error)throw Error('Auth identity was created but its checkpoint is unconfirmed');
    }
    const provision=await admin.auth.admin.updateUserById(target,{app_metadata:{role:payload.role,tenant_id:payload.tenant_id}});if(provision.error)throw Error('Identity exists but trusted role provisioning is unconfirmed');
   }else{
    const update=await admin.auth.admin.updateUserById(target,{ban_duration:action==='DEACTIVATE'?'876000h':'none'});if(update.error)throw Error('Auth access update unconfirmed; inspect Requests');
   }
   const finished=await admin.rpc('coreaml_admin_finish',{p_actor:actor,p_request_id:requestId});
   if(finished.error||finished.data?.request_id!==requestId||finished.data?.actor_id!==actor||finished.data?.target_id!==target||finished.data?.state!=='COMPLETED')throw Error('Auth action may have completed; database confirmation is unconfirmed. Inspect Requests and retry the exact request.');
   return reply(finished.data);
  }catch{return reply({error:reserved?'Administration outcome unconfirmed. Inspect Requests and retry only the same request.':'Administration request could not be completed.',request_id:reserved?.request_id||null},503);}
 };
}
