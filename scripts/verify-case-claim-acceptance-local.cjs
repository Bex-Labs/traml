'use strict';
// Native local acceptance. Creates two synthetic, null-customer alerts and retains
// their claim receipts. Never claims any existing alert or creates cash/filings.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {randomUUID}=require('node:crypto');
const {spawn}=require('node:child_process');
const {ROOT,DB,API,BANK,query,assertLocal,lit}=require('./aml-compatible-db.cjs');
const {dashboardReadiness,phaseWithDiagnostics}=require('./aml-browser-readiness.cjs');
const {networkAllowed,clean:baseClean,awaitJwtReadiness,signOutBrowserSession}=require('./verify-coreaml-kyc-browser-local.cjs');
const BASE='http://127.0.0.1:5520';
const clean=value=>baseClean(process.env.COREAML_LOCAL_PASSWORD?String(value).split(process.env.COREAML_LOCAL_PASSWORD).join('[password removed]'):value);
const uuid=value=>typeof value==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const read=sql=>query('BEGIN TRANSACTION READ ONLY;'+sql+'COMMIT;');
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function requestDecision(url,method,body,alertId){
 if(!networkAllowed(url,method))return 'destination';
 if(url.origin===API){
  if(url.pathname.startsWith('/functions/v1/'))return 'mutation';
  if(url.pathname.startsWith('/rest/v1/rpc/')){
   if(method==='OPTIONS'&&url.pathname==='/rest/v1/rpc/coreaml_claim_case')return null;
   if(method!=='POST'||url.pathname!=='/rest/v1/rpc/coreaml_claim_case'
       ||!body||Object.keys(body).length!==1||body.p_alert_id!==alertId)return 'mutation';
   return null;
  }
  const allowedAuth=method==='POST'&&['/auth/v1/token','/auth/v1/logout'].includes(url.pathname);
  if(!['GET','HEAD','OPTIONS'].includes(method)&&!allowedAuth)return 'mutation';
 }
 if(url.origin===BASE&&!['GET','HEAD','OPTIONS'].includes(method))return 'mutation';
 return null;
}
function fingerprintSQL(ids,riskExclusions=[]){
 const exclude=ids.map(id=>lit(id)+'::uuid').join(',');
 return `SELECT md5(jsonb_build_object(
 'alerts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.alerts a WHERE id NOT IN (${exclude})),
 'claims',(SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM public.coreaml_case_claims c WHERE anchor_alert_id NOT IN (${exclude})),
 'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM public.system_events e WHERE coalesce(metadata->>'anchor_alert_id','') NOT IN (${ids.map(lit).join(',')})),
 'customers',(SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM public.customers c),
 'accounts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.accounts a),
 'transactions',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.transactions t),
 'risk',(SELECT jsonb_agg(to_jsonb(h) ORDER BY id) FROM public.risk_score_history h WHERE ${riskExclusions.length?'id::text NOT IN ('+riskExclusions.map(value=>lit(String(value))).join(',')+')':'true'}),
 'runs',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.coreaml_compatible_runs r),
 'results',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.coreaml_compatible_results r),
 'outbox',(SELECT jsonb_agg(to_jsonb(o) ORDER BY transaction_id) FROM public.transaction_evaluation_outbox o),
 'archives',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.report_archives a)
 )::text);`;
}
function fingerprint(ids,riskExclusions=[]){return read(fingerprintSQL(ids,riskExclusions));}
// Baseline recovered from the retained failed report supplied for this run.
// Recovery may account for two precisely identified orphan history inserts only;
// all other state must still match this original pre-insertion fingerprint.
const RECOVERY_BASELINES=Object.freeze({'0f27350e-d2be-4d65-8e4e-21401f52a907':'c69f0d3ddc0ce194da9d9c9619ed4e01'});
function validateRecovery(prior,runId){
 assert(uuid(runId)&&RECOVERY_BASELINES[runId],'No verified historical baseline for this run');
 assert.equal(prior.run_id,runId);assert.equal(prior.fixture?.created,true);
 assert.equal(prior.fixture.marker,'CaseAcceptance-'+runId);
 const ids=[prior.fixture.browser_alert_id,prior.fixture.race_alert_id];assert(ids.every(uuid)&&ids[0]!==ids[1]);
 assert.equal(prior.diagnostics?.phases?.length,0,'Recovery requires the run stopped before browser login');
 assert.equal(prior.diagnostics?.race?.length,0,'Recovery requires the race never started');
 return ids;
}
function orphanHistoryIds(history,reasons){
 assert.equal(history.length,2);assert.equal(reasons.length,2);
 assert.equal(new Set(history.map(h=>h.change_reason)).size,2);
 assert.equal(new Set(history.map(h=>String(h.id))).size,2);
 for(const h of history){assert(h.id!==null&&h.id!==undefined&&h.customer_id===null&&h.previous_score===null&&h.previous_tier===null);assert(reasons.includes(h.change_reason));assert.equal(Number(h.new_score),10);assert.equal(h.new_tier,'LOW');}
 return history.map(h=>h.id);
}
function validateBrowserResume(previous,runId,rootPrior){
 assert(uuid(runId)&&previous.run_id===runId);
 const rootId=previous.resumed_from_run;const ids=validateRecovery(rootPrior,rootId);
 assert.equal(previous.fixture?.browser_alert_id,ids[0]);assert.equal(previous.fixture?.race_alert_id,ids[1]);assert.equal(previous.fixture?.marker,rootPrior.fixture.marker);
 const passed=name=>previous.checks?.some(check=>check.check===name&&check.result==='PASS');
 assert(passed('Two concurrent database-role claims wait on a lock and produce one winner'),'Saved race is not verified');
 assert(passed('Original alerts, financial, risk, evaluation and archive state unchanged'),'Saved state preservation is not verified');
 assert(!previous.checks?.some(check=>check.check==='Actual queue and Claim button create exactly one protected claim'),'Browser-only resume requires no earlier claim attempt');
 assert.equal(previous.reconciliation?.original_fingerprint,RECOVERY_BASELINES[rootId]);assert.equal(previous.reconciliation?.recovered_fingerprint,RECOVERY_BASELINES[rootId]);
 assert(uuid(previous.fixture.race_winner_id));
 const race=previous.diagnostics?.race;assert(Array.isArray(race)&&race.length===2&&race.filter(result=>result.exit_code===0).length===1);
 assert.equal(race.find(result=>result.exit_code===0).actor_id,previous.fixture.race_winner_id);
 return rootId;
}
function trackAssets(page,info,diagnostics){
 const pending=new Map();info.assets=diagnostics.assets;
 page.on('request',request=>{
  const url=new URL(request.url());if(!['document','script','stylesheet','font'].includes(request.resourceType())&&url.origin!==API)return;
  if(info.assets.length>=400)return;
  const entry={method:request.method(),path:clean(url.origin+url.pathname),type:request.resourceType(),phase:info.phase||'initial',started_at:new Date().toISOString(),status:'PENDING'};
  info.assets.push(entry);pending.set(request,{entry,start:Date.now()});
 });
 page.on('response',response=>{const item=pending.get(response.request());if(item){item.entry.http_status=response.status();item.entry.headers_after_ms=Date.now()-item.start;}});
 page.on('requestfinished',request=>{const item=pending.get(request);if(item){item.entry.status='FINISHED';item.entry.elapsed_ms=Date.now()-item.start;pending.delete(request);}});
 page.on('requestfailed',request=>{const item=pending.get(request);if(item){item.entry.status='FAILED';item.entry.error=clean(request.failure()?.errorText||'Request failed');item.entry.elapsed_ms=Date.now()-item.start;pending.delete(request);}});
 page.on('console',message=>{if(message.type()==='error'&&diagnostics.console_errors.length<40)diagnostics.console_errors.push(clean(message.text()));});
}
function receiptState(id){return JSON.parse(read(`SELECT jsonb_build_object(
 'alert',(SELECT jsonb_build_object('id',id,'status',status,'assigned_user_id',assigned_user_id,'case_reference',case_reference,'evidence',evidence,'details',details,'customer_id',customer_id,'transaction_id',transaction_id) FROM public.alerts WHERE id=${lit(id)}::uuid),
 'receipts',(SELECT coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) FROM public.coreaml_case_claims c WHERE anchor_alert_id=${lit(id)}::uuid),
 'audit_count',(SELECT count(*) FROM public.system_events WHERE metadata->>'anchor_alert_id'=${lit(id)})
 )::text;`));}
