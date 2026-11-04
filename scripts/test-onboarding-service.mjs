// Dependency-free tests for browser orchestration, including lost-response retry.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
if (!globalThis.crypto) globalThis.crypto = webcrypto;
const code=fs.readFileSync(new URL('../js/services/onboarding.service.js',import.meta.url),'utf8');
const {createOnboardingAttempt,submitOnboardingAttempt}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
const bank='a1000000-0000-4000-8000-000000000001';
const file={name:'test.PNG',type:'image/png',size:70};
const input={customerType:'RETAIL',firstName:' Synthetic ',lastName:'Test',bvn:'12345678901',idFile:file,utilityFile:file};
function attempt(){return createOnboardingAttempt(input,bank);}
function fake({uploadFail=false,rpcError=null,lookupData=null,lookupError=null,throwRpc=false,incomplete=false,duplicate=false}={}){
 const calls={upload:[],remove:[],rpc:[]};
 const client={storage:{from:()=>({upload:async(p)=>{calls.upload.push(p);return {error:uploadFail&&calls.upload.length===2?{message:'network lost'}:duplicate?{statusCode:'409'}:null}},remove:async(p)=>{calls.remove.push(p);return {error:null}}})},
 rpc:async(name,payload)=>{calls.rpc.push({name,payload});if(throwRpc)throw Error('network');return {error:rpcError,data:incomplete?[]:[{customer_id:payload.p_customer_id,account_id:'test-account-id',account_number:'9000000001',account_status:'PENDING'}]}},
 from:()=>({select:()=>({eq:()=>({maybeSingle:async()=>({data:lookupData,error:lookupError})})})})};
 return {client,calls};
}
assert.throws(()=>createOnboardingAttempt({...input,bvn:'invalid'},bank),/11-digit/);
assert.throws(()=>createOnboardingAttempt({...input,idFile:{...file,size:11*1024*1024}},bank),/10 MB/);
assert.throws(()=>createOnboardingAttempt(input,'../other-bank'),/assigned bank/);
const a=attempt();assert.equal(a.payload.p_first_name,'Synthetic');assert(a.payload.p_id_path.endsWith('id_document.png'));
const good=fake();assert.equal((await submitOnboardingAttempt(good.client,a)).account_status,'PENDING');assert.equal(good.calls.upload.length,2);assert.equal(good.calls.remove.length,0);assert.equal(good.calls.rpc[0].name,'onboard_customer');
const failedUpload=fake({uploadFail:true});await assert.rejects(submitOnboardingAttempt(failedUpload.client,attempt()),/upload failed/);assert.equal(failedUpload.calls.rpc.length,0);assert.equal(failedUpload.calls.remove.length,1);
const rejected=fake({rpcError:{code:'22023',message:'Rejected'},lookupData:null});await assert.rejects(submitOnboardingAttempt(rejected.client,attempt()),/Rejected/);assert.equal(rejected.calls.remove.length,1);
const retained=fake({rpcError:{code:'22023',message:'Reconciliation needed'},lookupData:{id:'exists'}});await assert.rejects(submitOnboardingAttempt(retained.client,attempt()),e=>e.keepAttempt===true);assert.equal(retained.calls.remove.length,0);
const retryAttempt=attempt(),lost=fake({throwRpc:true});await assert.rejects(submitOnboardingAttempt(lost.client,retryAttempt),e=>e.keepAttempt===true);assert.equal(lost.calls.remove.length,0);
const retry=fake();await submitOnboardingAttempt(retry.client,retryAttempt);assert.equal(retry.calls.upload.length,0);assert.equal(retry.calls.rpc[0].payload.p_customer_id,retryAttempt.customerId);
const duplicate=fake({duplicate:true});await submitOnboardingAttempt(duplicate.client,attempt());assert.equal(duplicate.calls.rpc.length,1);
const incomplete=fake({incomplete:true});await assert.rejects(submitOnboardingAttempt(incomplete.client,attempt()),e=>e.keepAttempt===true);assert.equal(incomplete.calls.remove.length,0);
const network=fake({rpcError:{message:'Failed to fetch'}});await assert.rejects(submitOnboardingAttempt(network.client,attempt()),e=>e.keepAttempt===true);assert.equal(network.calls.remove.length,0);
console.log('PASS: input validation, successful RPC, upload cleanup, definite rejection cleanup, linked-document retention, lost-response retry, duplicate upload recovery, incomplete response, and network-error preservation.');
