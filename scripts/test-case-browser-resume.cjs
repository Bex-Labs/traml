'use strict';
const assert=require('node:assert/strict'),{EventEmitter}=require('node:events');
const {validateBrowserResume,trackAssets,RECOVERY_BASELINES}=require('./verify-case-claim-acceptance-local.cjs');
const rootId='0f27350e-d2be-4d65-8e4e-21401f52a907',runId='9d5f7fca-6a85-4960-ab28-7ff5ad6df6e0';
const browserId='ab6ad7b9-d3f7-4a38-a799-8238fafee971',raceId='a8cbd4e6-8794-4c74-89cf-063a07bfaa9b',actor='aacb70b4-8b48-40f6-9c59-f2a38e0445d6';
const root={run_id:rootId,fixture:{created:true,marker:'CaseAcceptance-'+rootId,browser_alert_id:browserId,race_alert_id:raceId},diagnostics:{phases:[],race:[]}};
const previous={run_id:runId,resumed_from_run:rootId,fixture:{...root.fixture,race_winner_id:actor},checks:[{check:'Two concurrent database-role claims wait on a lock and produce one winner',result:'PASS'},{check:'Original alerts, financial, risk, evaluation and archive state unchanged',result:'PASS'}],diagnostics:{race:[{actor_id:actor,exit_code:0},{actor_id:'72855f6c-85db-4c78-b6c3-b42134a9cb99',exit_code:3}]},reconciliation:{original_fingerprint:RECOVERY_BASELINES[rootId],recovered_fingerprint:RECOVERY_BASELINES[rootId]}};
assert.equal(validateBrowserResume(previous,runId,root),rootId);console.log('PASS Verified prior race can be preserved for browser-only resume');
for(const mutate of [p=>p.fixture.browser_alert_id=raceId,p=>p.checks[0].result='FAIL',p=>p.checks[1].result='FAIL',p=>p.fixture.race_winner_id='00000000-0000-4000-8000-000000000099',p=>p.reconciliation.recovered_fingerprint='changed']){const copy=structuredClone(previous);mutate(copy);assert.throws(()=>validateBrowserResume(copy,runId,root));}
console.log('PASS Altered fixtures, unverified races, changed state and mismatched winners cannot resume');
const attempted=structuredClone(previous);attempted.checks.push({check:'Actual queue and Claim button create exactly one protected claim',result:'FAIL'});assert.throws(()=>validateBrowserResume(attempted,runId,root));console.log('PASS A previous browser claim attempt requires separate reconciliation');
const page=new EventEmitter(),info={phase:'dashboard_handlers_and_role'},diagnostics={assets:[],console_errors:[]};trackAssets(page,info,diagnostics);
const request={url:()=> 'https://cdn.jsdelivr.net/chart.js?apikey=DO_NOT_EXPORT',method:()=> 'GET',resourceType:()=> 'script',postData:()=>{throw Error('Body must not be read');}};
page.emit('request',request);assert.equal(info.assets,diagnostics.assets);assert.equal(info.assets[0].status,'PENDING');assert.equal(info.assets[0].phase,info.phase);assert.equal(info.assets[0].path,'https://cdn.jsdelivr.net/chart.js');console.log('PASS Actual asset tracker exposes pending startup requests to phase diagnostics');
page.emit('response',{request:()=>request,status:()=>200});page.emit('requestfinished',request);assert.equal(info.assets[0].status,'FINISHED');assert.equal(info.assets[0].http_status,200);console.log('PASS HTTP status and completion are recorded');
const failed={...request,url:()=> 'http://127.0.0.1:55321/auth/v1/token?apikey=DO_NOT_EXPORT',method:()=> 'POST',resourceType:()=> 'fetch',failure:()=>({errorText:'net::ERR_EMPTY_RESPONSE'})};
page.emit('request',failed);page.emit('requestfailed',failed);assert.equal(info.assets[1].status,'FAILED');assert.equal(info.assets[1].error,'net::ERR_EMPTY_RESPONSE');assert(!JSON.stringify(diagnostics).includes('DO_NOT_EXPORT'));console.log('PASS Auth failures are tracked without query strings, headers or bodies');
page.emit('console',{type:()=> 'error',text:()=> 'Failed to load resource'});assert.equal(diagnostics.console_errors.length,1);console.log('PASS Browser console errors are retained for startup diagnosis');
console.log('7 browser-resume/diagnostic checks passed; native browser execution remains separate.');
