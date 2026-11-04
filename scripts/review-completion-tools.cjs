'use strict';
const assert=require('node:assert/strict');
const {reconcile,same,uuid}=require('./review-acceptance-tools.cjs');
const PHASES=['qa-submit','qa-reject','qa-save','qa-resubmit','qa-approve','exec-submit','exec-approve'];
function reconcileCompletedReview(prior,current,journal,trigger){
 assert(uuid(prior.run_id));assert.equal(journal.run_id,prior.run_id);assert.deepEqual(journal.fixture,prior.fixture);assert.equal(prior.summary.completed,false);assert.equal(prior.summary.pass,12);assert.equal(prior.summary.fail,2);
 const failed=prior.checks.filter(x=>x.result==='FAIL');assert.equal(failed.length,2);assert(failed.every(x=>x.detail.includes('Internal report payload changed')&&x.detail.includes('updated_at')));
 assert(prior.checks.some(x=>x.result==='PASS'&&x.check.startsWith('Maker reopens the reviewed closed case')));assert(prior.checks.some(x=>x.result==='PASS'&&x.check.startsWith('No unexpected browser destinations')));
 for(const key of ['blocked','writes','errors','route_errors'])assert.deepEqual(prior.diagnostics[key],[]);assert(prior.diagnostics.dialogs.every(x=>x.expected));
 assert.deepEqual(current,prior.after,'Current state differs from the stopped report; no continuation permitted');
 assert.deepEqual(trigger,{table:'suspicious_transaction_reports',trigger:'str_update_timestamp',enabled:'O',schema:'public',function:'update_str_timestamp',type_bits:19,body_md5:'1489083fd9d99d4554c8e29b3e9a7ad3'},'Unreviewed timestamp trigger');
 assert.deepEqual(prior.plans.map(x=>x.name),PHASES);assert.equal(prior.requests.length,9);
 const plans=structuredClone(prior.plans);
 for(const p of plans){const requests=prior.requests.filter(x=>x.phase===p.name);assert.equal(requests.length,['qa-submit','qa-approve'].includes(p.name)?2:1);assert.equal(p.count,requests.length);assert(p.persisted&&p.audit&&p.ack,'Each committed operation must have its retained receipt and audit');for(const [i,r]of requests.entries()){assert.equal(r.http_status,200);assert.equal(r.attempt,i+1);assert(same(r.body,p.body));assert(same({...r.ack,replayed:false},p.persisted.result));assert.equal(r.ack.replayed,i>0);if(requests.length===2&&i===0)assert.equal(r.dropped_committed_response,true);}}
 const submit=plans.find(p=>p.name==='exec-submit'),approval=plans.find(p=>p.name==='exec-approve'),row=current.fixture.suspicious_transaction_reports[0];assert.equal(current.fixture.suspicious_transaction_reports.length,1);assert.equal(row.id,submit.persisted.result.report_id);assert.equal(approval.body.p_target_id,row.id);assert.equal(approval.body.p_decision,'APPROVE');
 const old=submit.reportSnapshot;assert(old&&typeof old.updated_at==='string');const parse=value=>{const n=Date.parse(value);assert(Number.isFinite(n),'Timestamp missing or malformed');return n;};
 const originalTime=parse(old.updated_at),newTime=parse(row.updated_at),lockTime=parse(row.locked_at),receiptTime=parse(approval.persisted.created_at),auditTime=parse(approval.audit.created_at);
 assert(row.updated_at===approval.audit.created_at&&newTime===auditTime&&newTime>=originalTime&&newTime<=lockTime&&lockTime<=receiptTime,'Report timestamp is outside the confirmed approval transaction');
 // Only the known BEFORE UPDATE trigger's timestamp is normalized. Every other
 // report field, receipt, audit and unrelated record still uses the exact checks.
 submit.reportSnapshot={...old,updated_at:row.updated_at};
 const completed=reconcile(prior.before,current,prior.fixture,plans,prior.seed);assert.deepEqual(completed,PHASES);
 return {completed_phases:completed,report_id:row.id,timestamp:{trigger:'public.update_str_timestamp',before:old.updated_at,after:row.updated_at,approval_locked_at:row.locked_at}};
}
module.exports={reconcileCompletedReview,PHASES};