function assertReceipt(state,id,actor){
 assert(state.alert&&state.alert.status==='INVESTIGATING');assert.equal(state.alert.assigned_user_id,actor);
 assert.equal(state.alert.customer_id,null);assert.equal(state.alert.transaction_id,null);
 assert.deepEqual(state.alert.evidence,{});assert.equal(state.alert.details,'Synthetic claim acceptance; no customer or financial event.');
 assert.equal(state.receipts.length,1);assert.equal(state.audit_count,1);
 assert.equal(state.receipts[0].case_reference,state.alert.case_reference);
 assert.equal(state.receipts[0].investigator_id,actor);assert.deepEqual(state.receipts[0].alert_ids,[id]);
}
function runSql(sql){return new Promise(resolve=>{
 const started=Date.now(),child=spawn('docker',['exec','-i',DB,'psql','-X','-q','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres','-At'],{stdio:['pipe','pipe','pipe']});
 let stdout='',stderr='',settled=false;
 const finish=result=>{if(settled)return;settled=true;clearTimeout(timer);resolve({...result,elapsed_ms:Date.now()-started});};
 const timer=setTimeout(()=>{child.kill();finish({code:124,stdout,stderr:'Local race session timed out'});},25000);
 child.stdout.on('data',data=>{stdout+=data;});child.stderr.on('data',data=>{stderr+=data;});
 child.on('error',error=>finish({code:1,stdout,stderr:clean(error.message)}));
 child.on('close',code=>finish({code,stdout,stderr}));child.stdin.on('error',()=>{});child.stdin.end(sql);
 });}
