import {supabase} from '../config.js';
// Page routing uses the same active-profile/trusted-claim boundary as the server RPCs.
async function resolveSession(){
 let {data:{session},error}=await supabase.auth.getSession();if(error||!session)return null;
 const verified=await supabase.auth.getUser();if(verified.error||verified.data?.user?.id!==session.user.id)throw Error('Session identity could not be verified. Sign in again.');
 let {data:c,error:denied}=await supabase.rpc('coreaml_dashboard_context');
 if(denied&&typeof supabase.auth.refreshSession==='function'){const refreshed=await supabase.auth.refreshSession();if(!refreshed.error&&refreshed.data?.session?.user?.id===verified.data.user.id){session=refreshed.data.session;const retry=await supabase.rpc('coreaml_dashboard_context');c=retry.data;denied=retry.error;}}
 if(denied||c?.actor_id!==session.user.id||!c.role||(c.role!=='it_admin'&&!c.tenant_id))throw Error('Active matching staff profile required. Refresh your session or contact the administrator.');
 return {session,user:verified.data.user,role:c.role,tenantId:c.tenant_id,name:c.name};
}
export async function getVerifiedSession(timeout=15000){let timer;try{return await Promise.race([resolveSession(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Session verification timed out. Retry sign-in.')),timeout);})]);}finally{clearTimeout(timer);}}
export async function logout(){try{await supabase.rpc('log_user_logout');}finally{const {error}=await supabase.auth.signOut();if(error)throw error;}}
