'use strict';
// Opens the retained claimed case through the actual UI. All mutations are blocked.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {ROOT,API,BANK,query,assertLocal}=require('./aml-compatible-db.cjs');
const {validateFixture}=require('./customer-linked-native-tools.cjs');
const {stateSQL}=require('./case-workflow-install-tools.cjs');
const {dashboardReadiness,phaseWithDiagnostics}=require('./aml-browser-readiness.cjs');
const {networkAllowed,clean:baseClean,awaitJwtReadiness,signOutBrowserSession}=require('./verify-coreaml-kyc-browser-local.cjs');
const {trackAssets}=require('./verify-case-claim-acceptance-local.cjs');
const BASE='http://127.0.0.1:5520';
const clean=value=>baseClean(process.env.COREAML_LOCAL_PASSWORD?String(value).split(process.env.COREAML_LOCAL_PASSWORD).join('[password removed]'):value);
function requestDecision(url,method,body,ids){
 if(!networkAllowed(url,method))return 'destination';
 if(url.origin===API){
  if(url.pathname.startsWith('/functions/v1/'))return 'mutation';
  if(url.pathname.startsWith('/rest/v1/rpc/')){
   if(url.pathname!=='/rest/v1/rpc/coreaml_load_case_draft')return 'mutation';
   if(method==='OPTIONS')return null;
   return method==='POST'&&body&&Object.keys(body).length===1&&ids.includes(body.p_alert_id)?null:'mutation';
  }
  if(!['GET','HEAD','OPTIONS'].includes(method)&&!(method==='POST'&&['/auth/v1/token','/auth/v1/logout'].includes(url.pathname)))return 'mutation';
 }
 if(url.origin===BASE&&!['GET','HEAD','OPTIONS'].includes(method))return 'mutation';
 return null;
}
async function main(){
 assertLocal();let browser,context,page,before,fixture;
 const report={generated_at:new Date().toISOString(),scope:'Read-only actual case workspace; no draft save or closure permitted',checks:[],diagnostics:{blocked:[],writes:[],errors:[],dialogs:[],phases:[],assets:[],console_errors:[]}};
 const check=async(name,fn)=>{try{await fn();report.checks.push({check:name,result:'PASS'});return true;}catch(e){report.checks.push({check:name,result:'FAIL',detail:clean(e.message)});return false;}};
 try{
  if(!await check('Installed foundation and retained claimed fixture are available',async()=>{
   const install=JSON.parse(fs.readFileSync(path.join(ROOT,'.coreaml-local/case-workflow-install.json'),'utf8'));
   assert.equal(install.summary.pass,11);assert.equal(install.summary.fail,0);fixture=install.fixture;validateFixture(fixture);
   assert.equal(fixture.marker,'GroupClaimTest-b4b94f13-5991-4436-8692-b19c8665b92c');
   before=JSON.parse(query('BEGIN READ ONLY;'+stateSQL(fixture)+'COMMIT;'));
   assert.equal(before.fixture.claims.length,1);assert.equal(before.fixture.claims[0].case_reference,fixture.case_reference);assert(before.fixture.alerts.every(a=>a.status==='INVESTIGATING'&&a.assigned_user_id===fixture.owner_id));
   const response=await fetch(BASE+'/index.html',{signal:AbortSignal.timeout(10000)});assert.equal(response.status,200);await response.body?.cancel();
  }))return;
  if(!await check('Actual login, trusted officer profile and dashboard handlers are ready',async()=>{
   const {chromium}=require(path.join(ROOT,'.coreaml-test-tools/node_modules/playwright'));
   for(const channel of ['msedge','chrome']){try{browser=await chromium.launch({channel,headless:!process.argv.includes('--headed')});break;}catch{}}
   assert(browser,'Installed Chrome or Edge required');context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
   await context.route('**/*',route=>{const req=route.request(),url=new URL(req.url());let body;try{body=req.postDataJSON();}catch{}const decision=requestDecision(url,req.method(),body,fixture.alert_ids);if(decision){report.diagnostics[decision==='destination'?'blocked':'writes'].push({method:req.method(),path:url.origin+url.pathname});return route.abort('blockedbyclient');}return route.continue();});
   page=await context.newPage();page.setDefaultTimeout(30000);page.setDefaultNavigationTimeout(45000);
   page.on('websocket',socket=>{const url=new URL(socket.url());if(url.origin!==API.replace(/^http/,'ws'))report.diagnostics.blocked.push({method:'WEBSOCKET',path:url.origin+url.pathname});});
   page.on('pageerror',e=>report.diagnostics.errors.push(clean(e.message)));page.on('dialog',d=>{report.diagnostics.dialogs.push(clean(d.message()));void d.dismiss();});
   const info={page,actor:'compliance_officer',phases:report.diagnostics.phases};trackAssets(page,info,report.diagnostics);
   const phase=(name,fn)=>phaseWithDiagnostics(info,name,fn,{clean});
   await phase('login_document_commit',()=>page.goto(BASE+'/index.html',{waitUntil:'commit'}));
   assert.equal(await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');return supabase.supabaseUrl.replace(/\/$/,'');}),API);
   await page.locator('#email').fill('compliance_officer@coreaml-local.test');await page.locator('#password').fill(process.env.COREAML_LOCAL_PASSWORD||'CoreAML-Local-Only!2026');
   await phase('actual_form_to_dashboard_commit',()=>Promise.all([page.waitForURL(BASE+'/dashboard.html',{waitUntil:'commit'}),page.locator('#login-form button[type=submit]').click()]));
   const security=await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.auth.getSession();if(error||!data.session)throw Error('Session unavailable');return {id:data.session.user.id,metadata:data.session.user.app_metadata};});
   assert.equal(security.id,fixture.owner_id);assert.equal(security.metadata.role,'compliance_officer');assert.equal(security.metadata.tenant_id,BANK);
   await awaitJwtReadiness(()=>page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {error}=await supabase.from('alerts').select('id').limit(1).abortSignal(AbortSignal.timeout(5000));return {error:error?.message||null};}));
   const profile=await page.evaluate(async id=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.from('user_profiles').select('id,tenant_id,role,is_active').eq('id',id).single();if(error)throw Error(error.message);return data;},security.id);
   assert(profile.is_active&&profile.role==='compliance_officer'&&profile.tenant_id===BANK);await dashboardReadiness(page,{phase});
  }))return;
  await check('Actual Open Case button loads canonical claimed workspace without saving',async()=>{
   await page.locator('#nav-case-management').click();
   const row=page.locator(`#case-management-body tr[data-case-alert-id="${fixture.alert_ids[0]}"]`);await row.waitFor({state:'visible'});
   await row.getByRole('button',{name:'Open Case',exact:true}).click();
   await page.locator('#view-investigation-workspace').waitFor({state:'visible'});
   await page.waitForFunction(()=>{const status=document.getElementById('case-draft-status')?.textContent;return status==='Draft not yet saved.'||status?.startsWith('Draft confirmed');});
   assert.equal(await page.locator('#inv-case-id').innerText(),fixture.case_reference);
   assert.equal(await page.locator('#sar-alert-id').inputValue(),before.fixture.claims[0].anchor_alert_id);
   assert.equal(await page.locator('#inv-narrative-box').getAttribute('readonly'),null);
   assert.equal(await page.locator('#btn-case-retry').isEnabled(),true);assert.equal(await page.locator('#btn-case-close').isEnabled(),true);
   assert.equal(await page.locator('[onclick="escalateCase()"]').isDisabled(),true);
  });
 }finally{
  if(page)await check('Browser server sign-out completes',()=>signOutBrowserSession(page));
  if(context)await context.close();if(browser)await browser.close();
  await check('No unexpected destinations, writes, dialogs or uncaught errors',async()=>{for(const key of ['blocked','writes','dialogs','errors'])assert.equal(report.diagnostics[key].length,0,key+' detected');});
  if(before)await check('All original records, claim, risk, drafts and action receipts remain unchanged',async()=>assert.deepEqual(JSON.parse(query('BEGIN READ ONLY;'+stateSQL(fixture)+'COMMIT;')),before));
  report.summary={pass:report.checks.filter(c=>c.result==='PASS').length,fail:report.checks.filter(c=>c.result==='FAIL').length};
  const output=path.join(ROOT,'.coreaml-local/case-workspace-readonly.json');fs.mkdirSync(path.dirname(output),{recursive:true});if(fs.existsSync(output))fs.copyFileSync(output,output.replace(/\.json$/,'-before-'+Date.now()+'.json'));fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.table(report.checks);console.log('Summary:',report.summary);console.log('Report: .coreaml-local/case-workspace-readonly.json');console.log('No draft saves or closures were permitted.');if(report.summary.fail)process.exitCode=1;
 }
}
if(require.main===module)main().catch(e=>{console.error(clean(e.message));process.exitCode=1;});
module.exports={requestDecision};
