'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {ROOT,API,BANK,query,assertLocal,lit}=require('./aml-compatible-db.cjs');
const {stateSQL}=require('./case-workflow-install-tools.cjs');
const {dashboardReadiness,phaseWithDiagnostics}=require('./aml-browser-readiness.cjs');
const {networkAllowed,clean:baseClean,awaitJwtReadiness,signOutBrowserSession}=require('./verify-coreaml-kyc-browser-local.cjs');
const {trackAssets}=require('./verify-case-claim-acceptance-local.cjs');
const {awaitLoginForm}=require('./case-workflow-acceptance-tools.cjs');
const BASE='http://127.0.0.1:5520',clean=v=>baseClean(process.env.COREAML_LOCAL_PASSWORD?String(v).split(process.env.COREAML_LOCAL_PASSWORD).join('[password removed]'):v);
function requestDecision(url,method){if(!networkAllowed(url,method))return 'destination';if(url.origin===API){if(url.pathname.startsWith('/functions/v1/')||url.pathname.startsWith('/rest/v1/rpc/'))return 'mutation';if(!['GET','HEAD','OPTIONS'].includes(method)&&!(method==='POST'&&['/auth/v1/token','/auth/v1/logout'].includes(url.pathname)))return 'mutation';}if(url.origin===BASE&&!['GET','HEAD','OPTIONS'].includes(method))return 'mutation';return null;}
async function main(){
 assertLocal();const report={generated_at:new Date().toISOString(),scope:'Consolidated screens and measured officer dashboard; actual two-bank read-only browser verification',checks:[],diagnostics:{blocked:[],writes:[],errors:[],dialogs:[],phases:[],assets:[],console_errors:[]}};
 let browser,before,f,sample;
 const read=sql=>query('BEGIN READ ONLY;'+sql+'COMMIT;');
 const snapshot=()=>JSON.parse(read(`SELECT jsonb_build_object('workflow',(${stateSQL(f).replace(/;\s*$/,'')})::jsonb,'tills',(SELECT md5(coalesce(jsonb_agg(to_jsonb(t) ORDER BY id)::text,'null')) FROM public.tills t),'drafts',(SELECT md5(coalesce(jsonb_agg(to_jsonb(d) ORDER BY id)::text,'null')) FROM public.investigation_drafts d))::text;`));
 const check=async(name,fn)=>{try{await fn();report.checks.push({check:name,result:'PASS'});console.log('PASS '+name);return true;}catch(e){report.checks.push({check:name,result:'FAIL',detail:clean(e.message)});console.log('FAIL '+name+': '+clean(e.message));return false;}};
 try{
  if(!await check('Existing closed workflow fixture and linked transaction are available; no new fixture created',async()=>{
   f=JSON.parse(fs.readFileSync(path.join(ROOT,'.coreaml-local/case-workflow-install.json'),'utf8')).fixture;before=snapshot();report.before=before;
   sample=JSON.parse(read(`SELECT jsonb_build_object('customer_id',a.customer_id,'transaction_id',a.transaction_id,'reference',t.transaction_reference) FROM public.alerts a JOIN public.transactions t ON t.id=a.transaction_id WHERE a.tenant_id=${lit(BANK)} AND a.customer_id IS NOT NULL AND EXISTS(SELECT 1 FROM public.coreaml_compatible_runs r WHERE r.transaction_id=t.id) ORDER BY a.created_at DESC LIMIT 1;`));assert(sample.transaction_id&&sample.customer_id);
   const response=await fetch(BASE+'/index.html',{signal:AbortSignal.timeout(10000)});assert.equal(response.status,200);await response.body?.cancel();
   const {chromium}=require(path.join(ROOT,'.coreaml-test-tools/node_modules/playwright'));for(const channel of ['msedge','chrome']){try{browser=await chromium.launch({channel,headless:!process.argv.includes('--headed')});break;}catch{}}assert(browser,'Installed Chrome or Edge required');
  }))return;
  for(const actor of ['compliance_officer','compliance_bank2']){
   let context,page,loggedIn=false;const bank=actor==='compliance_officer'?BANK:'a1000000-0000-4000-8000-000000000002';
   try{
    if(!await check(actor+': actual login, trusted bank and dashboard readiness',async()=>{
     context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
     await context.route('**/*',route=>{const req=route.request(),url=new URL(req.url()),decision=requestDecision(url,req.method());if(decision){report.diagnostics[decision==='destination'?'blocked':'writes'].push({method:req.method(),path:url.origin+url.pathname});return route.abort('blockedbyclient');}return route.continue();});
     page=await context.newPage();page.setDefaultTimeout(30000);page.setDefaultNavigationTimeout(45000);page.on('pageerror',e=>report.diagnostics.errors.push(clean(e.message)));page.on('dialog',d=>{report.diagnostics.dialogs.push(clean(d.message()));void d.dismiss();});page.on('websocket',s=>{const u=new URL(s.url());if(u.origin!==API.replace(/^http/,'ws'))report.diagnostics.blocked.push({method:'WEBSOCKET',path:u.origin+u.pathname});});
     const info={page,actor,phases:report.diagnostics.phases};trackAssets(page,info,report.diagnostics);const phase=(name,fn)=>phaseWithDiagnostics(info,actor+'_'+name,fn,{clean});
     await phase('login_document',()=>page.goto(BASE+'/index.html',{waitUntil:'commit'}));await phase('login_form_ready',()=>awaitLoginForm(page));
     assert.equal(await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');return supabase.supabaseUrl.replace(/\/$/,'');}),API);
     await page.locator('#email').fill(actor+'@coreaml-local.test');await page.locator('#password').fill(process.env.COREAML_LOCAL_PASSWORD||'CoreAML-Local-Only!2026');await phase('actual_form_to_dashboard',()=>Promise.all([page.waitForURL(BASE+'/dashboard.html',{waitUntil:'commit'}),page.locator('#login-form button[type=submit]').click()]));loggedIn=true;
     const sec=await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.auth.getSession();if(error||!data.session)throw Error('Session missing');return data.session.user.app_metadata;});assert.equal(sec.tenant_id,bank);assert.equal(sec.role,'compliance_officer');
     await awaitJwtReadiness(()=>page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {error}=await supabase.from('alerts').select('id').limit(1).abortSignal(AbortSignal.timeout(5000));return {error:error?.message||null};}));await dashboardReadiness(page,{phase});
    }))continue;
    if(!await check(actor+': officer dashboard uses grouped case counts and explicit unavailable-data states',async()=>{
     await page.waitForFunction(()=>{const el=document.getElementById('analytics-officer-status');return el&&el.innerText&&!el.innerText.startsWith('Loading');});
     assert.doesNotMatch(await page.locator('#analytics-officer-status').innerText(),/Case metrics unavailable/);
     const officer=await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {data}=await supabase.auth.getSession();return data.session.user.id;});
     const expected=JSON.parse(read(`SELECT jsonb_build_object('open',(SELECT count(*) FROM (SELECT case_reference FROM public.alerts WHERE tenant_id=${lit(bank)} AND case_reference IS NOT NULL AND case_reference<>'' GROUP BY case_reference HAVING bool_and(status='INVESTIGATING') AND bool_and(coalesce(assigned_user_id=${lit(officer)}::uuid,false))) g),'closed',(SELECT count(*) FROM (SELECT case_reference FROM public.alerts WHERE tenant_id=${lit(bank)} AND case_reference IS NOT NULL AND case_reference<>'' GROUP BY case_reference HAVING bool_and(status='CLOSED') AND bool_and(coalesce(assigned_user_id=${lit(officer)}::uuid,false))) g),'critical',(SELECT count(*) FROM public.alerts WHERE tenant_id=${lit(bank)} AND status='UNASSIGNED' AND severity='CRITICAL'))::text;`));
     assert.equal(await page.locator('#kpi-my-cases').innerText(),String(expected.open));assert.equal(await page.locator('#kpi-my-conversion').innerText(),String(expected.closed));assert.equal(await page.locator('#kpi-critical-pool').innerText(),String(expected.critical));
     assert.equal(await page.locator('#kpi-sar-rate').innerText(),'—');assert.equal(await page.locator('#kpi-sars-filed').innerText(),'—');assert.equal(await page.locator('#kpi-resolution').innerText(),'—');
    }))continue;
    if(!await check(actor+': one customer directory and one transaction screen load without duplicate navigation',async()=>{
     assert.equal(await page.locator('#view-intelligence,#nav-intelligence-customers,#nav-intelligence-command,#nav-intelligence-transactions').count(),0);
     await page.locator('#nav-kyc').click();await page.waitForFunction(()=>document.getElementById('kyc-directory-count').innerText.length>0||document.querySelector('#kyc-directory-body [role=alert]'));assert.equal(await page.locator('#kyc-directory-body [role=alert]').count(),0);
     await page.locator('#nav-tx-monitoring').click();await page.locator('[data-form="transactions"]').waitFor();assert.equal(await page.locator('#tx-monitoring-root [role=alert]').count(),0);
    }))continue;
    if(actor==='compliance_officer'){
     await check('Existing KYC directory opens canonical Customer 360 and its connected records',async()=>{
      await page.locator('#nav-kyc').click();await page.locator('#kyc-directory-body [data-profile]').first().waitFor();await page.locator('#kyc-directory-body [data-profile]').first().click();await page.locator('#customer-related-records [data-customer-ledger]').waitFor();assert.equal(await page.locator('#customer-related-records [role=alert]').count(),0);assert.notEqual(await page.locator('#panel-entity-name').innerText(),'Customer unavailable');
      await page.locator('#customer360Panel .btn-close').click();await page.locator('#customer360Panel').waitFor({state:'hidden'});assert.equal(await page.locator('#customer-related-records').innerHTML(),'');
     });
     await check('Single Transaction Monitoring filters by reference and displays linked evidence and evaluation',async()=>{
      await page.locator('#nav-tx-monitoring').click();await page.locator('[data-form="transactions"]').waitFor();await page.locator('input[name="reference"]').fill(sample.reference);await page.getByRole('button',{name:'Apply filters',exact:true}).click();await page.locator(`button[data-transaction="${sample.transaction_id}"]`).waitFor();await page.locator(`button[data-transaction="${sample.transaction_id}"]`).click();await page.locator('.ci-transaction-hero').waitFor();assert.equal(await page.locator('.ci-title-row h2').innerText(),sample.reference);assert.equal(await page.locator('.ci-error').count(),0);assert(await page.locator('.ci-evidence').count()>0);assert(await page.locator('.ci-run').count()>0);
     });
     await check('Transaction customer link uses the same Customer 360 panel and its customer-scoped ledger',async()=>{
      await page.locator('#tx-monitoring-root [data-customer]').first().click();await page.locator('#customer-related-records [data-customer-ledger]').waitFor();assert.equal(await page.evaluate(()=>window.currentViewedCustomer.id),sample.customer_id);
      await page.locator('#customer-related-records [data-customer-ledger]').click();await page.locator('#customer360Panel').waitFor({state:'hidden'});await page.locator('[data-form="transactions"]').waitFor();assert.equal(await page.locator('#tx-monitoring-root .ci-notice').count(),1);
     });
    }else{
     await check('Other bank cannot open first-bank records through the canonical customer or transaction entry points',async()=>{
      await page.evaluate(id=>window.loadCustomerProfile(id),sample.customer_id);await page.locator('#customer-related-records [role=alert]').waitFor();assert.equal(await page.locator('#panel-entity-name').innerText(),'Customer unavailable');assert.equal(await page.locator('#customer-related-records [data-customer-ledger]').count(),0);
      await page.locator('#customer360Panel .btn-close').click();await page.locator('#customer360Panel').waitFor({state:'hidden'});
      await page.evaluate(id=>window.openTransactionMonitoring({id}),sample.transaction_id);await page.locator('.ci-error-card').waitFor();assert.match(await page.locator('.ci-error-card').innerText(),/Transaction unavailable/);assert.equal(await page.locator('.ci-transaction-hero').count(),0);
     });
    }
   }finally{if(page&&loggedIn)await check(actor+': server sign-out',()=>signOutBrowserSession(page));if(context)await context.close();}
  }
 }finally{
  if(browser)await browser.close();
  await check('No unexpected destinations, database/RPC/Edge writes, dialogs or uncaught browser errors',async()=>{for(const key of ['blocked','writes','errors','dialogs'])assert.equal(report.diagnostics[key].length,0,key+' detected');});
  if(before)await check('All existing financial, case, evidence, risk, draft and audit state remains unchanged',async()=>{report.after=snapshot();assert.deepEqual(report.after,before);});
  report.summary={pass:report.checks.filter(x=>x.result==='PASS').length,fail:report.checks.filter(x=>x.result==='FAIL').length};const output=path.join(ROOT,'.coreaml-local/intelligence-results.json');fs.mkdirSync(path.dirname(output),{recursive:true});if(fs.existsSync(output))fs.copyFileSync(output,output.replace(/\.json$/,'-before-'+Date.now()+'.json'));fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.table(report.checks);console.log('Summary:',report.summary);console.log('Report: .coreaml-local/intelligence-results.json');console.log('No database records, claims, evaluations or filings created.');if(report.summary.fail)process.exitCode=1;
 }
}
if(require.main===module)main().catch(e=>{console.error(clean(e.message));process.exitCode=1;});
module.exports={requestDecision};