function raceSql(actor,alertId,name){
 const claims=JSON.stringify({sub:actor,role:'authenticated',app_metadata:{role:'compliance_officer',tenant_id:BANK}});
 return `BEGIN;SET LOCAL statement_timeout='15s';SET LOCAL lock_timeout='8s';SET LOCAL application_name=${lit(name)};SET LOCAL ROLE authenticated;
 DO $claims$ BEGIN PERFORM set_config('request.jwt.claims',${lit(claims)},true);END $claims$;
 SELECT public.coreaml_claim_case(${lit(alertId)}::uuid);
 SELECT pg_sleep(3);COMMIT;`;
}
async function main(){
 assertLocal();
 const runId=randomUUID(),resumeAt=process.argv.indexOf('--resume-run'),browserResumeAt=process.argv.indexOf('--resume-browser-run');
 assert(!(resumeAt>=0&&browserResumeAt>=0),'Use only one resume mode');
 let resumeId=resumeAt<0?null:process.argv[resumeAt+1],browserResumeId=null,browserPrior;
 let ids=[randomUUID(),randomUUID()],marker='CaseAcceptance-'+runId,prior,raceSeal;
 if(browserResumeAt>=0){
  browserResumeId=process.argv[browserResumeAt+1];assert(uuid(browserResumeId),'Provide a valid browser resume UUID');
  browserPrior=JSON.parse(fs.readFileSync(path.join(ROOT,'.coreaml-local/case-acceptance',browserResumeId,'results.json'),'utf8'));
  assert(uuid(browserPrior.resumed_from_run),'Saved original run unavailable');
  prior=JSON.parse(fs.readFileSync(path.join(ROOT,'.coreaml-local/case-acceptance',browserPrior.resumed_from_run,'results.json'),'utf8'));
  resumeId=validateBrowserResume(browserPrior,browserResumeId,prior);ids=validateRecovery(prior,resumeId);marker=prior.fixture.marker;
 }
 if(resumeAt>=0){assert(uuid(resumeId),'Provide a valid retained run UUID');prior=JSON.parse(fs.readFileSync(path.join(ROOT,'.coreaml-local/case-acceptance',resumeId,'results.json'),'utf8'));ids=validateRecovery(prior,resumeId);marker=prior.fixture.marker;}
 const directory=path.join(ROOT,'.coreaml-local/case-acceptance',runId);fs.mkdirSync(directory,{recursive:true});
 const report={generated_at:new Date().toISOString(),run_id:runId,checks:[],fixture:{browser_alert_id:ids[0],race_alert_id:ids[1],marker},limitations:[
  'Creates and retains two isolated synthetic alerts, their claim receipts and audit events; no customer, deposit, evaluation or filing is created.',
  'Browser claim and replay use the actual form, queue, modal and service. The race uses two authenticated database-role sessions, not two signed-in browsers.',
  'Both alerts have no customer link. Customer-linked group claims and their risk-trigger side effects are not covered.',
  'Draft save/resume, closure, QA and SAR/CTR workflows remain outside this run.'
 ],diagnostics:{blocked:[],writes:[],errors:[],dialogs:[],phases:[],race:[],assets:[],console_errors:[]}};
 if(resumeId){report.resumed_from_run=resumeId;report.fixture.reused=true;report.limitations[0]='Reuses the two retained null-customer alerts; creates no new alerts, customers, cash, evaluations or filings. Expected claim receipts/audit events remain retained.';}
 if(browserResumeId){report.resumed_browser_from_run=browserResumeId;report.prior_race_run=browserResumeId;report.limitations[1]='This run verifies actual browser claim/replay only. The successful database race is preserved and rechecked from the previous run, not repeated.';}
 let browser,context,page,before,created=false;
 async function check(name,fn){try{await fn();report.checks.push({check:name,result:'PASS'});return true;}catch(error){report.checks.push({check:name,result:'FAIL',detail:clean(error.message)});return false;}}
 try{
  let actors;
  const ready=await check('Local installed claim function and two active same-bank officers are available',async()=>{
   assert.equal(read("SELECT to_regprocedure('public.coreaml_claim_case(uuid)') IS NOT NULL;"),'t');
   actors=JSON.parse(read(`SELECT coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) FROM (
    SELECT p.id, u.email='compliance_officer@coreaml-local.test' AS primary_actor FROM public.user_profiles p JOIN auth.users u ON u.id=p.id
    WHERE p.tenant_id=${lit(BANK)} AND p.role='compliance_officer' AND p.is_active IS TRUE
    AND u.email LIKE '%@coreaml-local.test' ORDER BY (u.email='compliance_officer@coreaml-local.test') DESC,p.id LIMIT 2) s;`));
   assert.equal(actors.length,2,'Need two existing active synthetic officers in the fixture bank');assert(actors[0].primary_actor,'Expected local compliance_officer test identity');assert(actors.every(a=>uuid(a.id)));
  });
  if(!ready)return report;
  if(resumeId){
   const reconciled=await check('Retained fixtures and exactly two orphan histories reconcile to original pre-insertion state',async()=>{
    const refs=ids.map((id,i)=>marker+'-'+i);
    const rows=JSON.parse(read(`SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY id),'[]'::jsonb) FROM public.alerts a WHERE id IN (${ids.map(id=>lit(id)+'::uuid').join(',')});`));
    assert.equal(rows.length,2);
    for(const id of ids){const row=rows.find(r=>r.id===id),index=ids.indexOf(id);assert(row&&row.customer_id===null&&row.transaction_id===null);if(!(browserResumeId&&index===1))assert(row.status==='UNASSIGNED'&&row.assigned_user_id===null&&row.case_reference===null);assert.equal(row.tenant_id,BANK);assert.equal(row.alert_ref,refs[index]);assert.equal(row.rule_triggered,marker);assert.deepEqual(row.evidence,{});assert.equal(row.details,'Synthetic claim acceptance; no customer or financial event.');}
    for(const id of ids){const state=receiptState(id);if(browserResumeId&&id===ids[1]){assertReceipt(state,id,browserPrior.fixture.race_winner_id);raceSeal=JSON.stringify(state);report.fixture.race_winner_id=browserPrior.fixture.race_winner_id;}else{assert.equal(state.receipts.length,0);assert.equal(state.audit_count,0);}}
    const reasons=refs.map(ref=>'Unified Engine Recalculation: Triggered by alert '+ref);
    const history=JSON.parse(read(`SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'customer_id',customer_id,'previous_score',previous_score,'new_score',new_score,'previous_tier',previous_tier,'new_tier',new_tier,'change_reason',change_reason)),'[]'::jsonb) FROM public.risk_score_history WHERE change_reason IN (${reasons.map(lit).join(',')});`));
    const orphanIds=orphanHistoryIds(history,reasons);
    const recovered=fingerprint(ids,orphanIds);assert.equal(recovered,RECOVERY_BASELINES[resumeId],'Other historical state does not reconcile; do not reset the baseline');
    report.reconciliation={original_fingerprint:RECOVERY_BASELINES[resumeId],recovered_fingerprint:recovered,retained_orphan_history_ids:orphanIds,orphan_rows_deleted:false};
   });
   if(!reconciled)return report;
  }
  // Ongoing preservation includes the retained orphan rows; none are ignored below.
  before=fingerprint(ids);
  const fixtureReady=await check('Two isolated null-customer alerts created; existing state unchanged',async()=>{
   if(!resumeId){query(`BEGIN;INSERT INTO public.alerts(id,alert_ref,rule_triggered,severity,status,tenant_id,created_at,evidence,details) VALUES
    ${ids.map((id,i)=>`(${lit(id)}::uuid,${lit(marker+'-'+i)},${lit(marker)},'LOW','UNASSIGNED',${lit(BANK)},now(),'{}','Synthetic claim acceptance; no customer or financial event.')`).join(',')};COMMIT;`);created=true;}
   assert.equal(fingerprint(ids),before);
  });
  if(resumeId&&fixtureReady)report.checks[report.checks.length-1].check='Retained null-customer fixtures reused without new inserts';
  if(!fixtureReady)return report;
  const browserReady=await check('Actual officer login and trusted bank/profile verified',async()=>{
   const {chromium}=require(path.join(ROOT,'.coreaml-test-tools/node_modules/playwright'));
   for(const channel of ['msedge','chrome']){try{browser=await chromium.launch({channel,headless:!process.argv.includes('--headed')});break;}catch{}}
   assert(browser,'Installed Chrome or Edge required');context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
   await context.route('**/*',async route=>{
    const request=route.request(),url=new URL(request.url());let body;try{body=request.postDataJSON();}catch{}
    const decision=requestDecision(url,request.method(),body,ids[0]);
    if(decision){report.diagnostics[decision==='destination'?'blocked':'writes'].push({method:request.method(),path:url.origin+url.pathname});return route.abort('blockedbyclient');}
    return route.continue();
   });
   page=await context.newPage();page.setDefaultTimeout(30000);page.setDefaultNavigationTimeout(45000);
   page.on('pageerror',error=>report.diagnostics.errors.push(clean(error.message)));
   page.on('websocket',socket=>{const url=new URL(socket.url());if(url.origin!==API.replace(/^http/,'ws'))report.diagnostics.blocked.push({method:'WEBSOCKET',path:url.origin+url.pathname});});
   page.on('dialog',dialog=>{report.diagnostics.dialogs.push(clean(dialog.message()));dialog.dismiss().catch(()=>{});});
   const info={page,actor:'compliance_officer',phases:report.diagnostics.phases};trackAssets(page,info,report.diagnostics);const phase=(name,fn)=>phaseWithDiagnostics(info,name,fn,{clean});
   await phase('login_document_commit',()=>page.goto(BASE+'/index.html',{waitUntil:'commit'}));
   const configured=await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');return supabase.supabaseUrl;});assert.equal(configured.replace(/\/$/,''),API);
   await page.locator('#email').fill('compliance_officer@coreaml-local.test');await page.locator('#password').fill(process.env.COREAML_LOCAL_PASSWORD||'CoreAML-Local-Only!2026');
   await phase('actual_form_to_dashboard_commit',()=>Promise.all([page.waitForURL(BASE+'/dashboard.html',{waitUntil:'commit'}),page.locator('#login-form button[type=submit]').click()]));
   const security=await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.auth.getSession();if(error||!data.session)throw Error('Session unavailable');return {id:data.session.user.id,metadata:data.session.user.app_metadata};});
   assert.equal(security.id,actors[0].id);assert.equal(security.metadata.role,'compliance_officer');assert.equal(security.metadata.tenant_id,BANK);
   await awaitJwtReadiness(()=>page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {error}=await supabase.from('alerts').select('id').limit(1).abortSignal(AbortSignal.timeout(5000));return {error:error?.message||null};}));
   const profile=await page.evaluate(async id=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.from('user_profiles').select('id,tenant_id,role,is_active').eq('id',id).single();if(error)throw Error(error.message);return data;},security.id);
   assert(profile.is_active&&profile.role==='compliance_officer'&&profile.tenant_id===BANK);await dashboardReadiness(page,{phase});
  });
  if(browserReady){
   const claimed=await check('Actual queue and Claim button create exactly one protected claim',async()=>{
    const row=page.locator(`#alerts-table-body tr[data-alert-id="${ids[0]}"]`);await row.waitFor({state:'visible'});
    await row.getByRole('button',{name:'Review Case',exact:true}).click();await page.locator('#alertPreviewModal').waitFor({state:'visible'});
    const responsePromise=page.waitForResponse(response=>response.url()===API+'/rest/v1/rpc/coreaml_claim_case'&&response.request().method()==='POST'&&response.request().postDataJSON()?.p_alert_id===ids[0]);
    await page.locator('#btn-claim-alert').click();const response=await responsePromise;assert.equal(response.status(),200,'Claim RPC must succeed');
    const receipt=await response.json();assert.deepEqual(receipt.alert_ids,[ids[0]]);assert.equal(receipt.investigator_id,actors[0].id);assert.equal(receipt.replayed,false);
    await page.locator('#alertPreviewModal').waitFor({state:'hidden'});assertReceipt(receiptState(ids[0]),ids[0],actors[0].id);
    report.fixture.browser_case_reference=receipt.case_reference;
   });
   if(claimed)await check('Actual service retry replays the original browser claim without duplicate audit',async()=>{
    const replay=await page.evaluate(async id=>{const alerts=await import('/js/services/alerts.service.js');return alerts.claimCase(id);},ids[0]);
    assert.equal(replay.replayed,true);assert.equal(replay.case_reference,report.fixture.browser_case_reference);assertReceipt(receiptState(ids[0]),ids[0],actors[0].id);
   });
  }
  if(browserResumeId){
   await check('Previously verified race claim remains unchanged; concurrency not rerun',async()=>{assert.equal(JSON.stringify(receiptState(ids[1])),raceSeal);report.diagnostics.race=browserPrior.diagnostics.race;});
  }else await check('Two concurrent database-role claims wait on a lock and produce one winner',async()=>{
   const names=[marker+'-race-1',marker+'-race-2'];
   const jobs=actors.map((actor,i)=>runSql(raceSql(actor.id,ids[1],names[i])));
   let sawWait=false;
   // Observe actual lock contention instead of counting sequential calls as a race.
   for(let attempt=0;attempt<12&&!sawWait;attempt++){
    sawWait=read(`SELECT EXISTS(SELECT 1 FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE l.locktype='advisory' AND NOT l.granted AND a.application_name IN (${names.map(lit).join(',')}));`)==='t';
    if(!sawWait)await pause(100);
   }
   const results=await Promise.all(jobs);report.diagnostics.race=results.map((r,i)=>({actor_id:actors[i].id,exit_code:r.code,elapsed_ms:r.elapsed_ms,error:r.code?clean(r.stderr):null}));
   assert(sawWait,'No advisory-lock wait observed; concurrency is not verified');assert.equal(results.filter(r=>r.code===0).length,1,'Exactly one officer must win');
   const loser=results.find(r=>r.code!==0);assert.match(loser.stderr,/already claimed|active investigation/i);
   const winner=actors[results.findIndex(r=>r.code===0)].id;assertReceipt(receiptState(ids[1]),ids[1],winner);report.fixture.race_winner_id=winner;
  });
 }catch(error){report.checks.push({check:'Acceptance prerequisites/execution',result:'FAIL',detail:clean(error.message)});}
 finally{
  if(page)await check('Browser session signs out',()=>signOutBrowserSession(page));
  if(context)await context.close().catch(()=>{});if(browser)await browser.close().catch(()=>{});
  await check('No unexpected browser destinations, mutations, dialogs or uncaught errors',async()=>{
   assert.deepEqual(report.diagnostics.blocked,[]);assert.deepEqual(report.diagnostics.writes,[]);assert.deepEqual(report.diagnostics.dialogs,[]);assert.deepEqual(report.diagnostics.errors,[]);
  });
  if(before)await check('Original alerts, financial, risk, evaluation and archive state unchanged',async()=>assert.equal(fingerprint(ids),before));
  report.fixture.created=created;report.summary={pass:report.checks.filter(c=>c.result==='PASS').length,fail:report.checks.filter(c=>c.result==='FAIL').length};
  const file=path.join(directory,'results.json');fs.writeFileSync(file,JSON.stringify(report,null,2)+'\n');console.table(report.checks);console.log('Summary:',report.summary);console.log('Report:',path.relative(ROOT,file));console.log(resumeId?'Retained synthetic fixtures reused; no new alerts created.':created?'Two synthetic test alerts retained; existing alerts were not claimed.':'No acceptance fixture created.');
  if(report.summary.fail)process.exitCode=1;
 }
 return report;
}
if(require.main===module)main().catch(error=>{console.error(clean(error.message));process.exitCode=1;});
module.exports={requestDecision,assertReceipt,raceSql,fingerprintSQL,fingerprint,validateRecovery,orphanHistoryIds,validateBrowserResume,trackAssets,RECOVERY_BASELINES};
