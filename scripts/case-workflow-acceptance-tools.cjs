'use strict';
const assert=require('node:assert/strict');
const {API,BANK,lit}=require('./aml-compatible-db.cjs');
const {networkAllowed}=require('./verify-coreaml-kyc-browser-local.cjs');
const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])])):value;
const same=(a,b)=>JSON.stringify(canonical(a))===JSON.stringify(canonical(b));
const uuid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const TEXT=Object.freeze({initial:'Synthetic acceptance: reviewed the linked alert evidence. Draft saved for continuity; no financial action or filing.',stale:'Synthetic stale-tab edit: this text must never replace the confirmed server draft.',final:'Synthetic acceptance complete: linked alert evidence reviewed. Closing only this claimed test group; no financial action or filing.'});
function fullStateSQL(f,baseSQL){return `SELECT ((${baseSQL(f).replace(/;\s*$/,'')})::jsonb||jsonb_build_object('draft_rows',(SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY id),'[]'::jsonb) FROM public.investigation_drafts d)))::text;`;}
function validateInitial(state,f){
 assert.equal(f.marker,'GroupClaimTest-b4b94f13-5991-4436-8692-b19c8665b92c');
 assert.equal(f.customer_id,'1d194969-6755-47bb-b7e2-f7cb038c1732');
 assert.deepEqual([...f.alert_ids].sort(),['c68e50d1-3090-4fce-b25f-c9a0fb03ce61','56b80c62-b95e-4122-9b64-0a77b705113b'].sort());
 assert.equal(f.owner_id,'aacb70b4-8b48-40f6-9c59-f2a38e0445d6');assert.equal(f.case_reference,'CASE-d3fd62ee-b6a8-4533-9fa7-c6fc65fa8120');
 assert.equal(state.fixture.customer.id,f.customer_id);assert.equal(state.fixture.customer.tenant_id,BANK);assert.equal(Number(state.fixture.customer.risk_score),40);assert.equal(state.fixture.customer.risk_tier,'MEDIUM');assert.equal(state.fixture.history.length,2);
 assert.equal(state.fixture.claims.length,1);const c=state.fixture.claims[0];assert.equal(c.investigator_id,f.owner_id);assert.equal(c.tenant_id,BANK);assert.equal(c.case_reference,f.case_reference);assert(f.alert_ids.includes(c.anchor_alert_id));assert.deepEqual([...c.alert_ids].sort(),[...f.alert_ids].sort());
 assert.equal(state.fixture.alerts.length,2);assert(state.fixture.alerts.every(a=>f.alert_ids.includes(a.id)&&a.status==='INVESTIGATING'&&a.customer_id===f.customer_id&&a.tenant_id===BANK&&a.assigned_user_id===f.owner_id&&a.case_reference===f.case_reference));
 assert.equal(state.draft_rows.length,0,'Existing drafts require reconciliation; acceptance will not start again');assert.equal(state.actions.length,0,'Existing actions require reconciliation; acceptance will not start again');
}
function createBoundary(f,anchor,options={}){
 assert(uuid(anchor)&&f.alert_ids.includes(anchor));let phase=null;
 const attempts=[],keys=new Map(),steps={initial:{action:'SAVE',rev:0,text:TEXT.initial,max:2},stale:{action:'SAVE',rev:0,text:TEXT.stale,max:1},final:{action:'SAVE',rev:1,text:TEXT.final,max:1},close:{action:'CLOSE',rev:2,max:2}};
 if(options.resumeRequest){
  const old=options.resumeRequest;
  assert.equal(old.phase,'initial');assert.equal(old.attempt,1);assert.equal(old.dropped_committed_response,true);
  const expected={p_alert_id:anchor,p_action:'SAVE',p_expected_revision:0,p_request_id:old.body.p_request_id,p_narrative:TEXT.initial,p_snapshot:{entity_ids:[f.customer_id],transaction_refs:[]}};
  assert(uuid(old.body.p_request_id)&&same(old.body,expected));
  attempts.push(structuredClone(old));keys.set(old.body.p_request_id,'initial');steps.stale.rev=1;steps.final.max=2;
 }
 return {
  attempts,
  arm(name){assert(steps[name],'Unknown write phase');phase=name;},
  disarm(){phase=null;},
  decide(url,method,body){
   if(!networkAllowed(url,method))return 'destination';
   if(url.origin===API){
    if(url.pathname.startsWith('/functions/v1/'))return 'mutation';
    if(url.pathname.startsWith('/rest/v1/rpc/')){
     if(url.pathname==='/rest/v1/rpc/coreaml_load_case_draft')return method==='OPTIONS'||(method==='POST'&&body&&same(Object.keys(body).sort(),['p_alert_id'])&&f.alert_ids.includes(body.p_alert_id))?null:'mutation';
     if(url.pathname!=='/rest/v1/rpc/coreaml_case_action'||!phase)return 'mutation';
     if(method==='OPTIONS')return null;
     const plan=steps[phase],prior=attempts.filter(a=>a.phase===phase);
     if(method!=='POST'||!body||prior.length>=plan.max||!uuid(body.p_request_id))return 'mutation';
     const expected={p_alert_id:anchor,p_action:plan.action,p_expected_revision:plan.rev,p_request_id:body.p_request_id};
     if(plan.action==='SAVE'){expected.p_narrative=plan.text;expected.p_snapshot={entity_ids:[f.customer_id],transaction_refs:[]};}
     if(!same(body,expected))return 'mutation';
     if(prior.length&&prior[0].body.p_request_id!==body.p_request_id)return 'mutation';
     if(keys.has(body.p_request_id)&&keys.get(body.p_request_id)!==phase)return 'mutation';
     keys.set(body.p_request_id,phase);attempts.push({phase,attempt:prior.length+1,body:structuredClone(body),drop:prior.length===0&&(options.resumeRequest?['final','close']:['initial','close']).includes(phase)});return null;
    }
    if(!['GET','HEAD','OPTIONS'].includes(method)&&!(method==='POST'&&['/auth/v1/token','/auth/v1/logout'].includes(url.pathname)))return 'mutation';
   }
   if(url.origin==='http://127.0.0.1:5520'&&!['GET','HEAD','OPTIONS'].includes(method))return 'mutation';
   return null;
  }
 };
}
function assertState(before,after,f,completed,attempts){
 const oldOriginal={...before.original},newOriginal={...after.original};delete oldOriginal.drafts;delete newOriginal.drafts;assert.deepEqual(newOriginal,oldOriginal,'Unrelated state changed');
 assert.deepEqual(after.fixture.customer,before.fixture.customer,'Customer/risk state changed');assert.deepEqual(after.fixture.history,before.fixture.history,'Risk history changed');assert.deepEqual(after.fixture.claims,before.fixture.claims,'Claim receipt changed');
 const closed=completed===3;
 assert.equal(after.fixture.alerts.length,2);
 for(const old of before.fixture.alerts){const current=after.fixture.alerts.find(a=>a.id===old.id);assert(current);assert.deepEqual(current,{...old,status:closed?'CLOSED':'INVESTIGATING'},'Alert changed outside expected status');}
 const expectedActions=['initial','final','close'].slice(0,completed);
 assert.equal(after.actions.length,completed,'Unexpected or duplicate action receipt');assert.equal(after.draft_rows.length,completed?1:0,'Unexpected draft rows');
 if(completed){const d=after.draft_rows[0];assert(uuid(d.id));assert.equal(d.alert_id,before.fixture.claims[0].anchor_alert_id);assert.equal(d.investigator_id,f.owner_id);assert.equal(d.tenant_id,BANK);assert.equal(d.case_reference,f.case_reference);assert.equal(d.revision,completed);assert.equal(d.status,closed?'CLOSED':'IN_PROGRESS');assert.equal(d.draft_narrative,completed===1?TEXT.initial:TEXT.final);assert.deepEqual(d.evidence_snapshot,{entities:[{id:f.customer_id,name:before.fixture.customer.entity_name||[before.fixture.customer.first_name,before.fixture.customer.last_name].filter(Boolean).join(' ')}],txs:[]});if(closed){assert.equal(typeof d.closed_at,'string');assert(!Number.isNaN(Date.parse(d.closed_at)),'Missing or invalid closure timestamp');}else assert.equal(d.closed_at,null);
  assert.deepEqual(d.ai_explanation??null,f.expected_ai_explanation??null,'Draft AI field differs from reviewed expectation');}
 const oldEvents=before.fixture.events;assert.equal(after.fixture.events.length,oldEvents.length+completed,'Unexpected or duplicate audit');for(const old of oldEvents)assert.deepEqual(after.fixture.events.find(e=>e.id===old.id),old);
 for(const name of expectedActions){
  const first=attempts.find(a=>a.phase===name);assert(first,'Missing browser request receipt');const b=first.body;
  const r=after.actions.find(a=>a.request_id===b.p_request_id);assert(r,'Missing persisted action');assert.equal(r.case_reference,f.case_reference);assert.equal(r.actor_id,f.owner_id);assert.equal(r.tenant_id,BANK);assert.equal(r.action,b.p_action);
  assert.deepEqual(r.payload,b.p_action==='SAVE'?{revision:b.p_expected_revision,narrative:b.p_narrative,snapshot:b.p_snapshot}:{revision:b.p_expected_revision});
  const d=after.draft_rows[0];assert.deepEqual(r.result,{id:d.id,alert_id:d.alert_id,case_reference:f.case_reference,request_id:b.p_request_id,revision:b.p_expected_revision+1,status:b.p_action==='SAVE'?'IN_PROGRESS':'CLOSED',replayed:false});
  const events=after.fixture.events.filter(e=>e.metadata?.request_id===b.p_request_id);assert.equal(events.length,1);const e=events[0];assert.equal(e.event_type,b.p_action==='SAVE'?'CASE_DRAFT_SAVED':'CASE_CLOSED');assert.equal(e.user_id,f.owner_id);assert.equal(e.tenant_id,BANK);assert.equal(e.metadata.case_ref,f.case_reference);assert.equal(e.metadata.anchor_alert_id,d.alert_id);assert.equal(e.metadata.revision,b.p_expected_revision+1);
 }
 const allowed=new Set([...oldEvents.map(e=>e.id),...after.fixture.events.filter(e=>expectedActions.some(name=>attempts.find(a=>a.phase===name)?.body.p_request_id===e.metadata?.request_id)).map(e=>e.id)]);
 assert(after.fixture.events.every(e=>allowed.has(e.id)),'Unexpected audit event');
}
function assertResumePreserved(retained,current){
 assert.equal(retained.draft_rows.length,1);assert.equal(current.draft_rows.length,1);
 const old=retained.draft_rows[0],now=current.draft_rows[0];
 for(const key of ['id','alert_id','investigator_id','tenant_id','case_reference','created_at','ai_explanation'])assert.deepEqual(now[key],old[key],'Retained draft metadata changed: '+key);
 for(const old of retained.actions)assert.deepEqual(current.actions.find(r=>r.request_id===old.request_id),old,'Retained action receipt changed');
 for(const old of retained.fixture.events)assert.deepEqual(current.fixture.events.find(e=>e.id===old.id),old,'Retained audit changed');
}
function validateResume(prior,current,f){
 assert.equal(prior.run_id,'d73e82d1-b2c6-4cad-80f4-0f6e24085bd8');
 const {expected_ai_explanation,...fixture}=f;assert.deepEqual(prior.fixture,fixture);
 assert.deepEqual(expected_ai_explanation,{},'Only the reviewed empty JSON default is accepted for this recovery');
 validateInitial(prior.before,f);assert.equal(prior.committed_action_count,1);assert.equal(prior.requests.length,1);
 const request=prior.requests[0];assert.equal(request.phase,'initial');assert.equal(request.attempt,1);assert.equal(request.http_status,200);assert.equal(request.drop,true);assert.equal(request.dropped_committed_response,true);
 assert.equal(request.body.p_request_id,'770d0c41-c936-4088-b537-911fb5f06ff0');
 assert.deepEqual(request.receipt,prior.after.actions[0].result);assert.equal(request.receipt.replayed,false);
 assert(prior.checks.some(c=>c.result==='PASS'&&c.check==='Actual login and two trusted officer tabs open the same unsaved case'));
 const failures=prior.checks.filter(c=>c.result==='FAIL');assert.equal(failures.length,2);assert(failures.every(c=>c.detail.includes('Unexpected background draft alteration')));
 for(const key of ['blocked','writes','errors','route_errors','dialogs'])assert.equal(prior.diagnostics[key].length,0);
 assertState(prior.before,prior.after,f,1,prior.requests);
 assert.deepEqual(current,prior.after,'Current state differs from the retained failed run; no continuation attempted');
 return structuredClone(request);
}
async function awaitLoginForm(page){
 // A committed navigation may still be parsing a blocking CDN script.
 // The actual auth module registers its submit handler on DOMContentLoaded.
 await page.waitForLoadState('domcontentloaded',{timeout:60000});
 for(const selector of ['#login-form','#email','#password','#login-form button[type=submit]'])
  await page.locator(selector).waitFor({state:'visible',timeout:10000});
}
module.exports={TEXT,createBoundary,fullStateSQL,validateInitial,assertState,same,awaitLoginForm,validateResume,assertResumePreserved};
