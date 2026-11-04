// Real local Auth + Storage + PostgREST checks. Never accepts a remote target.
const fs=require('node:fs'),path=require('node:path'),{randomUUID}=require('node:crypto'),{spawnSync}=require('node:child_process');
const API='http://127.0.0.1:55321',DB='supabase_db_sentinel-aml',BANK='a1000000-0000-4000-8000-000000000001';
const PASSWORD='CoreAML-Local-Only!2026',DRAFT='docs/sql/manual-kyc-activation.sql';
const PNG=Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6GoAAAAAASUVORK5CYII=','base64');
const report={generated_at:new Date().toISOString(),scope:'Local manual KYC attestation and atomic pending-account activation',checks:[],applications:[],limitations:[
 'Synthetic manual evidence references only: no real identity, sanctions, PEP or document-authenticity verification.',
 'Successful fixtures remain locally; rejected applications stay pending. No cash posting or AML detection tested.',
 'Browser form execution is a separate check; no hosted deployment or migration-history changes.'
]};
function run(cmd,args,input){const p=spawnSync(cmd,args,{input,encoding:'utf8',maxBuffer:8*1024*1024});if(p.error||p.status!==0)throw Error(p.error?.message||p.stderr||`${cmd} failed`);return p.stdout;}
function query(sql){return run('docker',['exec','-i',DB,'psql','-X','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres','-At'],sql);}
function lit(v){return "'"+String(v).replace(/'/g,"''")+"'";}
function assert(ok,msg){if(!ok)throw Error(msg);}
async function check(name,fn){try{await fn();report.checks.push({check:name,result:'PASS'});}catch(e){report.checks.push({check:name,result:'FAIL',detail:e.message});}}
async function main(){
 process.chdir(path.resolve(__dirname,'..'));
 assert(/^project_id\s*=\s*"sentinel-aml"/m.test(fs.readFileSync('supabase/config.toml','utf8')),'Wrong local project.');
 const db=JSON.parse(run('docker',['inspect',DB]))[0];
 assert(db.State?.Running&&(db.NetworkSettings?.Ports?.['5432/tcp']||[]).some(p=>p.HostPort==='55322'),'Expected local Docker database on port 55322.');
 const raw=process.platform==='win32'?run('cmd.exe',['/d','/s','/c','supabase status -o json']):run('supabase',['status','-o','json']);
 const status=JSON.parse(raw);assert(status.API_URL===API,'Expected loopback API on 55321.');
 const key=status.PUBLISHABLE_KEY||status.ANON_KEY;assert(key,'Missing local public API key.');
 assert(Number(query("SELECT count(*) FROM pg_policies WHERE policyname IN ('coreaml_customers_bank_boundary','coreaml_accounts_bank_boundary','coreaml_staff_directory_bank_boundary');").trim())===3,'Earlier isolation/staff fixes are required.');
 assert(query("SELECT to_regprocedure('public.onboard_customer(uuid,text,text,text,text,text,text,text)') IS NOT NULL;").trim()==='t','Earlier onboarding fix is required.');
 if(process.argv.includes('--apply')){query("BEGIN;SET LOCAL lock_timeout='5s';SET LOCAL statement_timeout='60s';\n"+fs.readFileSync(DRAFT,'utf8')+'\nCOMMIT;');console.log('Applied manual KYC draft ONLY to local Docker; migration history unchanged.');}
 const tokens=new Map();
 async function req(route,method='GET',body,token,type='application/json'){
  const r=await fetch(API+route,{method,redirect:'error',signal:AbortSignal.timeout(30000),headers:{apikey:key,'Content-Type':type,...(token?{Authorization:`Bearer ${token}`}:{})},...(body===undefined?{}:{body:type==='application/json'?JSON.stringify(body):body})});
  return {ok:r.ok,status:r.status,data:(r.headers.get('content-type')||'').includes('json')?await r.json():await r.text()};
 }
 async function login(role){if(tokens.has(role))return tokens.get(role);const r=await req('/auth/v1/token?grant_type=password','POST',{email:`${role}@coreaml-local.test`,password:PASSWORD});assert(r.ok&&r.data.access_token,`Login failed for ${role}, HTTP ${r.status}`);tokens.set(role,r.data.access_token);return r.data.access_token;}
 async function rpc(payload,token){let r;for(let i=0;i<3;i++){r=await req('/rest/v1/rpc/approve_manual_kyc','POST',payload,token);if(r.data?.code!=='PGRST202')return r;await new Promise(resolve=>setTimeout(resolve,500));}return r;}
 async function application(){
  const id=randomUUID(),token=await login('teller');
  const p={p_customer_id:id,p_customer_type:'RETAIL',p_first_name:'Synthetic',p_last_name:'KYC Review',p_entity_name:null,
   p_bvn:null,p_id_path:`${BANK}/${id}/id_document.png`,p_utility_path:`${BANK}/${id}/utility_bill.png`};
  // Allocate a BVN absent from all banks using local SQL, then upload real tiny PNGs.
  for(let i=0;i<10;i++){const bvn=String(10000000000n+BigInt('0x'+randomUUID().replace(/-/g,'').slice(0,12))%90000000000n);if(query(`SELECT NOT EXISTS(SELECT 1 FROM public.customers WHERE bvn=${lit(bvn)});`).trim()==='t'){p.p_bvn=bvn;break;}}
  assert(p.p_bvn,'Could not allocate a fresh synthetic BVN.');
  for(const object of [p.p_id_path,p.p_utility_path]){const r=await req('/storage/v1/object/kyc-vault/'+object,'POST',PNG,token,'image/png');assert(r.ok,`Document upload failed (HTTP ${r.status}).`);}
  const r=await req('/rest/v1/rpc/onboard_customer','POST',p,token);assert(r.ok&&r.data?.[0]?.account_status==='PENDING',`Fixture onboarding failed (${r.data?.message||r.status}).`);
  const row=r.data[0];report.applications.push({customer_id:id,account_id:row.account_id,account_number:row.account_number});
  return {p,row,review:{p_review_id:randomUUID(),p_customer_id:id,p_identity_reference:'SYNTHETIC LOCAL ID EVIDENCE',p_screening_reference:'SYNTHETIC LOCAL SCREENING EVIDENCE',p_notes:'Synthetic manual review for local software verification only; no external checks performed.',p_flags:{face_to_face:false,cash_intensive:false,complex_structure:false,pep_or_adverse_media:false}}};
 }
 async function rejected(p,token,code){const r=await rpc(p,token);assert(!r.ok&&r.data?.code===code,`Expected ${code}, got HTTP ${r.status} / ${r.data?.code||'no code'}.`);}
 const officer=await login('compliance_officer');let first;
 try{
  await check('Teller creates fresh pending fixture with private documents',async()=>{first=await application();});
  if(!first){report.checks.push({check:'Dependent KYC approval checks',result:'BLOCKED',detail:'Fixture creation failed.'});return;}
  await check('Reviewer can download same-bank private documents',async()=>{for(const name of [first.p.p_id_path,first.p.p_utility_path]){const r=await req('/storage/v1/object/authenticated/kyc-vault/'+name,'GET',undefined,officer);assert(r.ok,'Reviewer could not retrieve document.');}});
  await check('Anonymous approval denied',async()=>{const r=await rpc(first.review);assert(!r.ok&&[401,403].includes(r.status),'Anonymous approval was not denied.');});
  for(const role of ['teller','sales_rep','branch_manager','bankmanager','bank_manager','it_admin','compliance_bank2','compliance_bank3','compliance_bank4']){
   await check(`${role}: approval denied`,async()=>rejected(first.review,await login(role),'42501'));
  }
  await check('Missing evidence rejected',()=>rejected({...first.review,p_identity_reference:''},officer,'22023'));
  await check('Malformed risk flags rejected',()=>rejected({...first.review,p_flags:{face_to_face:'true'}},officer,'22023'));
  await check('Direct customer completion is blocked',async()=>{const r=await req(`/rest/v1/customers?id=eq.${first.p.p_customer_id}`,'PATCH',{kyc_status:'COMPLETED'},officer);assert(!r.ok&&r.data?.code==='42501','Direct completion was not denied.');});
  await check('Direct pending-account activation is blocked',async()=>{
   const claims=JSON.parse(Buffer.from(officer.split('.')[1],'base64url').toString());
   query(`BEGIN;SELECT set_config('request.jwt.claims',${lit(JSON.stringify(claims))},true);SET LOCAL ROLE authenticated;
DO $probe$ DECLARE denied boolean:=false; BEGIN BEGIN UPDATE public.accounts SET status='ACTIVE' WHERE id=${lit(first.row.account_id)}::uuid; EXCEPTION WHEN insufficient_privilege THEN denied:=true; END; IF NOT denied AND EXISTS(SELECT 1 FROM public.accounts WHERE id=${lit(first.row.account_id)}::uuid AND status='ACTIVE') THEN RAISE EXCEPTION 'Direct activation succeeded'; END IF; END $probe$;ROLLBACK;`);
  });
  await check('Officer atomically records manual review and activates zero-balance account',async()=>{
   const r=await rpc(first.review,officer);assert(r.ok&&r.data?.[0]?.account_status==='ACTIVE',r.data?.message||'Approval not confirmed.');
   const a=await req(`/rest/v1/accounts?select=status,balance&id=eq.${first.row.account_id}`,'GET',undefined,officer);
   const c=await req(`/rest/v1/customers?select=kyc_status&id=eq.${first.p.p_customer_id}`,'GET',undefined,officer);
   assert(a.ok&&a.data.length===1&&a.data[0].status==='ACTIVE'&&Number(a.data[0].balance)===0&&c.ok&&c.data.length===1&&c.data[0].kyc_status==='COMPLETED','Customer/account state mismatch.');
  });
  await check('Same review reference retries without duplicate review',async()=>{const r=await rpc(first.review,officer);const rows=await req(`/rest/v1/kyc_reviews?customer_id=eq.${first.p.p_customer_id}`,'GET',undefined,officer);assert(r.ok&&rows.ok&&rows.data.length===1&&rows.data[0].id===first.review.p_review_id&&rows.data[0].review_method==='MANUAL_ATTESTATION','Retry or evidence mismatch.');});
  await check('Changing evidence after approval is rejected',()=>rejected({...first.review,p_notes:'Changed evidence after the completed manual review.'},officer,'22023'));
  await check('Cross-bank reviewer cannot read review record',async()=>{const r=await req(`/rest/v1/kyc_reviews?customer_id=eq.${first.p.p_customer_id}`,'GET',undefined,await login('compliance_bank2'));assert(r.ok&&r.data.length===0,'Cross-bank review exposure.');});
  await check('Browser roles cannot write or delete review records',async()=>{
   assert(query("SELECT has_table_privilege('authenticated','public.kyc_reviews','INSERT') OR has_table_privilege('authenticated','public.kyc_reviews','UPDATE') OR has_table_privilege('authenticated','public.kyc_reviews','DELETE');").trim()==='f','Browser has review mutation privilege.');
  });
  await check('PEP/adverse-media review requires head-of-compliance',async()=>{const f=await application();f.review.p_flags.pep_or_adverse_media=true;await rejected(f.review,officer,'42501');const r=await rpc(f.review,await login('head_of_compliance'));assert(r.ok&&r.data?.[0]?.account_status==='ACTIVE',r.data?.message||'Head approval failed.');});
  await check('Forced account-update failure rolls back customer and review',async()=>{
   const f=await application(),claims=JSON.parse(Buffer.from(officer.split('.')[1],'base64url').toString());const p=f.review;
   query(`BEGIN;SET LOCAL lock_timeout='5s';SET LOCAL statement_timeout='60s';
ALTER TABLE public.accounts ADD CONSTRAINT coreaml_kyc_probe_fail CHECK(id<>${lit(f.row.account_id)}::uuid OR status<>'ACTIVE') NOT VALID;
SELECT set_config('request.jwt.claims',${lit(JSON.stringify(claims))},true);SET LOCAL ROLE authenticated;
DO $probe$ DECLARE failed boolean:=false; BEGIN
 BEGIN PERFORM * FROM public.approve_manual_kyc(${lit(p.p_review_id)}::uuid,${lit(p.p_customer_id)}::uuid,${lit(p.p_identity_reference)},${lit(p.p_screening_reference)},${lit(p.p_notes)},${lit(JSON.stringify(p.p_flags))}::jsonb);
 EXCEPTION WHEN check_violation THEN IF position('coreaml_kyc_probe_fail' in SQLERRM)=0 THEN RAISE; END IF;failed:=true;END;
 IF NOT failed THEN RAISE EXCEPTION 'Forced account failure did not occur';END IF;
 IF EXISTS(SELECT 1 FROM public.customers WHERE id=${lit(p.p_customer_id)}::uuid AND kyc_status<>'PENDING') OR EXISTS(SELECT 1 FROM public.kyc_reviews WHERE id=${lit(p.p_review_id)}::uuid) THEN RAISE EXCEPTION 'Partial approval persisted';END IF;
END $probe$;ROLLBACK;`);
  });
 }finally{
  for(const [role,token]of tokens){try{const r=await req('/auth/v1/logout','POST',undefined,token);assert(r.ok,`Logout failed: ${role}`);}catch(e){report.checks.push({check:`${role}: logout`,result:'FAIL',detail:e.message});}}
  report.summary={pass:report.checks.filter(c=>c.result==='PASS').length,fail:report.checks.filter(c=>c.result==='FAIL').length,blocked:report.checks.filter(c=>c.result==='BLOCKED').length};
  fs.mkdirSync('.coreaml-local',{recursive:true});fs.writeFileSync('.coreaml-local/kyc-verification.json',JSON.stringify(report,null,2)+'\n');console.table(report.checks.map(({check,result})=>({check,result})));console.log('Summary:',report.summary);console.log('Report: .coreaml-local/kyc-verification.json');
  if(report.summary.fail||report.summary.blocked)process.exitCode=1;
 }
}
main().catch(e=>{console.error(e.message);process.exitCode=1;});
