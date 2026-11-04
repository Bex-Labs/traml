// Read-only browser verification of the existing compatible AML fixture.
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {ROOT,API,BANK,query,assertLocal,lit}=require('./aml-compatible-db.cjs');
const {dashboardReadiness,phaseWithDiagnostics}=require('./aml-browser-readiness.cjs');
const {networkAllowed,clean:baseClean,awaitJwtReadiness,signOutBrowserSession}=require('./verify-coreaml-kyc-browser-local.cjs');
const clean=value=>baseClean(process.env.COREAML_LOCAL_PASSWORD?String(value).split(process.env.COREAML_LOCAL_PASSWORD).join('[password removed]'):value);
const BASE='http://127.0.0.1:5520',OUT=path.join(ROOT,'.coreaml-local/aml-browser');
const report={generated_at:new Date().toISOString(),scope:'Actual local officer queue, recorded alert evidence, linked ledger reads and cross-bank denial',checks:[],observations:[],limitations:['Uses the existing successful compatible-integration fixture; creates no customers, deposits, claims or evaluations.','Auth login/sign-out changes local sessions. Every database/Edge mutation from the browser is blocked and reported.','No claim, investigation, SAR/CTR submission, rule tuning, sanctions or full admin workflow is tested.','CTR remains POLICY_BLOCKED / NOT_FILED; evidence display is not policy approval.']};
const states=new Map(),sessions=[];let fixture,alerts,before,browser;
const uuid=s=>typeof s==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
const read=sql=>query('BEGIN TRANSACTION READ ONLY;'+sql+'COMMIT;');
async function check(name,fn,deps=[]){if(deps.some(d=>states.get(d)!=='PASS')){states.set(name,'BLOCKED');report.checks.push({check:name,result:'BLOCKED',detail:'Required earlier check failed'});return;}try{await fn();states.set(name,'PASS');report.checks.push({check:name,result:'PASS'});}catch(e){states.set(name,'FAIL');report.checks.push({check:name,result:'FAIL',detail:clean(e.message)});}}
function fingerprint(){return read(`SELECT md5(jsonb_build_object('customer',(SELECT to_jsonb(c) FROM public.customers c WHERE id=${lit(fixture.customerId)}::uuid),'account',(SELECT to_jsonb(a) FROM public.accounts a WHERE id=${lit(fixture.accountId)}::uuid),'till',(SELECT to_jsonb(t) FROM public.tills t WHERE id=${lit(fixture.tillId)}::uuid),'transactions',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.transactions t WHERE account_id=${lit(fixture.accountId)}::uuid),'alerts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.alerts a WHERE customer_id=${lit(fixture.customerId)}::uuid),'runs',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.coreaml_compatible_runs r WHERE set_id=${lit(fixture.setId)}::uuid),'results',(SELECT jsonb_agg(to_jsonb(r) ORDER BY id) FROM public.coreaml_compatible_results r WHERE transaction_id IN(SELECT id FROM public.transactions WHERE account_id=${lit(fixture.accountId)}::uuid)),'receipts',(SELECT jsonb_agg(to_jsonb(o) ORDER BY transaction_id) FROM public.transaction_evaluation_outbox o WHERE transaction_id IN(SELECT id FROM public.transactions WHERE account_id=${lit(fixture.accountId)}::uuid)),'risk_history',(SELECT jsonb_agg(to_jsonb(h) ORDER BY id) FROM public.risk_score_history h WHERE customer_id=${lit(fixture.customerId)}::uuid),'archive_count',(SELECT count(*) FROM public.report_archives),'transaction_count',(SELECT count(*) FROM public.transactions),'alert_count',(SELECT count(*) FROM public.alerts),'ctr_filing_event_count',(SELECT count(*) FROM public.system_events WHERE event_type='CTR_AUTO_FILED'))::text);`);}
function requestDecision(url,method){
 if(!networkAllowed(url,method))return 'destination';
 if(url.origin===API){
  if(url.pathname.startsWith('/rest/v1/rpc/')||url.pathname.startsWith('/functions/v1/'))return 'mutation';
  const allowedAuth=method==='POST'&&['/auth/v1/token','/auth/v1/logout'].includes(url.pathname);
  if(!['GET','HEAD','OPTIONS'].includes(method)&&!allowedAuth)return 'mutation';
 }
 if(url.origin===BASE&&!['GET','HEAD','OPTIONS'].includes(method))return 'mutation';
 return null;
}
async function login(actor){
 const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'}),info={actor,context,blocked:[],writes:[],errors:[],reads:[],phases:[],assets:[],console_errors:[],loggedIn:false};sessions.push(info);
 await context.route('**/*',async route=>{const r=route.request(),url=new URL(r.url()),method=r.method();
  const decision=requestDecision(url,method);
  if(decision==='destination'){info.blocked.push(url.origin+url.pathname);return route.abort('blockedbyclient');}
  if(decision==='mutation'){info.writes.push({method,path:url.pathname});return route.abort('blockedbyclient');}
  if(url.origin===API){
   if(method==='GET'&&url.pathname.startsWith('/rest/v1/'))info.reads.push({table:url.pathname.slice('/rest/v1/'.length),id:url.searchParams.get('id'),columns:url.searchParams.get('select')});
  }return route.continue();
 });
 const page=await context.newPage();info.page=page;page.setDefaultTimeout(30000);page.setDefaultNavigationTimeout(45000);
 page.on('pageerror',e=>info.errors.push(clean(e.message)));
 const requests=new Map();
 page.on('request',request=>{const url=new URL(request.url());if(['document','script','stylesheet'].includes(request.resourceType())||(url.origin===API&&(url.pathname.startsWith('/rest/v1/')||url.pathname.startsWith('/auth/v1/')))){if(info.assets.length>=250)return;const entry={method:request.method(),path:clean(url.origin+url.pathname),type:request.resourceType(),phase:info.phase||'initial',started_at:new Date().toISOString(),status:'PENDING'};info.assets.push(entry);requests.set(request,{entry,start:Date.now()});}});
 page.on('response',response=>{const pending=requests.get(response.request());if(pending){pending.entry.http_status=response.status();pending.entry.headers_after_ms=Date.now()-pending.start;}});
 page.on('requestfinished',request=>{const pending=requests.get(request);if(pending){pending.entry.status='FINISHED';pending.entry.elapsed_ms=Date.now()-pending.start;requests.delete(request);}});
 page.on('requestfailed',request=>{const pending=requests.get(request);if(pending){pending.entry.status='FAILED';pending.entry.error=clean(request.failure()?.errorText||'Request failed');pending.entry.elapsed_ms=Date.now()-pending.start;requests.delete(request);}});
 page.on('console',message=>{if(message.type()==='error'&&info.console_errors.length<30)info.console_errors.push(clean(message.text()));});
 const phase=(name,fn)=>phaseWithDiagnostics(info,name,fn,{clean});
 page.on('websocket',socket=>{const url=new URL(socket.url());if(url.origin!=='ws://127.0.0.1:55321')info.blocked.push(url.origin+url.pathname);});
 page.on('dialog',d=>{report.observations.push({actor,kind:'Unexpected dialog',message:clean(d.message())});d.dismiss().catch(()=>{});});
 await phase('login_document_commit',()=>page.goto(BASE+'/index.html',{waitUntil:'commit'}));
 const configured=await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');return supabase.supabaseUrl;});assert.equal(configured.replace(/\/$/,''),API,'Refusing credentials for a nonlocal backend');
 // Probe the same configured Auth origin from this browser, without credentials.
 await phase('browser_auth_health',async()=>{
  const health=await page.evaluate(async api=>{
   try { const response=await fetch(api+'/auth/v1/health',{signal:AbortSignal.timeout(10000)});return {status:response.status}; }
   catch { return {error:'Auth health request failed or timed out'}; }
  },API);
  assert(!health.error,'Browser cannot reach '+API+'/auth/v1/health; check the configured local stack, port and browser connectivity');
  assert.equal(health.status,200,'Auth health at '+API+' returned HTTP '+health.status);
 });
 await page.locator('#email').fill(actor+'@coreaml-local.test');await page.locator('#password').fill(process.env.COREAML_LOCAL_PASSWORD||'CoreAML-Local-Only!2026');
 await phase('actual_form_to_dashboard_commit',()=>Promise.all([page.waitForURL(BASE+'/dashboard.html',{waitUntil:'commit'}),page.locator('#login-form button[type=submit]').click()]));
 info.loggedIn=true;
 const security=await phase('browser_session',()=>page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.auth.getSession();if(error||!data.session)throw Error('Browser session missing');return {id:data.session.user.id,metadata:data.session.user.app_metadata};}));
 const bank=actor==='compliance_bank2'?'a1000000-0000-4000-8000-000000000002':BANK;assert.equal(security.metadata.role,'compliance_officer');assert.equal(security.metadata.tenant_id,bank);
 await phase('authenticated_read_readiness',()=>awaitJwtReadiness(()=>page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {error}=await supabase.from('alerts').select('id').limit(1).abortSignal(AbortSignal.timeout(5000));return {error:error?.message||null};})));
 const profile=await phase('trusted_profile_read',()=>page.evaluate(async id=>{const {supabase}=await import('/js/config.js');const r=await supabase.from('user_profiles').select('id,role,tenant_id,is_active').eq('id',id).limit(1);if(r.error)throw Error(r.error.message);return r.data?.[0];},security.id));assert(profile&&profile.is_active&&profile.role==='compliance_officer'&&profile.tenant_id===bank);
 await dashboardReadiness(page,{phase});
 return info;
}
async function scanQueue(info,review){const page=info.page,seen=new Set();for(let p=0;p<50;p++){
 const ids=await page.locator('#alerts-table-body tr.main-alert-row').evaluateAll(rows=>rows.map(r=>r.dataset.alertId));
 for(const id of ids){if(!alerts.some(a=>a.id===id))continue;seen.add(id);if(review)await review(alerts.find(a=>a.id===id));}
 const next=page.locator('#alerts-pagination-controls li').filter({has:page.getByRole('link',{name:'Next',exact:true})});
 if(await next.count()===0||await next.evaluate(n=>n.classList.contains('disabled')))return seen;
 const previous=ids.join(',');await next.getByRole('link',{name:'Next',exact:true}).click();await page.waitForFunction(old=>[...document.querySelectorAll('#alerts-table-body tr.main-alert-row')].map(r=>r.dataset.alertId).join(',')!==old,previous);
 }throw Error('Queue scan exceeded fifty pages; fixture visibility not established');}
