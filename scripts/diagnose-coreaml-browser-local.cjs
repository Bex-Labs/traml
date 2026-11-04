/* Read-only product diagnosis. Only fixture Auth login/logout mutate session state.
 * No customer/account/schema/rule changes. Never prints or persists credentials. */
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {networkAllowed,clean}=require('./verify-coreaml-kyc-browser-local.cjs');
const ROOT=path.resolve(__dirname,'..'),BASE='http://127.0.0.1:5520',API='http://127.0.0.1:55321';
const BANK='a1000000-0000-4000-8000-000000000001',OUT=path.join(ROOT,'.coreaml-local','browser-diagnostic.json');
const report={generated_at:new Date().toISOString(),scope:'Sequential compliance browser startup and authenticated read diagnostics; no product data writes',checks:[],sessions:[],limitations:[
 'Uses only the synthetic compliance_officer and head_of_compliance accounts; sessions are handled sequentially.',
 'Only Auth login and current-session logout write state. No applications, approvals, postings, rules or migrations.',
 'Read results alone do not establish a KYC or AML workflow pass. Tokens/public keys remain in memory and are never reported.'
]};
async function bounded(work,ms,label){let timer;try{return await Promise.race([work,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(label+' timed out after '+ms+' ms')),ms);})]);}finally{clearTimeout(timer);}}
async function step(actor,name,fn){const started=Date.now();try{const detail=await fn();report.checks.push({actor,check:name,result:'PASS',started_at:new Date(started).toISOString(),elapsed_ms:Date.now()-started,...(detail?{detail}:{})});return true;}catch(e){report.checks.push({actor,check:name,result:'FAIL',started_at:new Date(started).toISOString(),elapsed_ms:Date.now()-started,detail:clean(e.message)});return false;}}
async function httpRead(url,credentials,{fetchImpl=fetch}={}){assert(url.startsWith(API+'/')||url.startsWith(BASE+'/'),'Non-local HTTP target.');const started=Date.now();
 const r=await fetchImpl(url,{redirect:'error',signal:AbortSignal.timeout(8000),headers:credentials?{apikey:credentials.key,Authorization:'Bearer '+credentials.token}:{}});
 const serverDate=r.headers.get('date');let error;
 if(!r.ok){const body=await r.text();try{const data=JSON.parse(body);error=clean(data.message||data.msg||data.error_description||data.error||'Request rejected');}catch{error='Non-JSON HTTP error';}}
 else await r.body?.cancel();
 return {ok:r.ok,status:r.status,elapsed_ms:Date.now()-started,server_date:serverDate,error};
}
async function launch(chromium){for(const channel of ['msedge','chrome'])try{return await chromium.launch({channel,headless:!process.argv.includes('--headed')});}catch{}throw Error('No installed Edge or Chrome could be launched.');}
async function diagnose(browser,actor){
 const info={actor,started_at:new Date().toISOString(),lifecycle:[],requests:[],pending_at_cleanup:[],blocked:[]};report.sessions.push(info);
 const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});let page,credentials;
 const started=Date.now(),requests=new Map();let closing=false;
 const shortUrl=url=>{const u=new URL(url);return u.origin+u.pathname;};
 await context.route('**/*',async route=>{const request=route.request(),url=new URL(request.url());if(!networkAllowed(url,request.method())){info.blocked.push(shortUrl(url.href));return route.abort('blockedbyclient');}return route.continue();});
 try{
  page=await context.newPage();page.setDefaultTimeout(20000);page.setDefaultNavigationTimeout(30000);
  page.on('dialog',dialog=>dialog.accept().catch(()=>{}));
  page.on('domcontentloaded',()=>info.lifecycle.push({event:'domcontentloaded',url:shortUrl(page.url()),at_ms:Date.now()-started}));
  page.on('load',()=>info.lifecycle.push({event:'load',url:shortUrl(page.url()),at_ms:Date.now()-started}));
  page.on('pageerror',e=>info.lifecycle.push({event:'pageerror',message:clean(e.message),at_ms:Date.now()-started}));
  page.on('request',r=>{if(closing||info.requests.length>=200)return;const row={url:shortUrl(r.url()),method:r.method(),type:r.resourceType(),started_ms:Date.now()-started,state:'pending'};requests.set(r,row);info.requests.push(row);});
  page.on('response',r=>{const row=requests.get(r.request());if(row){row.status=r.status();row.response_ms=Date.now()-started;}});
  page.on('requestfinished',r=>{const row=requests.get(r);if(row){row.state='finished';row.elapsed_ms=Date.now()-started-row.started_ms;}});
  page.on('requestfailed',r=>{const row=requests.get(r);if(row){row.state=closing?'cancelled_during_cleanup':'failed';row.elapsed_ms=Date.now()-started-row.started_ms;row.error=clean(r.failure()?.errorText||'Request failed');}});
  const loginPage=await step(actor,'Login document commits; no full-load assumption',async()=>{const r=await page.goto(BASE+'/index.html',{waitUntil:'commit',timeout:30000});assert(r&&r.status()===200,'Login document did not return 200.');});
  if(!loginPage)return;
  const configured=await step(actor,'Actual browser configuration points to local API',async()=>{const url=await bounded(page.evaluate(async()=>{const {supabase}=await import('/js/config.js');return supabase.supabaseUrl;}),20000,'Browser config module import');assert.equal(url.replace(/\/$/,''),API,'Refusing to enter credentials for a non-local backend.');});
  if(!configured)return;
  const login=await step(actor,'Actual login form reaches dashboard document',async()=>{
   await page.locator('#email').fill(actor+'@coreaml-local.test');await page.locator('#password').fill(process.env.COREAML_LOCAL_PASSWORD||'CoreAML-Local-Only!2026');
   await Promise.all([page.waitForURL(BASE+'/dashboard.html',{waitUntil:'commit',timeout:30000}),page.locator('#login-form button[type=submit]').click()]);
  });
  if(!login)return;
  const captured=await step(actor,'Browser session and trusted bank/role can be read',async()=>{
   // Credentials stay in this function's memory; only timestamps/claims are reported.
   const value=await bounded(page.evaluate(async()=>{const {supabase}=await import('/js/config.js');if(supabase.supabaseUrl.replace(/\/$/,'')!=='http://127.0.0.1:55321')throw Error('Non-local backend.');const {data,error}=await supabase.auth.getSession();if(error||!data.session)throw Error('No readable browser session.');return {token:data.session.access_token,key:supabase.supabaseKey,role:data.session.user.app_metadata.role,bank:data.session.user.app_metadata.tenant_id};}),15000,'Read browser session');
   // Retain the fixture token for local cleanup even if its expected claims differ.
   credentials={token:value.token,key:value.key};assert(credentials.token&&credentials.key,'Missing local session credentials.');
   assert.equal(value.role,actor);assert.equal(value.bank,BANK);
   const claims=JSON.parse(Buffer.from(value.token.split('.')[1],'base64url').toString('utf8'));
   info.clock_snapshot={host_utc:new Date().toISOString(),jwt_issued_at:claims.iat,jwt_expires_at:claims.exp};
  });
  if(!captured)return;
  await step(actor,'Node authenticated customer read (outside browser)',async()=>{const result=await httpRead(API+'/rest/v1/customers?select=id&limit=1',credentials);assert(result.ok,'Node read: HTTP '+result.status+' '+(result.error||''));return result;});
  await step(actor,'Browser direct fetch (without SDK query builder)',async()=>{
   const result=await bounded(page.evaluate(async({token,key})=>{const started=Date.now();const r=await fetch('http://127.0.0.1:55321/rest/v1/customers?select=id&limit=1',{redirect:'error',signal:AbortSignal.timeout(8000),headers:{apikey:key,Authorization:'Bearer '+token}});const text=await r.text();let message='';if(!r.ok){try{const data=JSON.parse(text);message=data.message||data.error||'Rejected';}catch{message='Non-JSON error';}}return {ok:r.ok,status:r.status,elapsed_ms:Date.now()-started,error:message};},credentials),10000,'Browser direct fetch');
   assert(result.ok,'Browser direct read: HTTP '+result.status+' '+result.error);return result;
  });
  await step(actor,'Browser Supabase SDK customer read',async()=>{
   const result=await bounded(page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const started=Date.now();const {error,status}=await supabase.from('customers').select('id').limit(1).abortSignal(AbortSignal.timeout(8000));return {ok:!error,status,elapsed_ms:Date.now()-started,error:error?.message||null};}),10000,'Browser SDK read');
   assert(result.ok,'Browser SDK read: '+result.error);return result;
  });
  await step(actor,'Dashboard reaches DOMContentLoaded',async()=>{await page.waitForLoadState('domcontentloaded',{timeout:15000});});
  await step(actor,'Dashboard initializes its role and KYC navigation',async()=>{
   await page.waitForFunction(()=>{const role=document.querySelector('#ui-user-role')?.textContent.trim();return role&&role!=='...'&&typeof window.openKYCVerification==='function';},{},{timeout:15000});
   await page.locator('#nav-kyc').click();await page.locator('#view-kyc-directory').waitFor({state:'visible',timeout:10000});
  });
 }finally{
  info.pending_at_cleanup=info.requests.filter(r=>r.state==='pending').map(r=>({url:r.url,type:r.type,method:r.method,elapsed_ms:Date.now()-started-r.started_ms,status:r.status}));
  info.last_page_url=page?shortUrl(page.url()):null;
  // Explicit local Auth logout avoids an SDK lock or cleared browser storage
  // being misreported as successful cleanup. Never prints request headers/tokens.
  if(credentials)await step(actor,'Revoke captured fixture session through local Auth',async()=>{
   const r=await fetch(API+'/auth/v1/logout?scope=local',{method:'POST',redirect:'error',signal:AbortSignal.timeout(8000),headers:{apikey:credentials.key,Authorization:'Bearer '+credentials.token}});await r.body?.cancel();assert(r.ok,'Local Auth did not confirm logout (HTTP '+r.status+').');return {status:r.status};
  });
  else info.cleanup_notice='No token was captured; server-session revocation could not be verified. Closing browser context only.';
  credentials=null;closing=true;await context.close();
  await step(actor,'No unexpected network destinations',async()=>assert.deepEqual(info.blocked,[]));
 }
}
async function main(){
 assert(/^project_id\s*=\s*"sentinel-aml"/m.test(fs.readFileSync(path.join(ROOT,'supabase/config.toml'),'utf8')),'Wrong local project.');
 for(const [name,url]of [['Application HTTP server',BASE+'/index.html'],['Local API gateway',API+'/rest/v1/']])await step('environment',name,async()=>{const r=await httpRead(url);assert(r.status>=200&&r.status<500,'HTTP server unavailable.');if(name==='Application HTTP server')assert.equal(r.status,200);return {status:r.status,elapsed_ms:r.elapsed_ms,server_date:r.server_date};});
 const {chromium}=require(path.join(ROOT,'.coreaml-test-tools/node_modules/playwright'));const browser=await launch(chromium);
 try{for(const actor of ['compliance_officer','head_of_compliance'])await diagnose(browser,actor);}finally{await browser.close();}
}
if(require.main===module)main().catch(e=>report.checks.push({actor:'runner',check:'Diagnostic execution',result:'FAIL',detail:clean(e.message)})).finally(()=>{
 report.summary={pass:report.checks.filter(c=>c.result==='PASS').length,fail:report.checks.filter(c=>c.result==='FAIL').length};
 fs.mkdirSync(path.dirname(OUT),{recursive:true});fs.writeFileSync(OUT,JSON.stringify(report,null,2)+'\n');console.table(report.checks);console.log('Summary:',report.summary);console.log('Report: .coreaml-local/browser-diagnostic.json');
 console.log('Diagnostic only: no onboarding, approval, cash posting, AML rule or schema writes.');if(report.summary.fail)process.exitCode=1;
});
module.exports={bounded,httpRead};
