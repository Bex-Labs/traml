import fs from 'node:fs';import assert from 'node:assert/strict';import {createHash} from 'node:crypto';
const dir=new URL('../js/vendor/',import.meta.url),manifest=JSON.parse(fs.readFileSync(new URL('supabase-js-2.118.0.manifest.json',dir),'utf8'));
// Git on Windows may convert LF to CRLF. Ignore only that conversion; retain
// the original expected digest and reject all other content differences.
const code=fs.readFileSync(new URL('supabase-js-2.118.0.js',dir),'utf8').replace(/\r\n/g,'\n');
assert.equal(createHash('sha256').update(code).digest('hex'),manifest.sha256);assert.equal(manifest.version,'2.118.0');assert.deepEqual(manifest.external_imports,[]);
const config=fs.readFileSync(new URL('../js/config.js',import.meta.url),'utf8');assert(config.includes("from './vendor/supabase-js-2.118.0.js'"));assert(!config.includes('cdn.jsdelivr.net'));
const {createClient}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));assert.equal(typeof createClient,'function');
const requests=[];
const client=createClient('http://127.0.0.1:55321','synthetic-public-key',{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false},global:{fetch:async(url,options)=>{
 requests.push({url:String(url),method:options?.method||'GET',body:options?.body});
 const body=String(url).includes('/rpc/')?[{account_status:'ACTIVE',review_id:'synthetic-review'}]:String(url).includes('/storage/')?{signedURL:'/object/sign/synthetic?token=fake'}:[];
 return new Response(JSON.stringify(body),{status:200,headers:{'Content-Type':'application/json'}});
}}});
const session=await client.auth.getSession();assert.equal(session.error,null);assert.equal(session.data.session,null);
const rows=await client.from('customers').select('id').limit(1).abortSignal(AbortSignal.timeout(2000));assert.equal(rows.error,null);assert.deepEqual(rows.data,[]);
const payload={p_review_id:'synthetic-review'};const rpc=await client.rpc('approve_manual_kyc',payload);assert.equal(rpc.error,null);assert.equal(rpc.data[0].account_status,'ACTIVE');assert.equal(JSON.parse(requests.at(-1).body).p_review_id,payload.p_review_id);
const storage=await client.storage.from('kyc-vault').createSignedUrl('synthetic.png',120);assert.equal(storage.error,null);assert(storage.data.signedUrl.startsWith('http://127.0.0.1:55321/storage/v1/object/sign/'));
assert(requests.every(r=>r.url.startsWith('http://127.0.0.1:55321/')));await client.removeAllChannels();await client.auth.dispose();
console.log('PASS: bundled SDK hash/export, local config import, session read, PostgREST query, RPC payload and Storage signed-link handling with mocked HTTP; no external imports.');