async function reviewAlert(info,a){const p=info.page;
 const row=p.locator(`#alerts-table-body tr[data-alert-id="${a.id}"]`);assert.equal(await row.locator('td').nth(0).innerText(),a.alert_ref);assert.equal(await row.locator('td').nth(2).innerText(),a.rule_triggered);
 await row.getByRole('button',{name:'Review Case',exact:true}).click();
 await p.locator('#alertPreviewModal').waitFor({state:'visible'});
 await p.waitForFunction(id=>document.querySelector('#preview-evidence-panel')?.dataset.state==='ready'&&document.querySelector('#preview-evidence-panel')?.dataset.alertId===id,a.id);
 assert.equal(await p.locator('#preview-engine-context').innerText(),a.details);
 const fields=await p.locator('#preview-evidence-fields').innerText();for(const value of[a.evidence.rule_snapshot.id,a.evidence.transaction_reference,'POLICY_BLOCKED','NOT_FILED'])assert(fields.includes(value),'Missing recorded field: '+value);
 const expected=a.evidence.evidence.supporting_transactions||[],shown=await p.locator('#preview-evidence-transactions tbody tr').evaluateAll(rows=>rows.map(r=>r.dataset.transactionId));assert.deepEqual(shown,expected.slice(0,200).map(t=>t.id));
 await p.locator('#preview-evidence-ledger').click();await p.waitForFunction(()=>document.querySelector('#preview-evidence-ledger-result')?.dataset.state==='verified');assert((await p.locator('#preview-evidence-ledger-result').innerText()).includes(a.evidence.transaction_reference));
 report.reviewed_alerts.push({id:a.id,rule_id:a.evidence.rule_snapshot.id,transaction_id:a.transaction_id,supporting_count:expected.length});
 await p.locator('#alertPreviewModal').getByRole('button',{name:'Leave in Pool',exact:true}).click();await p.locator('#alertPreviewModal').waitFor({state:'hidden'});
}
async function main(){assertLocal();
 await check('Existing successful fixture and sealed database evidence are valid',async()=>{
  const prior=JSON.parse(fs.readFileSync(path.join(ROOT,'.coreaml-local/aml-compatible-verification.json'),'utf8'));assert.equal(prior.summary?.fail,0);assert.equal(prior.summary?.blocked,0);assert.equal(prior.final_counts?.alerts,8);fixture=prior.fixture;for(const k of['customerId','accountId','setId','tillId'])assert(uuid(fixture?.[k]),'Invalid fixture '+k);assert(/^AmlCompatTest[0-9a-f]{8}$/.test(fixture.marker));
  assert.equal(read(`SELECT EXISTS(SELECT 1 FROM public.accounts a JOIN public.customers c ON c.id=a.customer_id JOIN public.coreaml_compatible_sets s ON s.account_id=a.id WHERE a.id=${lit(fixture.accountId)}::uuid AND c.id=${lit(fixture.customerId)}::uuid AND s.id=${lit(fixture.setId)}::uuid AND c.first_name='Synthetic' AND c.last_name=${lit(fixture.marker)} AND c.tenant_id=${lit(BANK)} AND s.tenant_id=c.tenant_id);`),'t');
  alerts=JSON.parse(read(`SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY id),'[]'::jsonb) FROM public.alerts a WHERE customer_id=${lit(fixture.customerId)}::uuid;`));assert.equal(alerts.length,8);assert(alerts.every(a=>a.status==='UNASSIGNED'&&a.evidence?.set_id===fixture.setId&&a.evidence?.filing_status==='NOT_FILED'));before=fingerprint();report.fixture={...fixture};report.reviewed_alerts=[];
 });
 await check('Local application server is reachable',async()=>{const r=await fetch(BASE+'/index.html',{redirect:'error',signal:AbortSignal.timeout(10000)});assert.equal(r.status,200,'Start local Python server on port 5520');await r.body?.cancel();},['Existing successful fixture and sealed database evidence are valid']);
 if(states.get('Local application server is reachable')!=='PASS')return;
 const {chromium}=require(path.join(ROOT,'.coreaml-test-tools/node_modules/playwright'));for(const channel of['msedge','chrome']){try{browser=await chromium.launch({channel,headless:!process.argv.includes('--headed')});break;}catch{}}assert(browser,'Installed Edge or Chrome required');
 let officer,other;
 try{
  await check('Officer logs in through actual form with trusted bank and role',async()=>{officer=await login('compliance_officer');});
  await check('Actual queue and modal display all eight alerts and linked evidence',async()=>{const seen=await scanQueue(officer,a=>reviewAlert(officer,a));assert.equal(seen.size,8);assert.equal(report.reviewed_alerts.length,8);const required=['alerts','transactions','coreaml_compatible_runs'];for(const table of required)assert(officer.reads.some(r=>r.table===table),'Missing actual read: '+table);},['Officer logs in through actual form with trusted bank and role']);
  await check('Another bank logs in through actual form with trusted bank and role',async()=>{other=await login('compliance_bank2');});
  await check('Other-bank queue excludes all eight fixture alerts',async()=>assert.equal((await scanQueue(other)).size,0),['Another bank logs in through actual form with trusted bank and role']);
  await check('Direct preview reference and ledger read cannot expose another bank',async()=>{const a=alerts[0];await other.page.evaluate(id=>window.previewUnassignedAlert(id,'Restricted alert','Unavailable','Unavailable'),a.id);await other.page.locator('#alertPreviewModal').waitFor({state:'visible'});await other.page.waitForFunction(()=>document.querySelector('#preview-evidence-panel')?.dataset.state==='unavailable');assert.equal((await other.page.locator('#preview-evidence-fields').innerText()).trim(),'');assert.equal((await other.page.locator('#preview-evidence-transactions').innerText()).trim(),'');assert(await other.page.locator('#preview-evidence-ledger').isHidden());const ledger=await other.page.evaluate(async id=>{const service=await import('/js/services/alerts.service.js');return service.getEvidenceTransaction(id);},a.transaction_id);assert.equal(ledger,null);await other.page.locator('#alertPreviewModal').getByRole('button',{name:'Leave in Pool',exact:true}).click();},['Other-bank queue excludes all eight fixture alerts']);
 }finally{
  for(const info of sessions){if(info.loggedIn)await check(info.actor+': browser server sign-out',async()=>await signOutBrowserSession(info.page));await check(info.actor+': no unexpected destinations or database mutations',async()=>{assert.deepEqual(info.blocked,[]);assert.deepEqual(info.writes,[]);});await check(info.actor+': no uncaught browser errors',async()=>assert.deepEqual(info.errors,[]));await info.context.close();}
  report.diagnostics=sessions.map(({actor,phase,phases,assets,console_errors,errors,blocked,writes})=>({actor,last_phase:phase,phases,assets,console_errors,uncaught_errors:errors,blocked_destinations:blocked,blocked_writes:writes}));
  await browser.close();browser=null;
  await check('Existing financial, alert, risk and evaluation state remains unchanged',async()=>assert.equal(fingerprint(),before));
 }
}
if(require.main===module)main().catch(e=>report.checks.push({check:'Browser prerequisites/execution',result:'FAIL',detail:clean(e.message)})).finally(async()=>{if(browser)await browser.close().catch(()=>{});report.summary={pass:report.checks.filter(c=>c.result==='PASS').length,fail:report.checks.filter(c=>c.result==='FAIL').length,blocked:report.checks.filter(c=>c.result==='BLOCKED').length,reviewed_alerts:report.reviewed_alerts?.length||0};fs.mkdirSync(OUT,{recursive:true});const resultFile=path.join(OUT,'results.json');if(fs.existsSync(resultFile))fs.copyFileSync(resultFile,path.join(OUT,'results-before-'+Date.now()+'.json'));fs.writeFileSync(resultFile,JSON.stringify(report,null,2)+'\n');console.table(report.checks);console.log('Summary:',report.summary);console.log('Report: .coreaml-local/aml-browser/results.json');console.log('No new cash, claims, evaluations or filings.');if(report.summary.fail||report.summary.blocked||report.observations.length)process.exitCode=1;});

module.exports={requestDecision};
