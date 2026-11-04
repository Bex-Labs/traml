'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),Module=require('node:module');
const ROOT=path.resolve(__dirname,'..'),API='http://127.0.0.1:55321',BANK='a1000000-0000-4000-8000-000000000001';
const file=path.join(__dirname,'case-workflow-acceptance-tools.cjs'),m=new Module(file,module);m.filename=file;m.paths=module.paths;m.require=name=>name==='./aml-compatible-db.cjs'?{API,BANK}:name==='./verify-coreaml-kyc-browser-local.cjs'?{networkAllowed:()=>true}:require(name);m._compile(fs.readFileSync(file,'utf8'),file);
const {validateResume,createBoundary,assertState,TEXT,assertResumePreserved}=m.exports;
const prior=JSON.parse(fs.readFileSync(process.env.COREAML_RESUME_TEST_REPORT||path.join(ROOT,'.coreaml-local/case-workflow-acceptance/d73e82d1-b2c6-4cad-80f4-0f6e24085bd8/results.json'),'utf8'));
const f={...prior.fixture,expected_ai_explanation:{}},seed=validateResume(prior,prior.after,f);
console.log('PASS Actual retained report reconciles its one save, receipt, audit and empty JSON default');
for(const mutate of [s=>s.draft_rows[0].revision=2,s=>s.actions.push(structuredClone(s.actions[0])),s=>s.fixture.events.push({...s.fixture.events.at(-1),id:'changed'}),s=>s.fixture.alerts[0].details='changed',s=>s.fixture.history.push({id:'changed'}),s=>s.draft_rows[0].ai_explanation={status:'Success'},s=>s.original.profiles='changed']){const current=structuredClone(prior.after);mutate(current);assert.throws(()=>validateResume(prior,current,f));}
console.log('PASS Current data drift, duplicate receipts/audits, changed evidence, risk or nonempty AI output cannot resume');
for(const mutate of [p=>p.run_id='unverified',p=>p.requests.push(structuredClone(p.requests[0])),p=>p.requests[0].body.p_request_id='00000000-0000-4000-8000-000000000000',p=>p.requests[0].dropped_committed_response=false,p=>p.checks.find(c=>c.result==='FAIL').detail='Different failure']){const p=structuredClone(prior);mutate(p);assert.throws(()=>validateResume(p,prior.after,f));}
console.log('PASS Unverified run, changed original request and previous retry attempts cannot resume');
const boundary=createBoundary(f,seed.body.p_alert_id,{resumeRequest:seed}),url=new URL(API+'/rest/v1/rpc/coreaml_case_action');
boundary.arm('initial');assert.equal(boundary.decide(url,'POST',seed.body),null);assert.equal(boundary.attempts.at(-1).drop,false);assert(boundary.decide(url,'POST',seed.body));
const body=(phase,id,rev)=>({p_alert_id:seed.body.p_alert_id,p_action:'SAVE',p_expected_revision:rev,p_request_id:`00000000-0000-4000-8000-${id}`,p_narrative:TEXT[phase],p_snapshot:{entity_ids:[f.customer_id],transaction_refs:[]}});
boundary.arm('final');const final=body('final','000000000001',1);assert.equal(boundary.decide(url,'POST',final),null);assert.equal(boundary.attempts.at(-1).drop,true);assert.equal(boundary.decide(url,'POST',final),null);assert.equal(boundary.attempts.at(-1).drop,false);
boundary.arm('stale');assert(boundary.decide(url,'POST',body('stale','000000000002',0)));assert.equal(boundary.decide(url,'POST',body('stale','000000000002',1)),null);
console.log('PASS Resume replays original UUID, drops/retries only the next UI save, and tests stale revision one');
assert.throws(()=>assertState(prior.before,prior.after,{...f,expected_ai_explanation:null},1,prior.requests));
const source=fs.readFileSync(path.join(__dirname,'verify-case-workflow-resume-local.cjs'),'utf8');assert(source.includes('pg_get_expr(d.adbin,d.adrelid)'));assert(source.includes('validateResume(prior,current,f)'));assert(source.indexOf('validateResume(prior,current,f)')<source.indexOf("boundary.arm('initial')"));
console.log('PASS Empty JSON expectation is explicit and native default/reconciliation gates precede all writes');
assertResumePreserved(prior.after,prior.after);
for(const mutate of [s=>s.draft_rows[0].created_at='changed',s=>s.actions[0].created_at='changed',s=>s.fixture.events.at(-1).message='changed']){const current=structuredClone(prior.after);mutate(current);assert.throws(()=>assertResumePreserved(prior.after,current));}
console.log('PASS Retained draft creation metadata and original receipt/audit must remain byte-for-byte equivalent');
console.log('6 resume safety checks passed against the retained report; native continuation remains separate.');
