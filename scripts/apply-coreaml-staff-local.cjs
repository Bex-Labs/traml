// Applies and verifies the draft staff-profile fix in the named LOCAL Docker DB.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const CONTAINER = 'supabase_db_sentinel-aml';
const MIGRATION = 'supabase/migrations/20261021133605_staff_role_profiles.sql';
const sql = value => "'" + String(value).replace(/'/g, "''") + "'";
function run(args,input) {
  const p=spawnSync('docker',args,{input,encoding:'utf8',maxBuffer:8*1024*1024});
  if(p.error || p.status!==0) throw new Error(p.error?.message || p.stderr || 'Docker command failed');
  return p.stdout;
}
function query(text) {return run(['exec','-i',CONTAINER,'psql','-X','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres','-At'],text);}
function main() {
  process.chdir(path.resolve(__dirname,'..'));
  if(!/^project_id\s*=\s*"sentinel-aml"/m.test(fs.readFileSync('supabase/config.toml','utf8'))) throw new Error('Expected sentinel-aml project.');
  const inspect=JSON.parse(run(['inspect',CONTAINER]))[0];
  if(!inspect.State?.Running || !(inspect.NetworkSettings?.Ports?.['5432/tcp']||[]).some(p=>p.HostPort==='55322')) throw new Error('Expected running local Docker DB on 55322.');
  const users=JSON.parse(query("SELECT json_agg(x) FROM (SELECT id,email,raw_app_meta_data->>'role' AS role,raw_app_meta_data->>'tenant_id' AS tenant_id FROM auth.users WHERE email LIKE '%@coreaml-local.test' ORDER BY email) x;"));
  if(!Array.isArray(users)||users.length!==11)throw new Error('Expected exactly 11 synthetic Auth users.');
  const guardCount=Number(query("SELECT count(*) FROM pg_policies WHERE schemaname='public' AND policyname IN ('coreaml_customers_bank_boundary','coreaml_accounts_bank_boundary') AND permissive='RESTRICTIVE';").trim());
  if(guardCount!==2)throw new Error('Apply and verify the customer/account isolation fix first.');
  query("BEGIN; SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='60s';\n"+fs.readFileSync(MIGRATION,'utf8')+'\nCOMMIT;');
  const checks=[];
  function test(check,statement){try{query(statement);checks.push({check,result:'PASS'});}catch(e){checks.push({check,result:'FAIL',detail:e.message});}}
  for(const user of users){
    const expected=user.role==='it_admin'?11:users.filter(u=>u.tenant_id===user.tenant_id).length;
    const claims={sub:user.id,role:'authenticated',app_metadata:{role:user.role,tenant_id:user.tenant_id}};
    test(`${user.email}: aligned profiles and scoped directories`, `BEGIN;
DO $test$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles p JOIN public.user_profiles s USING(id)
 WHERE p.id=${sql(user.id)}::uuid AND p.role=${sql(user.role)} AND s.role=${sql(user.role)}
 AND p.tenant_id=${sql(user.tenant_id)} AND s.tenant_id=${sql(user.tenant_id)} AND s.is_active=true)
 THEN RAISE EXCEPTION 'Profile mismatch'; END IF;
END $test$;
SELECT set_config('request.jwt.claims',${sql(JSON.stringify(claims))},true);
SET LOCAL ROLE authenticated;
DO $test$ DECLARE pc integer; sc integer; BEGIN
 SELECT count(*) INTO pc FROM public.profiles WHERE email LIKE '%@coreaml-local.test';
 SELECT count(*) INTO sc FROM public.user_profiles WHERE id IN (SELECT id FROM public.profiles WHERE email LIKE '%@coreaml-local.test');
 IF pc<>${expected} OR sc<>${expected} THEN RAISE EXCEPTION 'Directory visibility expected ${expected}, got %/%',pc,sc; END IF;
END $test$;
ROLLBACK;`);
  }
  const officer=users.find(u=>u.email==='compliance_officer@coreaml-local.test');
  test('User metadata cannot change stored staff role',`BEGIN;
UPDATE auth.users SET raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||'{"role":"it_admin","tenant_id":"forged-bank"}'::jsonb WHERE id=${sql(officer.id)}::uuid;
DO $test$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles p JOIN public.user_profiles s USING(id) WHERE p.id=${sql(officer.id)}::uuid AND p.role='compliance_officer' AND s.role='compliance_officer' AND p.tenant_id=${sql(officer.tenant_id)} AND s.tenant_id=${sql(officer.tenant_id)}) THEN RAISE EXCEPTION 'Metadata escalated privileges'; END IF;
END $test$; ROLLBACK;`);
  test('Disabled staff receive no role or bank from token hook',`BEGIN;
UPDATE public.user_profiles SET is_active=false WHERE id=${sql(officer.id)}::uuid;
DO $test$ DECLARE e jsonb; BEGIN
 e:=public.custom_access_token_hook(jsonb_build_object('user_id',${sql(officer.id)},'claims',jsonb_build_object('sub',${sql(officer.id)},'app_metadata',jsonb_build_object('role','it_admin','tenant_id','forged'))));
 IF e#>>'{claims,app_metadata,role}'<>'access_disabled' OR e#>>'{claims,app_metadata,tenant_id}' IS NOT NULL THEN RAISE EXCEPTION 'Inactive staff received privileges'; END IF;
END $test$; ROLLBACK;`);
  test('Hook and trigger functions are not executable by browser roles',`DO $test$ BEGIN
 IF has_function_privilege('authenticated','public.custom_access_token_hook(jsonb)','EXECUTE') OR has_function_privilege('anon','public.custom_access_token_hook(jsonb)','EXECUTE') OR has_function_privilege('authenticated','public.handle_new_user()','EXECUTE') OR has_function_privilege('anon','public.handle_new_user()','EXECUTE') THEN RAISE EXCEPTION 'Public function execution remains'; END IF;
END $test$;`);
  const report={generated_at:new Date().toISOString(),migration_draft:MIGRATION,migration_history_modified:false,checks,
    limitations:['Local SQL/profile verification; no production changes.','Admin invite Edge Function flow and custom-role capabilities still require dedicated fixes/tests.','The token-hook function is tested directly; this does not enable it in config.toml or invalidate existing JWTs.','Customer/account onboarding and transaction/alert workflows remain separate.']};
  fs.mkdirSync('.coreaml-local',{recursive:true});
  fs.writeFileSync('.coreaml-local/staff-verification.json',JSON.stringify(report,null,2)+'\n');
  console.table(checks.map(({check,result})=>({check,result})));
  console.log('Report: .coreaml-local/staff-verification.json. SQL role and metadata probes rolled back.');
  console.log('Rerun the baseline and fixture login setup to verify integration.');
  if(checks.some(c=>c.result==='FAIL'))process.exitCode=1;
}
try{main();}catch(e){console.error('Local staff step stopped:',e.message);process.exitCode=1;}
