/* Actual local browser journey: onboarding, manual review, committed-response loss,
 * same-reference retry, risk escalation and account lookup. No schema changes. */
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {randomUUID,randomInt}=require('node:crypto');
const ROOT=path.resolve(__dirname,'..'),BASE='http://127.0.0.1:5520',API='http://127.0.0.1:55321';
const BANK='a1000000-0000-4000-8000-000000000001';
const HEAD_ONLY=process.argv.includes('--resume-head');
const OUT=path.join(ROOT,'.coreaml-local',HEAD_ONLY?'kyc-browser-head':'kyc-browser');
const report={generated_at:new Date().toISOString(),scope:'Actual local onboarding and manual KYC approval forms, lost-response retry, head review and account lookup',checks:[],applications:[],observations:[],diagnostics:{authReadiness:[],cleanup:[],requestFailures:[],apiErrors:[]},limitations:[
 'Creates two synthetic applications through the onboarding form; successful approvals remain locally.',
 'Intentionally drops one successful local approval response, then retries the same review reference.',
 'Synthetic evidence only: no real identity/sanctions verification, cash posting, AML detection or full admin testing.',
 'No schema changes, migration-history writes or hosted application access.'
]};
if(HEAD_ONLY){report.scope='Resume head-of-compliance browser approval for an existing pending high-risk fixture';report.limitations=[
 'Reads the latest full-suite result and resumes its existing High application; creates no new applications.',
 'Performs one synthetic manual approval if all prerequisites pass. No real identity/sanctions checks or cash posting.',
 'Separate result file preserves the original full-suite report; this is not a fresh full-suite pass.'
];}
const states=new Map(),sessions=[];
function clean(v){return String(v).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g,'[JWT removed]').replace(/sb_secret_[\w-]+/g,'[secret removed]').replace(/CoreAML-Local-Only!2026/g,'[password removed]').replace(/([?&](?:token|apikey|access_token)=)[^&\s"']+/gi,'$1[removed]').slice(0,900);}
async function check(name,fn,requires=[]){
 if(requires.some(r=>states.get(r)!=='PASS')){states.set(name,'BLOCKED');report.checks.push({check:name,result:'BLOCKED',detail:'Required earlier check failed: '+requires.filter(r=>states.get(r)!=='PASS').join(', ')});return false;}
 try{await fn();states.set(name,'PASS');report.checks.push({check:name,result:'PASS'});return true;}
 catch(e){states.set(name,'FAIL');report.checks.push({check:name,result:'FAIL',detail:clean(e.message)});return false;}
}
function networkAllowed(url,method){
 if([BASE,API].includes(url.origin))return true;
 if(url.protocol!=='https:'||!['GET','HEAD'].includes(method))return false;
 if(['cdn.jsdelivr.net','cdnjs.cloudflare.com','fonts.googleapis.com','fonts.gstatic.com','cdn.tailwindcss.com'].includes(url.hostname))return true;
 return url.hostname==='unpkg.com'&&/^\/vis-network(?:@[0-9A-Za-z.+-]+)?\/standalone\/umd\/vis-network\.min\.js$/.test(url.pathname);
}
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function awaitJwtReadiness(read,{delay=pause,onRetry=()=>{},attempts=8}={}){
 for(let attempt=1;attempt<=attempts;attempt++){
  const result=await read();
  if(!result.error)return {attempts:attempt};
  const message=String(result.error);
  if(!/JWT issued at future/i.test(message))throw Error('Authenticated local API probe failed: '+message);
  if(attempt===attempts)throw Error('JWT remains future-dated after '+attempts+' read-only probes. Check Windows/Docker clock synchronization; authentication checks were not bypassed.');
  onRetry({attempt,delayMs:500,message:'JWT issued at future'});await delay(500);
 }
}
async function signOutBrowserSession(page,{delay=pause,onRetry=()=>{}}={}){
 for(let attempt=1;attempt<=3;attempt++){
  const result=await page.evaluate(async()=>{
   const {supabase}=await import('/js/config.js');
   const session=await supabase.auth.getSession();
   if(session.error)return {hasSession:false,error:session.error.message};
   if(!session.data.session)return {hasSession:false,error:'No browser session remains to verify server sign-out.'};
   const {error}=await supabase.auth.signOut({scope:'local'});
   return {hasSession:true,error:error?.message||null};
  });
  if(!result.error)return {attempts:attempt};
  if(!result.hasSession||!/(?:failed to fetch|networkerror|network request failed|fetch failed)/i.test(result.error)||attempt===3)
   throw Error('Browser sign-out could not be verified: '+result.error);
  onRetry({attempt,delayMs:attempt*500,message:'Transient sign-out network failure'});await delay(attempt*500);
 }
}
async function launch(chromium){
 for(const channel of ['msedge','chrome']){try{return await chromium.launch({channel,headless:!process.argv.includes('--headed')});}catch{}}
 throw Error('Could not launch installed Edge or Chrome. Keep either browser installed and rerun.');
}
async function openSession(browser,actor){
 const context=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
 const info={actor,context,blocked:[],providerCalls:[],reviewRequests:[],dropNextApproval:false,droppedCommittedResponse:false,loggedIn:false,expectedFailures:new WeakSet()};sessions.push(info);
 await context.route('**/*',async route=>{
  const request=route.request(),url=new URL(request.url());
  if(!networkAllowed(url,request.method())){info.blocked.push(url.origin+url.pathname);return route.abort('blockedbyclient');}
  if(url.origin===API&&url.pathname.endsWith('/functions/v1/verify-kyc'))info.providerCalls.push(url.pathname);
  if(url.origin===API&&url.pathname==='/rest/v1/rpc/approve_manual_kyc'&&request.method()==='POST'){
   info.reviewRequests.push(request.postDataJSON());
   if(info.dropNextApproval){
    info.dropNextApproval=false;
    try{
     const response=await route.fetch({timeout:30000,maxRedirects:0});
     if(response.ok()){info.droppedCommittedResponse=true;info.expectedFailures.add(request);await response.dispose();return route.abort('failed');}
     return route.fulfill({response});
    }catch(e){report.observations.push({actor,kind:'Response-loss injection failure',message:clean(e.message)});return route.abort('failed');}
   }
  }
  return route.continue();
 });
 const page=await context.newPage();info.page=page;page.setDefaultTimeout(30000);page.setDefaultNavigationTimeout(45000);
 page.on('dialog',dialog=>dialog.accept().catch(()=>{}));
 page.on('pageerror',e=>report.observations.push({actor,kind:'Uncaught browser error',message:clean(e.message)}));
 page.on('requestfailed',request=>{
  if(info.expectedFailures.has(request)||report.diagnostics.requestFailures.length>=100)return;
  const url=new URL(request.url());
  report.diagnostics.requestFailures.push({actor,method:request.method(),url:url.origin+url.pathname,error:clean(request.failure()?.errorText||'Request failed')});
 });
 page.on('response',response=>{
  const url=new URL(response.url());
  if(url.origin===API&&response.status()>=400&&report.diagnostics.apiErrors.length<100)
   report.diagnostics.apiErrors.push({actor,url:url.origin+url.pathname,status:response.status()});
 });
 const banking=actor==='teller';
 await page.goto(BASE+(banking?'/bank-login.html':'/index.html'),{waitUntil:'commit',timeout:45000});
 const url=await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');return supabase.supabaseUrl;});
 assert.equal(url.replace(/\/$/,''),API,'Refusing to enter credentials: configured backend must be local.');
 await page.locator(banking?'#teller-email':'#email').fill(actor+'@coreaml-local.test');
 await page.locator(banking?'#teller-password':'#password').fill(process.env.COREAML_LOCAL_PASSWORD||'CoreAML-Local-Only!2026');
 await Promise.all([page.waitForURL(BASE+(banking?'/core-banking.html':'/dashboard.html'),{waitUntil:'commit',timeout:45000}),page.locator(banking?'#teller-login-form button[type=submit]':'#login-form button[type=submit]').click()]);
 const metadata=await page.evaluate(async()=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.auth.getSession();if(error||!data.session)throw Error('No browser session.');return data.session.user.app_metadata;});
 info.loggedIn=true;assert.equal(metadata.role,actor);assert.equal(metadata.tenant_id,BANK);
 const ready=await awaitJwtReadiness(()=>page.evaluate(async()=>{
  const {supabase}=await import('/js/config.js');
  const {error}=await supabase.from('customers').select('id').limit(1).abortSignal(AbortSignal.timeout(5000));
  return {error:error?.message||null};
 }),{onRetry:event=>report.diagnostics.authReadiness.push({actor,...event})});
 report.diagnostics.authReadiness.push({actor,ready:true,attempts:ready.attempts});
 if(banking)await page.waitForFunction(()=>!['','...'].includes(document.querySelector('#ui-teller-role')?.textContent.trim()||''));
 else await page.waitForFunction(expected=>typeof window.openKYCVerification==='function'&&document.querySelector('#ui-user-role')?.textContent.trim().toLowerCase().replace(/\s+/g,'_')===expected,actor,{timeout:45000});
 return info;
}
async function snapshot(page,app){
 return page.evaluate(async({customerId,accountId})=>{
  const {supabase}=await import('/js/config.js');
  const a=await supabase.from('accounts').select('id,status,balance,customer_id').eq('id',accountId).single();
  const c=await supabase.from('customers').select('id,kyc_status,risk_score,risk_tier').eq('id',customerId).single();
  const r=await supabase.from('kyc_reviews').select('id,review_method,risk_flags,risk_score,reviewer_id').eq('customer_id',customerId);
  for(const result of [a,c,r])if(result.error)throw Error(result.error.message);
  return {account:a.data,customer:c.data,reviews:r.data};
 },app);
}
function assertPending(s){assert.equal(s.customer.kyc_status,'PENDING');assert.equal(s.account.status,'PENDING');assert.equal(Number(s.account.balance),0);assert.equal(s.reviews.length,0);}
function assertActive(s){assert.equal(s.customer.kyc_status,'COMPLETED');assert.equal(s.account.status,'ACTIVE');assert.equal(Number(s.account.balance),0);assert.equal(s.reviews.length,1);assert.equal(s.reviews[0].review_method,'MANUAL_ATTESTATION');}
async function createApplication(info,label){
 const page=info.page,marker='KycBrowser'+label+randomUUID().slice(0,8);
 for(let attempt=0;attempt<3;attempt++){
  // Random 11-digit identifiers plus collision lookup make repeated runs independent.
  let bvn;
  for(let n=0;n<10;n++){
   const candidate=String(randomInt(10000000000,100000000000));
   const available=await page.evaluate(async value=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.from('customers').select('id').eq('bvn',value).limit(1);if(error)throw Error(error.message);return data.length===0;},candidate);
   if(available){bvn=candidate;break;}
  }
  assert(bvn,'Could not allocate a fresh synthetic BVN.');
  await page.locator('#nav-onboard-tab').click();await page.locator('#ob-type').selectOption('RETAIL');
  await page.locator('#ob-first-name').fill('Synthetic');await page.locator('#ob-last-name').fill(marker);await page.locator('#ob-bvn').fill(bvn);
  const buffer=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6GoAAAAAASUVORK5CYII=','base64');
  for(const selector of ['#ob-id-file','#ob-utility-file'])await page.locator(selector).setInputFiles({name:'synthetic.png',mimeType:'image/png',buffer});
  const [dialog]=await Promise.all([page.waitForEvent('dialog',{timeout:45000}),page.locator('#btn-submit-onboard').click()]);
  const message=dialog.message();
  if(/customers_bvn_key/.test(message))continue;
  const match=message.match(/Application confirmed\. Account (\d{10}): PENDING/);
  assert(match,'Onboarding was not confirmed: '+clean(message));
  const a=await page.evaluate(async number=>{const {supabase}=await import('/js/config.js');const {data,error}=await supabase.from('accounts').select('id,customer_id,status,balance').eq('account_number',number).single();if(error)throw Error(error.message);return data;},match[1]);
  assert.equal(a.status,'PENDING');assert.equal(Number(a.balance),0);
  const app={label,marker,customerId:a.customer_id,accountId:a.id,accountNumber:match[1]};report.applications.push(app);return app;
 }
 throw Error('Three synthetic BVN collisions; no successful browser application.');
}
async function lookup(info,app,pending){
 const page=info.page;await page.locator('#nav-cash-tab').click();await page.locator('#lookup-acct').fill('');await page.locator('#lookup-acct').fill(app.accountNumber);
 if(pending){await page.waitForFunction(()=>document.querySelector('#cust-tier')?.textContent.includes('PENDING KYC APPROVAL'));assert.equal(await page.locator('#verified-account-id').inputValue(),'');}
 else await page.waitForFunction(id=>document.querySelector('#verified-account-id')?.value===id,app.accountId);
}
async function openReview(info,app){
 const page=info.page;await page.locator('#nav-kyc').click();
 const row=page.locator('#kyc-directory-body tr').filter({hasText:app.marker});
 await row.getByRole('button',{name:'Review KYC',exact:true}).click();
 await page.locator('#kycVerificationModal').waitFor({state:'visible'});
 await page.waitForFunction(()=>!document.querySelector('#btn-kyc-approve').disabled);
 assert.equal(await page.locator('#kyc-customer-id').inputValue(),app.customerId);
 assert.match(await page.locator('#kycVerificationModal').innerText(),/Manual KYC review/);
 assert.doesNotMatch(await page.locator('#kycVerificationModal').innerText(),/98%|CONFIDENCE MATCH|Identity Successfully Verified|Watchlist.*CLEARED/i);
 const links=await page.locator('#kyc-document-links a').evaluateAll(nodes=>nodes.map(n=>n.href));assert.equal(links.length,2);
 for(const link of links){const u=new URL(link);assert.equal(u.origin,API);assert(u.pathname.startsWith('/storage/v1/object/sign/kyc-vault/'));const response=await page.request.get(link,{maxRedirects:0});assert(response.ok(),'Private review document did not load.');await response.dispose();}
}
async function fillReview(info,label,high=false){
 const page=info.page;
 await page.locator('#kyc-identity-reference').fill('SYNTHETIC-LOCAL-IDENTITY-'+label);
 await page.locator('#kyc-screening-reference').fill('SYNTHETIC-LOCAL-SCREENING-'+label);
 await page.locator('#kyc-review-notes').fill('Synthetic browser verification only. No real identity or watchlist checks were performed.');
 for(const id of ['kyc-identity-checked','kyc-address-checked','kyc-screening-checked'])await page.locator('#'+id).check();
 if(high)await page.locator('#edd-media').check();
}
async function main(){
 assert(/^project_id\s*=\s*"sentinel-aml"/m.test(fs.readFileSync(path.join(ROOT,'supabase/config.toml'),'utf8')),'Wrong local project.');
 assert(fs.existsSync(path.join(ROOT,'js/services/kyc-review.service.js')),'Apply the manual KYC patch first.');
 const bankingSource=fs.readFileSync(path.join(ROOT,'core-banking.html'),'utf8');
 assert(bankingSource.includes('submitOnboardingAttempt')&&bankingSource.includes('PENDING KYC APPROVAL'),'Apply the atomic onboarding patch before running this browser test.');
 const response=await fetch(BASE+'/index.html',{redirect:'error',signal:AbortSignal.timeout(10000)});assert.equal(response.status,200,'Start the local Python server on port 5520.');
 const {chromium}=require(path.join(ROOT,'.coreaml-test-tools/node_modules/playwright'));
 const browser=await launch(chromium);let teller,officer,head,low,high;
 try{
  await check('Teller logs in through actual banking form',async()=>{teller=await openSession(browser,'teller');});
  await check('Create ordinary pending application through actual onboarding form',async()=>{low=await createApplication(teller,'Low');},['Teller logs in through actual banking form']);
  await check('Create escalation application with fresh synthetic BVN',async()=>{high=await createApplication(teller,'High');},['Teller logs in through actual banking form']);
  await check('Teller lookup refuses pending account selection',()=>lookup(teller,low,true),['Create ordinary pending application through actual onboarding form']);
  await check('Officer logs in through actual compliance form',async()=>{officer=await openSession(browser,'compliance_officer');});
  await check('Officer opens actual review form and both private documents',()=>openReview(officer,low),['Officer logs in through actual compliance form','Create ordinary pending application through actual onboarding form']);
  await check('Missing attestations prevent approval without an RPC',async()=>{
   const count=officer.reviewRequests.length;await officer.page.locator('#btn-kyc-approve').click();
   await officer.page.waitForFunction(()=>document.querySelector('#kyc-review-status')?.textContent.includes('Confirm identity'));
   assert.equal(officer.reviewRequests.length,count);assertPending(await snapshot(officer.page,low));
  },['Officer opens actual review form and both private documents']);
  await check('Committed approval with lost response retains locked review for retry',async()=>{
   await fillReview(officer,low.marker);officer.dropNextApproval=true;await officer.page.locator('#btn-kyc-approve').click();
   await officer.page.waitForFunction(()=>document.querySelector('#kyc-review-status')?.textContent.includes('Review reference:'));
   assert(officer.droppedCommittedResponse,'No successful approval response was dropped.');
   assert(await officer.page.locator('#kycVerificationModal').isVisible());assert(await officer.page.locator('#kyc-review-notes').isDisabled());
   assertActive(await snapshot(officer.page,low));
  },['Missing attestations prevent approval without an RPC']);
  await check('Actual retry confirms activation with one unchanged review reference',async()=>{
   await officer.page.locator('#btn-kyc-approve').click();await officer.page.locator('#kycVerificationModal').waitFor({state:'hidden'});
   assert(officer.reviewRequests.length>=2);for(const payload of officer.reviewRequests)assert.deepEqual(payload,officer.reviewRequests[0]);
   const s=await snapshot(officer.page,low);assertActive(s);assert.equal(s.reviews[0].id,officer.reviewRequests[0].p_review_id);
  },['Committed approval with lost response retains locked review for retry']);
  await check('Teller lookup recognizes the activated account without posting cash',()=>lookup(teller,low,false),['Actual retry confirms activation with one unchanged review reference']);
  await check('Officer high-risk attempt stays pending and unlocks correction',async()=>{
   await openReview(officer,high);await fillReview(officer,high.marker,true);await officer.page.locator('#btn-kyc-approve').click();
   await officer.page.waitForFunction(()=>/head-of-compliance/i.test(document.querySelector('#kyc-review-status')?.textContent||''));
   assert.equal(await officer.page.locator('#kyc-review-notes').isDisabled(),false);assertPending(await snapshot(officer.page,high));
   await officer.page.locator('#kycVerificationModal .btn-close').click();await officer.page.locator('#kycVerificationModal').waitFor({state:'hidden'});
  },['Officer logs in through actual compliance form','Create escalation application with fresh synthetic BVN','Actual retry confirms activation with one unchanged review reference']);
  await check('Head of compliance logs in through actual form',async()=>{head=await openSession(browser,'head_of_compliance');});
  await check('Head approves high-risk application through actual review form',async()=>{
   await openReview(head,high);await fillReview(head,high.marker,true);await head.page.locator('#btn-kyc-approve').click();await head.page.locator('#kycVerificationModal').waitFor({state:'hidden'});
   const s=await snapshot(head.page,high);assertActive(s);assert.equal(s.customer.risk_tier,'HIGH');assert(Number(s.customer.risk_score)>=75);assert.equal(s.reviews[0].risk_flags.pep_or_adverse_media,true);
  },['Head of compliance logs in through actual form','Officer high-risk attempt stays pending and unlocks correction']);
 }finally{
  for(const info of sessions){
   if(info.loggedIn&&info.page&&!info.page.isClosed())await check(info.actor+': browser sign-out',async()=>{
    const result=await signOutBrowserSession(info.page,{onRetry:event=>report.diagnostics.cleanup.push({actor:info.actor,...event})});
    report.diagnostics.cleanup.push({actor:info.actor,revocationConfirmed:true,attempts:result.attempts});
   });
   await check(info.actor+': no unexpected network destinations',async()=>assert.deepEqual(info.blocked,[]));
   await check(info.actor+': no automated identity-provider claims or requests',async()=>assert.deepEqual(info.providerCalls,[]));
   await info.context.close();
  }
  await browser.close();
 }
}
async function resumeHead(){
 assert(/^project_id\s*=\s*"sentinel-aml"/m.test(fs.readFileSync(path.join(ROOT,'supabase/config.toml'),'utf8')),'Wrong local project.');
 const sourceFile=path.join(ROOT,'.coreaml-local','kyc-browser','results.json');
 const source=JSON.parse(fs.readFileSync(sourceFile,'utf8'));
 const app=source.applications?.find(a=>a.label==='High');
 const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
 assert(app&&uuid.test(app.customerId)&&uuid.test(app.accountId)&&/^\d{10}$/.test(app.accountNumber)&&/^KycBrowserHigh[0-9a-f]{8}$/i.test(app.marker),'No valid High fixture reference in the full-suite report.');
 report.source_report={path:'.coreaml-local/kyc-browser/results.json',generated_at:source.generated_at,summary:source.summary};
 report.applications.push(app);
 const response=await fetch(BASE+'/index.html',{redirect:'error',signal:AbortSignal.timeout(10000)});assert.equal(response.status,200,'Start the local Python server on port 5520.');await response.body?.cancel();
 const {chromium}=require(path.join(ROOT,'.coreaml-test-tools/node_modules/playwright'));
 const browser=await launch(chromium);let head;
 try{
  await check('Head logs in through actual form, API and initialized dashboard',async()=>{head=await openSession(browser,'head_of_compliance');});
  await check('Existing high-risk fixture is still pending with zero balance',async()=>{
   const state=await snapshot(head.page,app);assertPending(state);assert.equal(state.account.customer_id,app.customerId,'Account/customer reference mismatch.');
  },['Head logs in through actual form, API and initialized dashboard']);
  await check('Head opens existing application and private review documents',()=>openReview(head,app),['Existing high-risk fixture is still pending with zero balance']);
  await check('Head approves existing high-risk application through actual form',async()=>{
   await fillReview(head,app.marker,true);await head.page.locator('#btn-kyc-approve').click();await head.page.locator('#kycVerificationModal').waitFor({state:'hidden'});
   const state=await snapshot(head.page,app);assertActive(state);assert.equal(state.customer.risk_tier,'HIGH');assert(Number(state.customer.risk_score)>=75);assert.equal(state.reviews[0].risk_flags.pep_or_adverse_media,true);
  },['Head opens existing application and private review documents']);
 }finally{
  for(const info of sessions){
   if(info.loggedIn&&info.page&&!info.page.isClosed())await check(info.actor+': browser sign-out',async()=>{
    const result=await signOutBrowserSession(info.page,{onRetry:event=>report.diagnostics.cleanup.push({actor:info.actor,...event})});report.diagnostics.cleanup.push({actor:info.actor,revocationConfirmed:true,attempts:result.attempts});
   });
   await check(info.actor+': no unexpected network destinations',async()=>assert.deepEqual(info.blocked,[]));
   await check(info.actor+': no automated identity-provider claims or requests',async()=>assert.deepEqual(info.providerCalls,[]));
   await info.context.close();
  }
  await browser.close();
 }
}
if(require.main===module)(HEAD_ONLY?resumeHead():main()).catch(e=>{report.checks.push({check:'Browser prerequisites/execution',result:'FAIL',detail:clean(e.message)});}).finally(()=>{
 report.summary={pass:report.checks.filter(x=>x.result==='PASS').length,fail:report.checks.filter(x=>x.result==='FAIL').length,blocked:report.checks.filter(x=>x.result==='BLOCKED').length,uncaughtBrowserErrors:report.observations.filter(x=>x.kind==='Uncaught browser error').length};
 fs.mkdirSync(OUT,{recursive:true});fs.writeFileSync(path.join(OUT,'results.json'),JSON.stringify(report,null,2)+'\n');
 console.table(report.checks);console.log('Summary:',report.summary);console.log('Report:',path.relative(ROOT,path.join(OUT,'results.json')));
 console.log('Scope excludes real identity/sanctions checks, cash posting, AML detection and full admin workflows.');
 if(report.summary.fail||report.summary.blocked||report.observations.length)process.exitCode=1;
});
module.exports={networkAllowed,clean,awaitJwtReadiness,signOutBrowserSession};
