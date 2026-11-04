const assert=require('node:assert/strict');
const {bounded,httpRead}=require('./diagnose-coreaml-browser-local.cjs');
async function main(){
 assert.equal(await bounded(Promise.resolve('ready'),100,'test'),'ready');
 await assert.rejects(bounded(Promise.reject(Error('original failure')),100,'test'),/original failure/);
 await assert.rejects(bounded(new Promise(()=>{}),5,'readiness'),/readiness timed out/);
 let calls=0,cancelled=0;
 const credentials={token:'synthetic-test-token',key:'synthetic-public-key'};
 const fetchImpl=async(url,options)=>{calls++;assert.equal(options.redirect,'error');assert(options.signal instanceof AbortSignal);assert.equal(options.headers.Authorization,'Bearer '+credentials.token);return {ok:true,status:200,headers:{get:()=> 'Thu, 22 Oct 2026 12:00:00 GMT'},body:{cancel:async()=>cancelled++}};};
 const result=await httpRead('http://127.0.0.1:55321/rest/v1/customers?select=id&limit=1',credentials,{fetchImpl});
 assert(result.ok);assert.equal(calls,1);assert.equal(cancelled,1);
 assert(!JSON.stringify(result).includes(credentials.token));assert(!JSON.stringify(result).includes(credentials.key));
 for(const url of ['https://mbwgglgvykjpsnvnvcsj.supabase.co/rest/v1/customers','http://127.0.0.1:54321/rest/v1/customers','http://127.0.0.1:55321.example.com/rest/v1/customers'])await assert.rejects(httpRead(url,credentials,{fetchImpl}),/Non-local/);
 assert.equal(calls,1,'Credentials must not be sent to another target.');
 const error=await httpRead('http://127.0.0.1:55321/rest/v1/customers',credentials,{fetchImpl:async()=>({ok:false,status:401,headers:{get:()=>null},text:async()=>JSON.stringify({message:'JWT issued at future'})})});
 assert.equal(error.status,401);assert.equal(error.error,'JWT issued at future');assert(!error.ok);
 console.log('PASS: bounded diagnostics preserve failures; only selected loopback targets accept credentials; response bodies are released; error details exclude credential headers.');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
