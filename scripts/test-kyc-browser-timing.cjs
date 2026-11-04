// Dependency-free regression tests: retry only safe reads and current-session logout.
const assert=require('node:assert/strict');
const {awaitJwtReadiness,signOutBrowserSession,networkAllowed}=require('./verify-coreaml-kyc-browser-local.cjs');
async function main(){
 let calls=0,waits=[],events=[];
 const ready=await awaitJwtReadiness(async()=>({error:++calls===1?'JWT issued at future':null}),{delay:async ms=>waits.push(ms),onRetry:e=>events.push(e)});
 assert.equal(ready.attempts,2);assert.equal(calls,2);assert.deepEqual(waits,[500]);assert.equal(events.length,1);
 calls=0;await assert.rejects(awaitJwtReadiness(async()=>{calls++;return {error:'JWT issued at future'};},{delay:async()=>{}}),/after 8 read-only probes/);assert.equal(calls,8);
 for(const message of ['JWT expired','permission denied','Failed to fetch','invalid JWT signature']){
  calls=0;await assert.rejects(awaitJwtReadiness(async()=>{calls++;return {error:message};},{delay:async()=>{throw Error('Unexpected retry');}}),/Authenticated local API probe failed/);assert.equal(calls,1);
 }
 calls=0;await assert.rejects(awaitJwtReadiness(async()=>{calls++;throw Error('Execution context destroyed');},{delay:async()=>{}}),/Execution context destroyed/);assert.equal(calls,1);
 function fakePage(results){let n=0;return {evaluate:async()=>{assert(n<results.length,'Unexpected sign-out retry');return results[n++];},calls:()=>n};}
 const transient=fakePage([{hasSession:true,error:'Failed to fetch'},{hasSession:true,error:null}]);waits=[];
 assert.equal((await signOutBrowserSession(transient,{delay:async ms=>waits.push(ms)})).attempts,2);assert.deepEqual(waits,[500]);
 const persistent=fakePage(Array.from({length:3},()=>({hasSession:true,error:'Failed to fetch'})));
 await assert.rejects(signOutBrowserSession(persistent,{delay:async()=>{}}),/could not be verified/);assert.equal(persistent.calls(),3);
 const cleared=fakePage([{hasSession:true,error:'Failed to fetch'},{hasSession:false,error:'No browser session remains to verify server sign-out.'}]);
 await assert.rejects(signOutBrowserSession(cleared,{delay:async()=>{}}),/No browser session remains/);assert.equal(cleared.calls(),2);
 const denied=fakePage([{hasSession:true,error:'permission denied'}]);
 await assert.rejects(signOutBrowserSession(denied,{delay:async()=>{throw Error('Unexpected retry');}}),/permission denied/);assert.equal(denied.calls(),1);
 assert(!networkAllowed(new URL('https://mbwgglgvykjpsnvnvcsj.supabase.co/auth/v1/logout'),'POST'));
 assert(!networkAllowed(new URL('http://127.0.0.1:54321/rest/v1/customers'),'GET'));
 assert(networkAllowed(new URL('http://127.0.0.1:55321/rest/v1/customers'),'GET'));
 console.log('PASS: bounded future-JWT read readiness; no retries for other authentication/permission/network errors; bounded logout recovery; missing-session and persistent failures remain failures; local network boundary unchanged.');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
