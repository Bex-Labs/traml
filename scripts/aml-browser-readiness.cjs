'use strict';
// Read-only readiness phases. No retries, navigation forcing or application boot calls.
async function dashboardReadiness(page,{phase,timeout=45000}={}){
 await phase('dashboard_handlers_and_role',()=>page.waitForFunction(()=>{
  return typeof window.previewUnassignedAlert==='function'&&typeof window.loadAlertsQueue==='function'
   &&document.querySelector('#ui-user-role')?.textContent.trim().toLowerCase().replace(/\s+/g,'_')==='compliance_officer';
 },null,{timeout}));
 await phase('open_unassigned_queue',()=>page.locator('#tab-unassigned').click({timeout}));
 await phase('unassigned_queue_result',async()=>{
  await page.waitForFunction(()=>{
   const body=document.querySelector('#alerts-table-body');
   if(!body)return false;
   return body.querySelector('tr.main-alert-row')!==null||/No unassigned alerts found\.|Failed to load alerts from database\./.test(body.textContent);
  },null,{timeout});
  const status=await page.locator('#alerts-table-body').textContent();
  if(/Failed to load alerts from database\./.test(status))throw Error('Actual alert queue reported a database read failure');
 });
}
function queueSnapshot(){
 const body=document.querySelector('#alerts-table-body'),role=document.querySelector('#ui-user-role'),secure=document.querySelector('#secure-body');
 return {ready_state:document.readyState,has_preview_handler:typeof window.previewUnassignedAlert==='function',has_queue_handler:typeof window.loadAlertsQueue==='function',role_text:role?.textContent.trim()||null,secure_body_display:secure?.style.display||null,queue_present:!!body,queue_rows:body?.querySelectorAll('tr.main-alert-row').length||0,queue_state:!body?'absent':/Fetching/.test(body.textContent)?'fetching':/Failed to load alerts/.test(body.textContent)?'error':/No unassigned alerts found\./.test(body.textContent)?'empty':body.querySelector('tr.main-alert-row')?'rows':'other'};
}
async function phaseWithDiagnostics(info,name,fn,{clean,snapshot=()=>info.page.evaluate(queueSnapshot),snapshotTimeout=1500}={}){
 const item={name,started_at:new Date().toISOString()};info.phases.push(item);const start=Date.now();info.phase=name;
 try{const value=await fn();item.result='PASS';return value;}
 catch(e){item.result='FAIL';item.error=clean(e.message);item.pending_requests=(info.assets||[]).filter(r=>r.status==='PENDING').slice(0,50).map(r=>({...r}));let timer;try{item.snapshot=await Promise.race([snapshot(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Diagnostic snapshot timed out')),snapshotTimeout);})]);}catch(err){item.snapshot_error=clean(err.message);}finally{clearTimeout(timer);}throw Error(name+': '+clean(e.message));}
 finally{item.elapsed_ms=Date.now()-start;}
}
module.exports={dashboardReadiness,queueSnapshot,phaseWithDiagnostics};
