'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const h=require('./aml-compatible-db.cjs');
const EXPECTED={case_workflow_staff:'302346675e0a2beab00b6ccf1538b943',review_staff:'0710580ea1103c268cbbf274071fe378',coreaml_case_summary:'ea6ae5607d43e6742404cf0c2c8d8b6f',coreaml_review_decision:'937b513efbf71e99dc4bbef82bb3f14f',coreaml_submit_case_review:'6019b5096cd991536534b9698613cbde'};
const PROTECTED=['suspicious_transaction_reports','coreaml_review_actions','coreaml_review_submissions','coreaml_case_claims','investigation_drafts','alerts','transactions','accounts','customers','user_profiles','report_archives','system_events','coreaml_filing_drafts','coreaml_filing_events','coreaml_filing_exports'];
const read=sql=>h.query('BEGIN TRANSACTION READ ONLY;'+sql+'COMMIT;'),digest=(value,kind='sha256')=>crypto.createHash(kind).update(value).digest('hex');
function functions(sql){return [...sql.matchAll(/CREATE(?: OR REPLACE)? FUNCTION\s+([\w.]+)\([^]*?AS \$\$([^]*?)\$\$;/g)].map(m=>({name:m[1],hash:digest(m[2].replace(/\r\n/g,'\n'),'md5')}));}
const snapshotSql=()=>`SELECT jsonb_build_object(${PROTECTED.map(t=>h.lit(t)+`,(SELECT md5(coalesce(jsonb_agg(${t==='coreaml_filing_drafts'?"to_jsonb(x)-ARRAY['prepared_by','submitted_request_id','final_review_request_id','pending_outcome_id']":"to_jsonb(x)"} ORDER BY ${t==='coreaml_filing_drafts'?"(to_jsonb(x)-ARRAY['prepared_by','submitted_request_id','final_review_request_id','pending_outcome_id'])::text":"to_jsonb(x)::text"})::text,'null')) FROM public.${t} x)`).join(',')}) AS state`;
// Compare logical source without rewriting stored functions or ignoring code changes.
function sourceHashSql(qualifiedName){const [schema,name]=qualifiedName.split('.');return `SELECT md5(replace(prosrc,chr(13)||chr(10),chr(10))) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=${h.lit(schema)} AND p.proname=${h.lit(name)};`;}
function verifyFunctions(list){for(const f of list)assert.equal(read(sourceHashSql(f.name)),f.hash,'Installed function differs: '+f.name);}
function probeSql(){return `DO $$ DECLARE p public.user_profiles%ROWTYPE;d jsonb;seen integer:=0;BEGIN
 FOR p IN SELECT DISTINCT ON(role) * FROM public.user_profiles WHERE tenant_id=${h.lit(h.BANK)} AND is_active IS TRUE AND role IN ('head_of_compliance','compliance_officer') ORDER BY role,id LOOP
  seen:=seen+1;PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',p.id,'role','authenticated','app_metadata',jsonb_build_object('role',p.role,'tenant_id',p.tenant_id))::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';d:=public.coreaml_filing_read_v2(NULL,0,NULL,'ALL');IF d->>'actor_id'<>p.id::text OR d->>'tenant_id'<>p.tenant_id OR d->>'role'<>p.role THEN RAISE EXCEPTION 'Reporting read scope mismatch';END IF;
  d:=public.coreaml_filing_progress(ARRAY[]::text[]);IF d->>'actor_id'<>p.id::text OR d->'rows'<>'[]'::jsonb THEN RAISE EXCEPTION 'Progress scope mismatch';END IF;EXECUTE 'RESET ROLE';
 END LOOP;IF seen<>2 THEN RAISE EXCEPTION 'Both local reporting roles are required for verification';END IF;
 IF has_function_privilege('anon','public.coreaml_filing_read_v2(uuid,integer,text,text)','EXECUTE') OR has_function_privilege('anon','public.coreaml_filing_progress(text[])','EXECUTE') OR has_function_privilege('anon','public.coreaml_filing_export_read_v2(uuid)','EXECUTE') OR has_function_privilege('authenticated','public.coreaml_filing_commit(uuid,uuid,uuid,text,integer,text,jsonb)','EXECUTE') OR has_function_privilege('service_role','coreaml_private.filing_commit_v1(uuid,uuid,uuid,text,integer,text,jsonb)','EXECUTE') OR has_function_privilege('authenticated','coreaml_private.filing_commit_v1(uuid,uuid,uuid,text,integer,text,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Unexpected reporting privilege';END IF;
 IF EXISTS(SELECT 1 FROM pg_class WHERE oid=ANY(ARRAY['public.coreaml_filing_drafts'::regclass,'public.coreaml_filing_events'::regclass,'public.coreaml_filing_exports'::regclass]) AND NOT relrowsecurity) THEN RAISE EXCEPTION 'Reporting RLS is missing';END IF;
 IF EXISTS(SELECT 1 FROM pg_proc WHERE oid=ANY(ARRAY['public.coreaml_filing_read_v2(uuid,integer,text,text)'::regprocedure,'public.coreaml_filing_commit(uuid,uuid,uuid,text,integer,text,jsonb)'::regprocedure,'public.coreaml_filing_progress(text[])'::regprocedure,'public.coreaml_filing_export_read_v2(uuid)'::regprocedure]) AND (NOT prosecdef OR NOT coalesce(proconfig @> ARRAY['search_path=""'],false))) THEN RAISE EXCEPTION 'Reporting function boundary differs';END IF;
 END $$;
 DO $$ BEGIN IF (SELECT state FROM pg_temp.filing_upgrade_before) IS DISTINCT FROM (${snapshotSql()}) THEN RAISE EXCEPTION 'Protected records changed during upgrade';END IF;END $$;`;}
function main(){
 h.assertLocal();assert.equal(h.DB,'supabase_db_sentinel-aml');assert.equal(h.API,'http://127.0.0.1:55321');
 const foundation=JSON.parse(read("SELECT jsonb_object_agg(proname,md5(prosrc)) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('public','coreaml_private') AND p.proname IN ("+Object.keys(EXPECTED).map(h.lit).join(',')+");"));assert.deepEqual(foundation,EXPECTED,'Reviewed case workflow foundation differs; no changes made');
 assert.equal(read("SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid='public.suspicious_transaction_reports'::regclass AND t.tgname='trg_network_contagion' AND t.tgenabled='D' AND md5(p.prosrc)='30dd775e66c84360d03e2766ab475928';"),'1','Existing propagation quarantine differs');
 const v1=fs.readFileSync(path.join(h.ROOT,'sql/coreaml-filing-workspace-local.sql'),'utf8').replace(/\r/g,''),sql=fs.readFileSync(path.join(h.ROOT,'sql/coreaml-filing-review-v2-local.sql'),'utf8').replace(/\r/g,''),stamp='coreaml_filing_v2:'+digest(sql);
 assert.equal(read("SELECT obj_description('public.coreaml_filing_drafts'::regclass);"),'coreaml_filing_v1:'+digest(v1),'Install the existing filing workspace first; no reset is required');
 const installed=read("SELECT count(*) FROM pg_attribute WHERE attrelid='public.coreaml_filing_drafts'::regclass AND attname='prepared_by' AND NOT attisdropped;")==='1';
 if(installed){assert.equal(read("SELECT col_description('public.coreaml_filing_drafts'::regclass,(SELECT attnum FROM pg_attribute WHERE attrelid='public.coreaml_filing_drafts'::regclass AND attname='prepared_by'));"),stamp,'Different reporting upgrade exists; it will not be overwritten');verifyFunctions(functions(sql));verifyFunctions(functions(v1).filter(f=>!['coreaml_private.filing_context','public.coreaml_filing_commit'].includes(f.name)));verifyFunctions(functions(v1).filter(f=>f.name==='public.coreaml_filing_commit').map(f=>({...f,name:'coreaml_private.filing_commit_v1'})));}
 else verifyFunctions(functions(v1));
 require('./bundle-filing-schema.cjs').buildSchemaBundle(h.ROOT);
 const before=JSON.parse(read(snapshotSql()+';'));
 const install=installed?'':sql+`COMMENT ON COLUMN public.coreaml_filing_drafts.prepared_by IS ${h.lit(stamp)};`;
 const probes=probeSql();
 const plan='BEGIN;CREATE TEMP TABLE filing_upgrade_before ON COMMIT DROP AS '+snapshotSql()+';'+install+probes;
 h.query(plan+'ROLLBACK;');h.query(plan+'COMMIT;');
 const after=JSON.parse(read(snapshotSql()+';'));assert.deepEqual(after,before,'Protected data changed after installation; preserve output');
 const folder=path.join(h.ROOT,'.coreaml-local/filing-review-v2');fs.mkdirSync(folder,{recursive:true});const file=path.join(folder,'install-'+Date.now()+'.json');fs.writeFileSync(file,JSON.stringify({at:new Date().toISOString(),installed_before:installed,sql_sha256:digest(sql),protected_before:before,protected_after:after,notes:['No filing event, report preparation, approval or external response was created.','No customer, ledger, case or investigation ownership was changed.','Signed-in local verification and Edge Runtime restart remain necessary.']},null,2)+'\n');
 console.log('PASS Same-plan rollback probe and both reporting-role reads');console.log('PASS Restricted write boundary and original data preserved');console.log('Reporting review upgrade installed. Report: '+path.relative(h.ROOT,file));console.log('Restart function serving, then hard-refresh CoreAML. Existing preparations need officer save and final report approval.');
}
if(require.main===module)try{main();}catch(e){console.error('Reporting review upgrade stopped: '+e.message);process.exitCode=1;}
module.exports={main,functions,snapshotSql,probeSql,sourceHashSql};
