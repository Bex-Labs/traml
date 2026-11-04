// Native-browser regression: isolated synthetic pages/responses, no real backend.
'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ROOT=path.resolve(__dirname,'..'),BASE='http://127.0.0.1:5520',API='http://127.0.0.1:55321';
async function launch(chromium){for(const channel of ['msedge','chrome'])try{return await chromium.launch({channel,headless:true});}catch{}return chromium.launch({headless:true});}
async function main(){
 const html=fs.readFileSync(path.join(ROOT,'dashboard.html'),'utf8');
 const policy=html.match(/<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]+)"/i)?.[1];assert(policy,'Dashboard CSP is missing.');
 const connect=policy.split(';').map(v=>v.trim()).find(v=>v.startsWith('connect-src '));assert(connect,'Explicit connect-src is missing.');
 const sources=connect.split(/\s+/).slice(1);
 assert(sources.includes(API));assert(sources.includes('ws://127.0.0.1:55321'));assert(!sources.includes('*'));assert(!sources.includes('http:'));assert(!sources.includes('ws:'));
 const previous=policy.replace(/connect-src[^;]*;/,'');
 assert.equal(previous.trim(),"default-src 'self' 'unsafe-inline' 'unsafe-eval' https: data: wss:;",'Existing default policy must remain intact.');
 if(process.argv.includes('--static')){console.log('PASS: explicit local API/realtime addresses, no broad HTTP/WS wildcard, and the existing default policy is preserved. Native browser behavior is not tested in --static mode.');return;}
 const {chromium}=require(process.env.COREAML_TEST_PLAYWRIGHT_MODULE||path.join(ROOT,'.coreaml-test-tools/node_modules/playwright'));
 const browser=await launch(chromium);const context=await browser.newContext({serviceWorkers:'block'});let apiRequests=0,unexpected=0;
 await context.addInitScript(()=>{window.cspViolations=[];document.addEventListener('securitypolicyviolation',e=>window.cspViolations.push({directive:e.effectiveDirective,blocked:e.blockedURI}));});
 await context.route('**/*',async route=>{
  const url=new URL(route.request().url());
  if(url.origin===BASE&&['/old-policy','/fixed-policy'].includes(url.pathname))return route.fulfill({status:200,contentType:'text/html',body:'<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="'+(url.pathname==='/old-policy'?previous:policy)+'"></head><body>Synthetic CSP test only</body></html>'});
  if(url.origin===API&&url.pathname==='/synthetic-csp-probe'){apiRequests++;return route.fulfill({status:200,headers:{'Content-Type':'application/json','Access-Control-Allow-Origin':BASE},body:'{"synthetic":true}'});}
  unexpected++;return route.abort('blockedbyclient');
 });
 const page=await context.newPage();
 async function probe(url){return page.evaluate(async target=>{try{const response=await fetch(target,{signal:AbortSignal.timeout(3000)});return {ok:response.ok,data:await response.json()};}catch(error){return {ok:false,error:error.name};}},url);}
 try{
  await page.goto(BASE+'/old-policy');assert.equal((await probe(API+'/synthetic-csp-probe')).ok,false);assert.equal(apiRequests,0,'Old CSP should reject before any API request.');
  await page.waitForFunction(()=>window.cspViolations.some(v=>v.directive==='connect-src'));
  await page.goto(BASE+'/fixed-policy');const allowed=await probe(API+'/synthetic-csp-probe');assert.equal(allowed.ok,true);assert.equal(allowed.data.synthetic,true);assert.equal(apiRequests,1);
  assert.equal((await probe('http://127.0.0.1:54321/synthetic-csp-probe')).ok,false);
  await page.waitForFunction(()=>window.cspViolations.some(v=>v.directive==='connect-src'&&v.blocked.startsWith('http://127.0.0.1:54321')));
  assert.equal(unexpected,0,'Wrong-stack requests must be stopped by CSP before network routing.');
  console.log('PASS: native browser reproduces old CSP blocking the local API before a request, fixed CSP permits the exact API, and the other local stack remains blocked. Exact realtime address is present; no broad HTTP/WS allowance was added.');
 }finally{await context.close();await browser.close();}
}
main().catch(e=>{console.error(e.message);process.exitCode=1;});
