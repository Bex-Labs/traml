// Complete bounded reads. Never present a truncated page as a bank-wide total.
export function createAnalyticsService(client,getContext,{timeout=20000,maxRows=10000,pageSize=500}={}){
 async function read(table,columns){
  const controller=new AbortController();let timer;
  try{return await Promise.race([(async()=>{
   const c=await getContext();if(!c?.tenantId||!c.user?.id||!['compliance_officer','head_of_compliance','bank_manager'].includes(c.role))throw Error('Verified bank operations access is required.');
   const rows=[];let total=null;
   for(let offset=0;;offset+=pageSize){
    if(controller.signal.aborted)throw Error('Dashboard read timed out.');
    const r=await client.from(table).select(columns,{count:'exact'}).eq('tenant_id',c.tenantId).order('id').range(offset,offset+pageSize-1).abortSignal(controller.signal);
    if(r.error)throw Error('Dashboard data could not be read.');if(!Array.isArray(r.data)||!Number.isInteger(r.count)||r.count<0)throw Error('Dashboard count unavailable.');
    if(r.count>maxRows)throw Error('Dataset exceeds the interactive analytics limit. Totals are unavailable.');
    if(total!==null&&total!==r.count)throw Error('Records changed during loading. Refresh to retry.');total=r.count;rows.push(...r.data);
    if(rows.length>total||new Set(rows.map(x=>x.id)).size!==rows.length)throw Error('Dashboard pages changed during loading. Refresh to retry.');
    if(rows.length===total)break;if(!r.data.length)throw Error('Dashboard read is incomplete.');
   }
   const fresh=await getContext();if(c.tenantId!==fresh?.tenantId||c.user.id!==fresh?.user?.id||c.role!==fresh?.role)throw Error('Session changed. Refresh the dashboard.');return {rows,user:c.user.id,bank:c.tenantId};
  })(),new Promise((_,reject)=>{timer=setTimeout(()=>{controller.abort();reject(Error('Dashboard read timed out. Refresh to retry.'));},timeout);})]);}finally{clearTimeout(timer);controller.abort();}
 }
 return {alerts:()=>read('alerts','id,status,severity,rule_triggered,created_at,assigned_user_id,case_reference'),customers:()=>read('customers','id,risk_tier,industry')};
}
