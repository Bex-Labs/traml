// Install the existing cash foundation into the named local Docker DB only.
const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process'),{createHash}=require('node:crypto');
const DB='supabase_db_sentinel-aml',SOURCE='docs/sql/cash-approval-foundation-source.sql';
function buildDraft(source){
 const normalized=source.replace(/\r\n/g,'\n');
 if(createHash('sha256').update(normalized).digest('hex')!=='aee2646a7855232d4bc0316f0579563ab0c5cc6aa9184b78da016adfd9fa671d')throw Error('Unexpected cash foundation source; stopped before any database change.');
 // Staff-profile remediation supersedes the historical role list. Keep it intact.
 let sql=normalized.slice(normalized.indexOf('create table public.cash_transaction_approvals'));
 sql="create schema if not exists coreaml_private;\ngrant usage on schema coreaml_private to authenticated;\n"+sql;
 const specs=[['post_cash_transaction','p_account_id uuid,p_till_id uuid,p_amount numeric,p_direction text,p_narration text,p_request_reference text','uuid,uuid,numeric,text,text,text','p_account_id,p_till_id,p_amount,p_direction,p_narration,p_request_reference'],['review_cash_transaction','p_approval_id uuid,p_approve boolean','uuid,boolean','p_approval_id,p_approve']];
 // Keep privileged RPC implementations out of the exposed public schema.
 for(const [name,args,types,values]of specs){
  sql=sql.replaceAll('function public.'+name+'(', 'function coreaml_private.'+name+'(');
  sql+=`\ncreate function public.${name}(${args}) returns jsonb language sql security invoker set search_path='' as $wrapper$ select coreaml_private.${name}(${values}); $wrapper$;
revoke all on function public.${name}(${types}) from public,anon;
grant execute on function public.${name}(${types}) to authenticated;\n`;
 }
 return sql;
}
function run(args,input){const r=spawnSync('docker',args,{input,encoding:'utf8',timeout:90000,maxBuffer:8*1024*1024});if(r.error||r.status!==0)throw Error(r.error?.message||r.stderr||'Docker failed');return r.stdout;}
const query=sql=>run(['exec','-i',DB,'psql','-X','-q','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres','-At'],sql);
function main(){
 process.chdir(path.resolve(__dirname,'..'));
 if(!/^project_id\s*=\s*"sentinel-aml"/m.test(fs.readFileSync('supabase/config.toml','utf8')))throw Error('Wrong local project');
 const db=JSON.parse(run(['inspect',DB]))[0];if(!db.State?.Running||!db.NetworkSettings?.Ports?.['5432/tcp']?.some(p=>p.HostPort==='55322'))throw Error('Expected local Docker database on port 55322');
 const draft=buildDraft(fs.readFileSync(SOURCE,'utf8'));
 const inventory=JSON.parse(query(`SELECT json_build_object('post',to_regprocedure('public.post_cash_transaction(uuid,uuid,numeric,text,text,text)') IS NOT NULL,'review',to_regprocedure('public.review_cash_transaction(uuid,boolean)') IS NOT NULL,'approvals',to_regclass('public.cash_transaction_approvals') IS NOT NULL,'outbox',to_regclass('public.transaction_evaluation_outbox') IS NOT NULL);`));
 if(Object.values(inventory).some(Boolean))throw Error('Cash foundation is already present or partially installed; refusing to overwrite it. Run verification and share the report.');
 query(`BEGIN;SET LOCAL lock_timeout='5s';SET LOCAL statement_timeout='60s';
 CREATE TEMP TABLE coreaml_cash_preserve AS SELECT
  (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='public.user_profiles'::regclass AND conname='user_profiles_role_check') AS role_constraint,
  (SELECT jsonb_object_agg(tgname,tgenabled) FROM pg_trigger WHERE tgrelid='public.transactions'::regclass AND NOT tgisinternal) AS triggers;
 DO $pre$ BEGIN
  IF (SELECT count(*) FROM public.user_profiles p JOIN auth.users u USING(id) WHERE u.email IN ('teller@coreaml-local.test','branch_manager@coreaml-local.test') AND p.is_active AND p.role=split_part(u.email,'@',1) AND p.tenant_id='a1000000-0000-4000-8000-000000000001')<>2 THEN RAISE EXCEPTION 'Requires verified active local teller and branch-manager fixtures';END IF;
  IF to_regprocedure('public.approve_manual_kyc(uuid,uuid,text,text,text,jsonb)') IS NULL THEN RAISE EXCEPTION 'Requires verified manual KYC foundation';END IF;
 END $pre$;
 ${draft}
 DO $post$ DECLARE old record; BEGIN
  SELECT * INTO old FROM coreaml_cash_preserve;
  IF old.role_constraint IS DISTINCT FROM (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='public.user_profiles'::regclass AND conname='user_profiles_role_check') THEN RAISE EXCEPTION 'Staff role constraint changed';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_each_text(old.triggers) x LEFT JOIN pg_trigger t ON t.tgrelid='public.transactions'::regclass AND t.tgname=x.key WHERE t.oid IS NULL OR t.tgenabled::text<>x.value) THEN RAISE EXCEPTION 'Existing transaction trigger state changed';END IF;
  IF EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid IN ('public.post_cash_transaction(uuid,uuid,numeric,text,text,text)'::regprocedure,'public.review_cash_transaction(uuid,boolean)'::regprocedure) AND p.prosecdef) THEN RAISE EXCEPTION 'Public RPC must be security invoker';END IF;
 END $post$;
 NOTIFY pgrst,'reload schema';COMMIT;`);
 console.log('Installed cash foundation ONLY in local Docker. Existing staff role constraint and transaction trigger states preserved; migration history unchanged.');
 console.log('Next: node scripts/verify-coreaml-cash-local.cjs');
}
module.exports={buildDraft};if(require.main===module)try{main();}catch(e){console.error(e.message);process.exitCode=1;}
