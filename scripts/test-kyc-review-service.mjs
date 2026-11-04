import fs from 'node:fs';import assert from 'node:assert/strict';
const code=fs.readFileSync(new URL('../js/services/kyc-review.service.js',import.meta.url),'utf8');
const {createKycReview,submitKycReview}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
const input={customerId:crypto.randomUUID(),identityReference:'Identity-file-001',screeningReference:'Screening-case-001',notes:'Manually checked the supplied evidence and screening disposition.',identityChecked:true,addressChecked:true,screeningChecked:true};
for(const key of ['identityChecked','addressChecked','screeningChecked'])assert.throws(()=>createKycReview({...input,[key]:false}),/Confirm/);
assert.throws(()=>createKycReview({...input,notes:'short'}),/20/);assert.throws(()=>createKycReview({...input,screeningReference:''}),/reference/);
const p=createKycReview(input);assert(Object.isFrozen(p)&&Object.isFrozen(p.p_flags));assert.equal(p.p_flags.face_to_face,false);
const requests=[];const client={rpc:async(name,payload)=>{requests.push({name,payload});return {data:[{customer_id:payload.p_customer_id,account_id:crypto.randomUUID(),account_status:'ACTIVE',review_id:payload.p_review_id}]};}};
await submitKycReview(client,p);await submitKycReview(client,p);assert.equal(requests[0].name,'approve_manual_kyc');assert.strictEqual(requests[0].payload,requests[1].payload);
for(const data of [[],[{customer_id:p.p_customer_id,review_id:p.p_review_id,account_id:'a',account_status:'PENDING'}]])await assert.rejects(submitKycReview({rpc:async()=>({data})},p),/incomplete/);
await assert.rejects(submitKycReview({rpc:async()=>({error:{code:'42501',message:'Permission denied'}})},p),e=>e.definiteRejection===true);
await assert.rejects(submitKycReview({rpc:async()=>({error:{message:'Gateway failure'}})},p),e=>e.definiteRejection===false);
await assert.rejects(submitKycReview({rpc:async()=>{throw Error('Connection lost');}},p),/Connection lost/);
console.log('PASS: required attestations/evidence, immutable retry reference, confirmed activation response, definite rejection and uncertain network outcome.');
// Exercise the actual dashboard handlers with a tiny DOM and stubbed API.
const html=fs.readFileSync(new URL('../dashboard.html',import.meta.url),'utf8');
const start=html.indexOf('        // Manual review:');const end=html.indexOf('        // --- Tab Switching Logic for the Pending Queue ---',start);
assert(start>=0&&end>start);assert(!html.includes('98% CONFIDENCE MATCH'));assert(!html.includes('Falling back to Sandbox Mock Data'));
const nodes=new Map();const node=id=>{if(!nodes.has(id))nodes.set(id,{id,type:/checked$|^edd-/.test(id)?'checkbox':'text',checked:false,value:'',disabled:false,textContent:'',children:[],replaceChildren(){this.children=[];},appendChild(v){this.children.push(v);},addEventListener(event,fn){this[event]=fn;}});return nodes.get(id);};
const notices=[];let mode='success',seen=[],shows=0;
const customer={id:input.customerId,entity_name:'Synthetic Review',customer_type:'RETAIL',id_url:'bank/id.png',utility_bill_url:'bank/utility.png'};
const browserClient={from:()=>({select:()=>({eq:()=>({single:async()=>({data:customer})})})}),storage:{from:()=>({createSignedUrl:async p=>({data:{signedUrl:'http://127.0.0.1/'+p}})})},rpc:async(name,payload)=>{
 seen.push(payload);
 if(mode==='lost')throw Error('Connection lost');
 if(mode==='denied')return {error:{code:'42501',message:'Reviewer denied'}};
 return {data:[{customer_id:payload.p_customer_id,review_id:payload.p_review_id,account_id:'account',account_status:'ACTIVE'}]};
}};
const win={};const modal={show(){},hide(){}};const bootstrap={Modal:{getOrCreateInstance:()=>modal,getInstance:()=>modal},Toast:function(){this.show=()=>shows++;}};
new Function('window','document','supabase','bootstrap','alert','createKycReview','submitKycReview','loadKYCDirectory',html.slice(start,end))(win,{getElementById:node,createElement:()=>({})},browserClient,bootstrap,v=>notices.push(v),createKycReview,submitKycReview,()=>{});
await win.openKYCVerification(customer.id);assert.equal(node('kyc-document-links').children.length,2);assert(!node('btn-kyc-approve').disabled);
await node('btn-kyc-approve').click();assert.equal(seen.length,0);assert.equal(shows,0);
function fill(){node('kyc-identity-reference').value=input.identityReference;node('kyc-screening-reference').value=input.screeningReference;node('kyc-review-notes').value=input.notes;for(const key of ['identity','address','screening'])node(`kyc-${key}-checked`).checked=true;}
fill();mode='lost';await node('btn-kyc-approve').click();assert.equal(shows,0);assert(node('kyc-review-notes').disabled);assert.match(node('kyc-review-status').textContent,/Review reference/);
mode='success';await node('btn-kyc-approve').click();assert.equal(shows,1);assert.strictEqual(seen[0],seen[1]);
await win.openKYCVerification(customer.id);fill();mode='denied';await node('btn-kyc-approve').click();assert(!node('kyc-review-notes').disabled);assert.equal(shows,1);
console.log('PASS: actual dashboard handlers load documents, require attestations, preserve uncertain retries, unlock definite rejections, and announce only confirmed activation.');
