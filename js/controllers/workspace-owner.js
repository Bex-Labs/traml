// Display only. The draft's server-confirmed read_only flag remains authoritative.
const uuid=v=>typeof v==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(v);
export async function resolveWorkspaceOwner(client,draft,timeout=4000){
 const id=uuid(draft.owner_id)?draft.owner_id:null;
 const fallback={id,label:id?'Assigned officer · '+id:'Assigned officer unavailable'};
 if(!id||!uuid(draft.tenant_id))return fallback;
 const abort=new AbortController();let timer;
 try{
  const result=await Promise.race([
   Promise.resolve().then(()=>client.from('user_profiles').select('id,tenant_id,full_name').eq('id',id).eq('tenant_id',draft.tenant_id).limit(1).abortSignal(abort.signal)),
   new Promise((_,reject)=>{timer=setTimeout(()=>{abort.abort();reject(Error('Owner label unavailable'));},timeout);})
  ]);
  const p=result.data?.[0];
  if(result.error||!p||p.id!==id||p.tenant_id!==draft.tenant_id||typeof p.full_name!=='string'||!p.full_name.trim())return fallback;
  return {id,label:p.full_name.trim().slice(0,200)};
 }catch{return fallback;}finally{clearTimeout(timer);}
}
export function renderWorkspaceOwner(document,owner,draft){
 document.getElementById('inv-header-officer').textContent=owner.label;
 let notice=document.getElementById('iw-access-notice');
 if(!notice){notice=document.createElement('p');notice.id='iw-access-notice';notice.setAttribute('role','status');document.getElementById('inv-header-officer').closest('.card-body').append(notice);}
 notice.hidden=!draft.read_only;
 notice.textContent=draft.case_status==='CLOSED'?'Closed case · read-only. Recorded owner: '+owner.label+'.':'Read-only investigation · recorded owner: '+owner.label+'. Viewing this case does not transfer ownership. Decisions on submitted packages are made in the review queues.';
}
