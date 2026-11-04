'use strict';
// Final controlled acceptance: only the already retained synthetic claim may change.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{randomUUID}=require('node:crypto');
const {ROOT,API,BANK,query,assertLocal}=require('./aml-compatible-db.cjs');
const {stateSQL}=require('./case-workflow-install-tools.cjs');
const {TEXT,createBoundary,fullStateSQL,validateInitial,assertState,awaitLoginForm}=require('./case-workflow-acceptance-tools.cjs');
const {dashboardReadiness,phaseWithDiagnostics}=require('./aml-browser-readiness.cjs');
const {clean:baseClean,awaitJwtReadiness,signOutBrowserSession}=require('./verify-coreaml-kyc-browser-local.cjs');
const {trackAssets}=require('./verify-case-claim-acceptance-local.cjs');
const BASE='http://127.0.0.1:5520';
const clean=v=>baseClean(process.env.COREAML_LOCAL_PASSWORD?String(v).split(process.env.COREAML_LOCAL_PASSWORD).join('[password removed]'):v);
async function main(){
 assertLocal();const runId=randomUUID(),directory=path.join(ROOT,'.coreaml-local/case-workflow-acceptance',runId);fs.mkdirSync(directory,{recursive:true});
 const output=path.join(directory,'results.json'),lockFile=path.join(directory,'..','active.lock');let lockOwned=false,browser,context,a,b,f,boundary,before,anchor,loggedIn=false;
 const report={run_id:runId,generated_at:new Date().toISOString(),scope:'Actual browser save/resume, stale tab and lost-response closure of retained synthetic claim only',checks:[],diagnostics:{blocked:[],writes:[],errors:[],dialogs:[],phases:[],assets:[],console_errors:[],route_errors:[]},checkpoints:[]};
 const write=()=>fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');
 const read=()=>JSON.parse(query('BEGIN READ ONLY;'+fullStateSQL(f,stateSQL)+'COMMIT;'));
 const checkpoint=name=>{report.checkpoints.push({name,at:new Date().toISOString()});report.requests=boundary?.attempts||[];write();};
 const check=async(name,fn)=>{try{await fn();report.checks.push({check:name,result:'PASS'});console.log('PASS '+name);write();return true;}catch(e){report.checks.push({check:name,result:'FAIL',detail:clean(e.message)});console.log('FAIL '+name+': '+clean(e.message));write();return false;}};
 const must=async(name,fn)=>{if(!await check(name,fn))throw Error('Acceptance stopped after a failed check.');};
 const status=page=>page.locator('#case-draft-status');
 async function confirmed(page,rev){await page.waitForFunction(revision=>document.getElementById('case-draft-status')?.textContent===`Draft confirmed • revision ${revision}`,rev);}
 async function pageReady(page,label){
  page.setDefaultTimeout(30000);page.setDefaultNavigationTimeout(45000);
  page.on('pageerror',e=>report.diagnostics.errors.push(clean(e.message)));
  page.on('websocket',socket=>{const url=new URL(socket.url());if(url.origin!==API.replace(/^http/,'ws'))report.diagnostics.blocked.push({method:'WEBSOCKET',path:url.origin+url.pathname});});
  page.on('dialog',async d=>{
   const message=d.message(),type=d.type();let expected=false,accept=false;
   if(type==='confirm'&&message==='Reload the saved server draft? Copy any unsaved text first; local edits will be replaced after a successful load.'&&report.dialogPhase==='reload'){expected=true;accept=true;}
   if(type==='confirm'&&message==='Close only the alert members of this claimed case using the saved narrative?'&&report.dialogPhase==='close'){expected=true;accept=true;}
   if(type==='alert'&&message.startsWith('Closure not confirmed:')&&report.dialogPhase==='close'){expected=true;}
   report.diagnostics.dialogs.push({page:label,type,message:clean(message),expected});try{if(accept)await d.accept();else await d.dismiss();}catch{}
  });
  const info={page,actor:'compliance_officer_'+label,phases:report.diagnostics.phases};trackAssets(page,info,report.diagnostics);
  return (name,fn)=>phaseWithDiagnostics(info,label+'_'+name,fn,{clean});
 }
 async function verifyOfficer(page){
  const security=await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.auth.getSession();if(error||!data.session)throw Error('Session unavailable');return {id:data.session.user.id,metadata:data.session.user.app_metadata,url:supabase.supabaseUrl.replace(/\/$/,'')};});
  assert.equal(security.url,API);assert.equal(security.id,f.owner_id);assert.equal(security.metadata.role,'compliance_officer');assert.equal(security.metadata.tenant_id,BANK);
  await awaitJwtReadiness(()=>page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {error}=await supabase.from('alerts').select('id').limit(1).abortSignal(AbortSignal.timeout(5000));return {error:error?.message||null};}));
  const p=await page.evaluate(async id=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.from('user_profiles').select('id,tenant_id,role,is_active').eq('id',id).single();if(error)throw Error(error.message);return data;},security.id);
  assert(p.is_active&&p.role==='compliance_officer'&&p.tenant_id===BANK);
 }
 async function openCase(page,revision=null){
  await page.locator('#nav-case-management').click();const row=page.locator(`#case-management-body tr[data-case-alert-id="${f.alert_ids[0]}"]`);await row.waitFor({state:'visible'});await row.getByRole('button',{name:'Open Case',exact:true}).click();await page.locator('#view-investigation-workspace').waitFor({state:'visible'});
  if(revision===null)await page.waitForFunction(()=>document.getElementById('case-draft-status')?.textContent==='Draft not yet saved.');else if(revision==='closed')await page.waitForFunction(()=>document.getElementById('case-draft-status')?.textContent==='Read-only case.');else await confirmed(page,revision);
  assert.equal(await page.locator('#inv-case-id').innerText(),f.case_reference);assert.equal(await page.locator('#sar-alert-id').inputValue(),anchor);
 }
 try{
  await must('Verified local prerequisites and pristine retained fixture; baseline journal saved',async()=>{
   try{const fd=fs.openSync(lockFile,'wx');fs.writeFileSync(fd,JSON.stringify({run_id:runId,pid:process.pid}));fs.closeSync(fd);lockOwned=true;}catch(e){throw Error('Another acceptance lock exists. Inspect the previous run before retrying; no fixture changes attempted.');}
   const install=JSON.parse(fs.readFileSync(path.join(ROOT,'.coreaml-local/case-workflow-install.json'),'utf8'));
   const readonly=JSON.parse(fs.readFileSync(path.join(ROOT,'.coreaml-local/case-workspace-readonly.json'),'utf8'));
   assert.equal(install.summary.pass,11);assert.equal(install.summary.fail,0);assert.equal(readonly.summary.pass,6);assert.equal(readonly.summary.fail,0);
   f=install.fixture;before=read();validateInitial(before,f);anchor=before.fixture.claims[0].anchor_alert_id;boundary=createBoundary(f,anchor);report.fixture=f;report.before=before;
   const response=await fetch(BASE+'/index.html',{signal:AbortSignal.timeout(10000)});assert.equal(response.status,200);await response.body?.cancel();checkpoint('Baseline saved before any browser write');
  });
  await must('Actual login and two trusted officer tabs open the same unsaved case',async()=>{
   const {chromium}=require(path.join(ROOT,'.coreaml-test-tools/node_modules/playwright'));
   for(const channel of ['msedge','chrome']){try{browser=await chromium.launch({channel,headless:!process.argv.includes('--headed')});break;}catch{}}
   assert(browser,'Installed Chrome or Edge required');context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
   await context.route('**/*',async route=>{
    const req=route.request(),url=new URL(req.url());let body;try{body=req.postDataJSON();}catch{}
    const decision=boundary.decide(url,req.method(),body);
    if(decision){report.diagnostics[decision==='destination'?'blocked':'writes'].push({method:req.method(),path:url.origin+url.pathname});return route.abort('blockedbyclient');}
    if(url.origin!==API||url.pathname!=='/rest/v1/rpc/coreaml_case_action'||req.method()!=='POST')return route.continue();
    const attempt=boundary.attempts.at(-1);checkpoint('Allowed '+attempt.phase+' request '+attempt.attempt);
    try{
     const response=await route.fetch({maxRedirects:0,timeout:20000});attempt.http_status=response.status();const data=await response.json();
     if(response.status()===200){
      assert.equal(data.request_id,body.p_request_id);assert.equal(data.alert_id,anchor);assert.equal(data.case_reference,f.case_reference);assert.equal(data.revision,body.p_expected_revision+1);assert.equal(data.status,body.p_action==='SAVE'?'IN_PROGRESS':'CLOSED');assert.equal(typeof data.replayed,'boolean');attempt.receipt=data;
     }else{attempt.rejection={code:data.code,message:clean(data.message)};}
     if(attempt.drop){assert.equal(response.status(),200,'Only a confirmed committed response may be dropped');assert.equal(data.replayed,false);attempt.dropped_committed_response=true;checkpoint('Committed '+attempt.phase+' response deliberately dropped');return route.abort('failed');}
     checkpoint('Response received for '+attempt.phase+' request '+attempt.attempt);return route.fulfill({response});
    }catch(e){report.diagnostics.route_errors.push(clean(e.message));checkpoint('Route failure');return route.abort('failed');}
   });
   a=await context.newPage();const phaseA=await pageReady(a,'A');
   await phaseA('login_document_commit',()=>a.goto(BASE+'/index.html',{waitUntil:'commit'}));
   console.log('Waiting for the actual login document and form…');
   await phaseA('login_document_and_form_ready',()=>awaitLoginForm(a));
   assert.equal(await a.evaluate(async()=>{const {supabase}=await import('/js/config.js');return supabase.supabaseUrl.replace(/\/$/,'');}),API);
   await a.locator('#email').fill('compliance_officer@coreaml-local.test');await a.locator('#password').fill(process.env.COREAML_LOCAL_PASSWORD||'CoreAML-Local-Only!2026');
   await phaseA('actual_form_to_dashboard_commit',()=>Promise.all([a.waitForURL(BASE+'/dashboard.html',{waitUntil:'commit'}),a.locator('#login-form button[type=submit]').click()]));loggedIn=true;
   await verifyOfficer(a);await dashboardReadiness(a,{phase:phaseA});
   b=await context.newPage();const phaseB=await pageReady(b,'B');await phaseB('dashboard_commit',()=>b.goto(BASE+'/dashboard.html',{waitUntil:'commit'}));await verifyOfficer(b);await dashboardReadiness(b,{phase:phaseB});
   await openCase(a);await openCase(b);assert.deepEqual(read(),before);
  });
  await must('Lost save response stays unconfirmed; exact retry creates one draft and audit',async()=>{
   boundary.arm('initial');await a.locator('#inv-narrative-box').fill(TEXT.initial);
   await a.waitForFunction(()=>/failed|fetch|network|timed out|incomplete|retry/i.test(document.getElementById('case-draft-status')?.textContent||''));
   assert.equal(await a.locator('#view-investigation-workspace').isVisible(),true);assert(!(await status(a).innerText()).startsWith('Draft confirmed'));
   assertState(before,read(),f,1,boundary.attempts);
   await a.locator('#btn-case-retry').click();await confirmed(a,1);boundary.disarm();
   const attempts=boundary.attempts.filter(x=>x.phase==='initial');assert.equal(attempts.length,2);assert(attempts[0].dropped_committed_response);assert.deepEqual(attempts[0].body,attempts[1].body);assert.equal(attempts[1].receipt.replayed,true);assertState(before,read(),f,1,boundary.attempts);checkpoint('Initial save and exact retry verified');
  });
  await must('Stale second-tab edit is rejected and cannot overwrite the saved draft',async()=>{
   const saved=read();boundary.arm('stale');await b.locator('#inv-narrative-box').fill(TEXT.stale);
   await b.waitForFunction(()=>/changed elsewhere|revision conflict/i.test(document.getElementById('case-draft-status')?.textContent||''));boundary.disarm();
   assert.equal(await b.locator('#inv-narrative-box').inputValue(),TEXT.stale);assert.equal(await b.locator('#inv-narrative-box').getAttribute('readonly')!==null,true);assert.equal(await b.locator('#btn-case-retry').isDisabled(),true);
   const attempted=boundary.attempts.find(x=>x.phase==='stale');assert(attempted.http_status>=400&&attempted.http_status<500);assert.match(attempted.rejection.message,/revision conflict/i);assert.deepEqual(read(),saved);checkpoint('Stale edit rejected without data change');
  });
  await must('Save and Exit then Resume Draft recover the confirmed narrative and pins',async()=>{
   const saved=read();await a.locator('#btn-case-save').click();await a.locator('#view-case-management').waitFor({state:'visible'});
   await a.locator('#btn-resume-draft').waitFor({state:'visible'});await a.locator('#btn-resume-draft').click();await a.locator('#view-investigation-workspace').waitFor({state:'visible'});await confirmed(a,1);
   assert.equal(await a.locator('#inv-narrative-box').inputValue(),TEXT.initial);assert.equal(await a.locator('#inv-entity-count').innerText(),'1');assert.equal(await a.locator('#inv-tx-count').innerText(),'0');assert.equal(await a.locator('#inv-case-id').innerText(),f.case_reference);assert.equal(await a.locator('#sar-alert-id').inputValue(),anchor);assert.deepEqual(read(),saved);
   report.dialogPhase='reload';await b.locator('#btn-case-reload').click();await confirmed(b,1);delete report.dialogPhase;assert.equal(await b.locator('#inv-narrative-box').inputValue(),TEXT.initial);assert.equal(await b.locator('#inv-narrative-box').getAttribute('readonly'),null);assert.deepEqual(read(),saved);checkpoint('Saved draft resumed and stale tab explicitly reloaded');
  });
  await must('Final narrative saves as the next revision without changing alert evidence or risk',async()=>{
   boundary.arm('final');await a.locator('#inv-narrative-box').fill(TEXT.final);await confirmed(a,2);boundary.disarm();assertState(before,read(),f,2,boundary.attempts);checkpoint('Final draft saved');
  });
  await must('Lost closure reply locks editing; retry confirms one atomic group closure',async()=>{
   boundary.arm('close');report.dialogPhase='close';await a.locator('#btn-case-close').click();
   await a.waitForFunction(()=>document.getElementById('btn-case-close')?.innerText==='Retry Closure Confirmation');
   assert.equal(await a.locator('#view-investigation-workspace').isVisible(),true);assert.equal(await a.locator('#inv-narrative-box').getAttribute('readonly')!==null,true);assert.equal(await a.locator('#btn-case-retry').isDisabled(),true);assert.equal(await a.locator('#btn-case-save').isDisabled(),true);assert.equal(await a.locator('#btn-case-reload').isDisabled(),true);
   assertState(before,read(),f,3,boundary.attempts);
   await a.locator('#btn-case-close').click();await a.locator('#view-case-management').waitFor({state:'visible'});boundary.disarm();delete report.dialogPhase;
   const attempts=boundary.attempts.filter(x=>x.phase==='close');assert.equal(attempts.length,2);assert(attempts[0].dropped_committed_response);assert.deepEqual(attempts[0].body,attempts[1].body);assert.equal(attempts[1].receipt.replayed,true);assertState(before,read(),f,3,boundary.attempts);checkpoint('Closure retry verified with one receipt and audit');
  });
  await must('Closed case reopens read-only with final narrative and no further writes',async()=>{
   const closed=read();await openCase(a,'closed');assert.equal(await a.locator('#inv-narrative-box').inputValue(),TEXT.final);for(const selector of ['#btn-case-retry','#btn-case-save','#btn-case-close'])assert.equal(await a.locator(selector).isDisabled(),true);assert.equal(await a.locator('#inv-narrative-box').getAttribute('readonly')!==null,true);assert.deepEqual(read(),closed);checkpoint('Closed workspace verified');
  });
 }catch(e){report.stopped=clean(e.message);}
 finally{
  boundary?.disarm();
  if(a)await check('Shared browser session cleanup is verified through the server',async()=>{
   const hasSession=await a.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.auth.getSession();if(error)throw Error(error.message);return !!data.session;});
   if(!hasSession){assert(!loggedIn,'An expected signed-in session disappeared before verified sign-out');return;}
   await signOutBrowserSession(a);
  });
  if(context)await context.close().catch(e=>report.diagnostics.errors.push(clean(e.message)));if(browser)await browser.close().catch(()=>{});
  await check('No unexpected destinations, mutations, dialogs, route errors or uncaught errors',async()=>{
   for(const key of ['blocked','writes','errors','route_errors'])assert.equal(report.diagnostics[key].length,0,key+' detected');assert(report.diagnostics.dialogs.every(d=>d.expected),'Unexpected dialog');
   if(!report.stopped){assert.equal(boundary.attempts.length,6);assert.equal(boundary.attempts.filter(x=>x.dropped_committed_response).length,2);assert.equal(report.diagnostics.dialogs.filter(d=>d.type==='confirm').length,2);assert.equal(report.diagnostics.dialogs.filter(d=>d.type==='alert').length,1);}
  });
  if(before&&boundary)await check('Retained test changes reconcile; all unrelated records, claim, evidence and risk remain unchanged',async()=>{
   const after=read();report.after=after;const committed=['initial','final','close'].filter(name=>{const attempt=boundary.attempts.find(x=>x.phase===name);return attempt&&after.actions.some(r=>r.request_id===attempt.body.p_request_id);}).length;
   report.committed_action_count=committed;assertState(before,after,f,committed,boundary.attempts);
  });
  report.requests=boundary?.attempts||[];
  report.summary={pass:report.checks.filter(c=>c.result==='PASS').length,fail:report.checks.filter(c=>c.result==='FAIL').length,completed:!report.stopped&&report.checks.filter(c=>c.result==='FAIL').length===0&&report.committed_action_count===3};
  if(!report.summary.completed&&report.summary.fail===0){report.checks.push({check:'Acceptance completed',result:'FAIL',detail:report.stopped||'Acceptance stopped before all actions were confirmed'});report.summary.fail++;}
  write();if(lockOwned)fs.unlinkSync(lockFile);console.table(report.checks);console.log('Summary:',report.summary);console.log('Report:',path.relative(ROOT,output));console.log('Retained synthetic case only; no new customers, alerts, cash, evaluations or filings.');
  if(!report.summary.completed){process.exitCode=1;console.log('Do not reset or rerun a partially changed fixture. Share this report for reconciliation.');}
 }
}
if(require.main===module)main().catch(e=>{console.error(clean(e.message));process.exitCode=1;});
module.exports={main};
