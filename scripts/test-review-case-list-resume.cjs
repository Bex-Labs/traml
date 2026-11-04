'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const ROOT=path.resolve(__dirname,'..'),{validatePristineResume}=require('./review-acceptance-tools.cjs');
const model=require('./fixtures/review-acceptance-model.json');
const prior={run_id:model.f.run_id,fixture:model.f,before:model.before,seed:model.seed,after:model.seed,requests:[],plans:[],completed_phases:[],summary:{pass:8,fail:1,completed:false},checks:[{check:'Actual maker submission survives a lost reply',result:'FAIL',detail:'Waiting for Open Case'},{check:'Exact receipts, audits and fixture transitions reconcile',result:'PASS'}],diagnostics:{console_errors:[{message:'caseLabel is not defined'}],blocked:[],writes:[],errors:[],route_errors:[],dialogs:[]}};
const journal={run_id:prior.run_id,fixture:prior.fixture};let count=0;const pass=t=>{console.log('PASS '+t);count++;};
assert.deepEqual(validatePristineResume(prior,model.seed,journal,prior.run_id),model.f);pass('Pristine stopped fixture reconciles without new alerts, drafts, claims or requests');
for(const mutate of [p=>p.requests.push({}),p=>p.plans.push({}),p=>p.after.fixture.alerts[0].status='CLOSED',p=>p.summary.completed=true,p=>p.diagnostics.console_errors=[],p=>p.checks[0].detail='Other failure',p=>p.diagnostics.writes.push({})]){const p=structuredClone(prior);mutate(p);assert.throws(()=>validatePristineResume(p,model.seed,journal,p.run_id));}
const changed=structuredClone(model.seed);changed.original.accounts='changed';assert.throws(()=>validatePristineResume(prior,changed,journal,prior.run_id));assert.throws(()=>validatePristineResume(prior,model.seed,{...journal,run_id:model.f.maker},prior.run_id));pass('Requests, changed state, wrong journal or an unreviewed failure cannot resume');
const {spawnSync}=require('node:child_process');
for(const file of ['test-case-worklists.cjs',...(process.argv.includes('--browser')?['test-case-worklists-browser.cjs']:[])]){const result=spawnSync(process.execPath,[path.join(__dirname,file)],{stdio:'inherit',env:process.env});assert.equal(result.status,0,'Current grouped case renderer regression failed');}
console.log('Retained pristine-resume gates and current grouped renderer checks passed.');
