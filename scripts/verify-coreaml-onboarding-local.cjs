// Local integration: real Auth, Storage, PostgREST, SQL rollback, and posting guard.
const fs=require('node:fs'), path=require('node:path'), {randomUUID}=require('node:crypto');
const {spawnSync}=require('node:child_process');
const API='http://127.0.0.1:55321', DB='supabase_db_sentinel-aml';
const BANK='a1000000-0000-4000-8000-000000000001', OTHER_BANK='a1000000-0000-4000-8000-000000000002';
const PASSWORD='CoreAML-Local-Only!2026';
const MIGRATIONS=['supabase/migrations/20261021135039_pending_onboarding_status.sql','supabase/migrations/20261021135215_atomic_customer_onboarding.sql'];
const PNG=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6GoAAAAAASUVORK5CYII=','base64');
const report={generated_at:new Date().toISOString(),checks:[],created_submissions:[],limitations:[
 'Creates synthetic pending applications and uploads real tiny PNG files to local Storage; successful fixtures are retained for browser review.',
 'The forced account-failure SQL probe rolls back; no production changes or migration-history edits.',
 'KYC approval/activation, real document verification, AML rule scenarios, and UI browser execution remain separate tests.',
]};
function run(command,args,input){const p=spawnSync(command,args,{input,encoding:'utf8',maxBuffer:8*1024*1024});if(p.error||p.status!==0)throw new Error(p.error?.message||p.stderr||`${command} failed`);return p.stdout;}
function sql(s){return "'"+String(s).replace(/'/g,"''")+"'";}
function query(s){return run('docker',['exec','-i',DB,'psql','-X','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres','-At'],s);}
function assert(ok,message){if(!ok)throw new Error(message);}
async function check(name,fn){try{await fn();report.checks.push({check:name,result:'PASS'});}catch(e){report.checks.push({check:name,result:'FAIL',detail:e.message});}}
async function main(){
 process.chdir(path.resolve(__dirname,'..'));
 assert(/^project_id\s*=\s*"sentinel-aml"/m.test(fs.readFileSync('supabase/config.toml','utf8')),'Wrong local project.');
 const db=JSON.parse(run('docker',['inspect',DB]))[0];
 assert(db.State?.Running&&(db.NetworkSettings?.Ports?.['5432/tcp']||[]).some(p=>p.HostPort==='55322'),'Expected running local database on 55322.');
 const raw=process.platform==='win32'?run('cmd.exe',['/d','/s','/c','supabase status -o json']):run('supabase',['status','-o','json']);
 const status=JSON.parse(raw);assert(status.API_URL===API,'Expected the loopback API on 55321.');
 const publicKey=status.PUBLISHABLE_KEY||status.ANON_KEY;assert(publicKey,'Missing local publishable key.');
 assert(Number(query("SELECT count(*) FROM information_schema.columns WHERE table_schema='storage' AND table_name='objects' AND column_name='owner_id';").trim())===1,'Storage owner_id column is required; no schema changes applied.');
 assert(Number(query("SELECT count(*) FROM pg_policies WHERE schemaname='public' AND policyname IN ('coreaml_customers_bank_boundary','coreaml_accounts_bank_boundary','coreaml_staff_directory_bank_boundary');").trim())===3,'Apply the previous isolation and staff fixes first.');
 if(process.argv.includes('--apply')){
  for(const file of MIGRATIONS)query("BEGIN; SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='60s';\n"+fs.readFileSync(file,'utf8')+'\nCOMMIT;');
  console.log('Applied onboarding drafts to local Docker only; enum change committed separately. Migration history unchanged.');
 }
 const tokens=new Map();
 async function request(route,method='GET',body,token,contentType='application/json'){
  const response=await fetch(API+route,{method,redirect:'error',signal:AbortSignal.timeout(30000),headers:{apikey:publicKey,'Content-Type':contentType,...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:contentType==='application/json'?JSON.stringify(body):body})});
  const isJson=(response.headers.get('content-type')||'').includes('json');
  return {ok:response.ok,status:response.status,data:isJson?await response.json():Buffer.from(await response.arrayBuffer())};
 }
 async function login(email){if(tokens.has(email))return tokens.get(email);const r=await request('/auth/v1/token?grant_type=password','POST',{email,password:PASSWORD});assert(r.ok&&r.data.access_token,`Fixture login failed for ${email} (HTTP ${r.status}).`);tokens.set(email,r.data.access_token);return r.data.access_token;}
 function makePayload(){const id=randomUUID();return {p_customer_id:id,p_customer_type:'RETAIL',p_first_name:'Synthetic',p_last_name:'Onboarding Test',p_entity_name:null,p_bvn:String(Date.now()).slice(-11),p_id_path:`${BANK}/${id}/id_document.png`,p_utility_path:`${BANK}/${id}/utility_bill.png`};}
 async function upload(payload,token){for(const name of [payload.p_id_path,payload.p_utility_path]){const r=await request('/storage/v1/object/kyc-vault/'+name,'POST',PNG,token,'image/png');assert(r.ok,`Storage upload failed (${r.status}): ${r.data.message||r.data.error||'unknown error'}`);}}
 async function rpc(payload,token){let r;for(let n=0;n<3;n++){r=await request('/rest/v1/rpc/onboard_customer','POST',payload,token);if(r.data?.code!=='PGRST202')return r;await new Promise(resolve=>setTimeout(resolve,1000));}return r;}
 async function customerRows(id,token){const r=await request(`/rest/v1/customers?select=id,kyc_status&id=eq.${id}`,'GET',undefined,token);assert(r.ok&&Array.isArray(r.data),'Customer lookup failed.');return r.data;}
 let first;
 try{
  async function confirmApplication(role,payload=makePayload()){
    const token=await login(`${role}@coreaml-local.test`);await upload(payload,token);
    const r=await rpc(payload,token);assert(r.ok,`Onboarding RPC failed (${r.status}): ${r.data.message||r.data.code||'unknown error'}`);
    const row=r.data?.[0];assert(row?.customer_id===payload.p_customer_id&&row.account_status==='PENDING','Missing or incorrect customer/account result.');
    const a=await request(`/rest/v1/accounts?select=id,balance,status,customer_id&customer_id=eq.${payload.p_customer_id}`,'GET',undefined,token);
    const customers=await customerRows(payload.p_customer_id,token);
    assert(a.ok&&a.data.length===1&&Number(a.data[0].balance)===0&&a.data[0].status==='PENDING'&&customers.length===1&&customers[0].kyc_status==='PENDING','Expected exactly one pending customer/account with zero balance.');
    const retry=await rpc(payload,token);assert(retry.ok&&retry.data?.[0]?.account_id===row.account_id,'Same reference created another account or retry failed.');
    const after=await request(`/rest/v1/accounts?select=id&customer_id=eq.${payload.p_customer_id}`,'GET',undefined,token);assert(after.ok&&after.data.length===1,'Retry duplicated accounts.');
    report.created_submissions.push({role,customer_id:row.customer_id,account_id:row.account_id,account_number:row.account_number});
    if(!first)first={payload,token,row};
  }
  for(const role of ['teller','sales_rep','branch_manager','bankmanager']){
   await check(`${role}: upload documents and atomically create pending account`,()=>confirmApplication(role));
  }
  await check('Corporate application creates a pending zero-balance account',()=>confirmApplication('sales_rep',{...makePayload(),p_customer_type:'CORPORATE',p_first_name:null,p_last_name:null,p_entity_name:'Synthetic Onboarding Company'}));
  assert(first,'No successful onboarding fixture; dependent tests cannot run.');
  await check('Anonymous onboarding RPC denied',async()=>{const r=await rpc(first.payload);assert(!r.ok&&[401,403].includes(r.status),'Anonymous RPC was not denied.');});
  for(const role of ['compliance_officer','head_of_compliance','bank_manager','it_admin']){
   await check(`${role}: banking application creation denied`,async()=>{const r=await rpc(first.payload,await login(`${role}@coreaml-local.test`));assert(!r.ok&&r.data.code==='42501','Expected the banking-role permission check.');});
  }
  await check('Other bank cannot download KYC documents',async()=>{const r=await request('/storage/v1/object/authenticated/kyc-vault/'+first.payload.p_id_path,'GET',undefined,await login('compliance_bank2@coreaml-local.test'));assert(!r.ok&&[400,401,403,404].includes(r.status),'Other bank downloaded a KYC document.');});
  await check('Anonymous KYC document download denied',async()=>{const r=await request('/storage/v1/object/kyc-vault/'+first.payload.p_id_path);assert(!r.ok,'Anonymous document download succeeded.');});
  await check('Upload into another bank folder denied',async()=>{const r=await request(`/storage/v1/object/kyc-vault/${OTHER_BANK}/${randomUUID()}/id_document.png`,'POST',PNG,first.token,'image/png');assert(!r.ok,'Cross-bank upload succeeded.');});
  await check('Changing details on an existing reference is rejected',async()=>{const r=await rpc({...first.payload,p_last_name:'Changed'},first.token);assert(!r.ok&&r.data.code==='22023','An existing application was silently replaced.');});
  await check('Invalid BVN creates no customer',async()=>{const p={...makePayload(),p_bvn:'bad'};const r=await rpc(p,first.token);assert(!r.ok&&r.data.code==='22023','Invalid BVN was not rejected.');assert((await customerRows(p.p_customer_id,first.token)).length===0,'Invalid request left a customer.');});
  await check('Missing documents create no customer',async()=>{const p=makePayload();const r=await rpc(p,first.token);assert(!r.ok&&r.data.code==='22023','Missing documents were not rejected.');assert((await customerRows(p.p_customer_id,first.token)).length===0,'Missing-document request left a customer.');});
  await check('Pending account transaction is rejected before AML triggers',async()=>{const r=await request('/rest/v1/transactions','POST',{account_id:first.row.account_id,transaction_reference:'ONBOARD-PENDING-'+randomUUID(),amount:1,currency:'NGN',transaction_type:'CREDIT',channel:'BRANCH_CASH',transaction_timestamp:new Date().toISOString()},first.token);assert(!r.ok&&r.data.code==='23514','Pending account accepted a posting or failed for an unrelated reason.');});
  await check('Forced account failure rolls back the customer too',async()=>{
   const p=makePayload();await upload(p,first.token);
   try{
    const claims=JSON.parse(Buffer.from(first.token.split('.')[1],'base64url').toString('utf8'));
    const call=`public.onboard_customer(${sql(p.p_customer_id)}::uuid,${sql(p.p_customer_type)},${sql(p.p_first_name)},${sql(p.p_last_name)},NULL,${sql(p.p_bvn)},${sql(p.p_id_path)},${sql(p.p_utility_path)})`;
    query(`BEGIN; SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='60s';
ALTER TABLE public.accounts ADD CONSTRAINT coreaml_onboarding_probe_fail CHECK(customer_id<>${sql(p.p_customer_id)}::uuid) NOT VALID;
SELECT set_config('request.jwt.claims',${sql(JSON.stringify(claims))},true);
SET LOCAL ROLE authenticated;
DO $test$ DECLARE rejected boolean:=false; BEGIN
 BEGIN PERFORM * FROM ${call};
 EXCEPTION WHEN check_violation THEN
  IF position('coreaml_onboarding_probe_fail' in SQLERRM)=0 THEN RAISE; END IF;
  rejected:=true;
 END;
 IF NOT rejected THEN RAISE EXCEPTION 'Account failure was not provoked'; END IF;
 IF EXISTS(SELECT 1 FROM public.customers WHERE id=${sql(p.p_customer_id)}::uuid) THEN RAISE EXCEPTION 'Orphan customer persisted'; END IF;
END $test$; ROLLBACK;`);
    assert((await customerRows(p.p_customer_id,first.token)).length===0,'Rollback probe left a customer.');
   }finally{const r=await request('/storage/v1/object/kyc-vault','DELETE',{prefixes:[p.p_id_path,p.p_utility_path]},first.token);assert(r.ok,'Rollback-probe document cleanup failed.');}
  });
 }finally{
  for(const [email,token]of tokens){try{const r=await request('/auth/v1/logout','POST',undefined,token);if(!r.ok)throw new Error(`HTTP ${r.status}`);}catch(e){report.checks.push({check:`${email}: logout`,result:'FAIL',detail:e.message});}}
  report.summary={pass:report.checks.filter(c=>c.result==='PASS').length,fail:report.checks.filter(c=>c.result==='FAIL').length};
  fs.mkdirSync('.coreaml-local',{recursive:true});fs.writeFileSync('.coreaml-local/onboarding-verification.json',JSON.stringify(report,null,2)+'\n');
  console.table(report.checks.map(({check,result})=>({check,result})));console.log('Summary:',report.summary);console.log('Report: .coreaml-local/onboarding-verification.json');
 }
 if(report.summary.fail)process.exitCode=1;
}
main().catch(e=>{console.error('Onboarding verification stopped:',e.message);process.exitCode=1;});
