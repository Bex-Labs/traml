'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const h=require('./aml-compatible-db.cjs'),v2=require('./apply-filing-review-v2-local.cjs');
const read=sql=>h.query('BEGIN READ ONLY;'+sql+'COMMIT;'),hash=s=>crypto.createHash('sha256').update(s.replace(/\r/g,'')).digest('hex');
const sourceHashSql=name=>{const [schema,fn]=name.split('.');return `SELECT md5(replace(prosrc,chr(13)||chr(10),chr(10))) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=${h.lit(schema)} AND p.proname=${h.lit(fn)};`;};
function verifyFunctions(list){for(const f of list)assert.equal(read(sourceHashSql(f.name)),f.hash,'Installed function differs: '+f.name);}
function snapshotSql(routes){return `SELECT (${v2.snapshotSql()})||jsonb_build_object('coreaml_reporting_routes',${routes?"(SELECT md5(coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text)::text,'null')) FROM public.coreaml_reporting_routes x)":"md5('null')"}) AS state`;}
function probeSql(){const prior=v2.probeSql().split(' DO $$ BEGIN IF (SELECT state FROM pg_temp.filing_upgrade_before)')[0];return prior+`
 DO $$ BEGIN
 IF has_function_privilege('anon','public.coreaml_prepare_case_report(uuid,integer,uuid)','EXECUTE') OR has_function_privilege('authenticated','coreaml_private.reporting_review_context_v3(uuid,text,uuid,boolean)','EXECUTE') OR has_function_privilege('service_role','coreaml_private.reporting_review_decision_v3(uuid,text,uuid,text,text,text,uuid)','EXECUTE') OR has_table_privilege('authenticated','public.coreaml_reporting_routes','SELECT') THEN RAISE EXCEPTION 'Unexpected streamlined reporting privilege';END IF;
 IF EXISTS(SELECT 1 FROM pg_proc WHERE oid=ANY(ARRAY['public.coreaml_prepare_case_report(uuid,integer,uuid)'::regprocedure,'coreaml_private.reporting_review_context_v3(uuid,text,uuid,boolean)'::regprocedure,'coreaml_private.reporting_review_decision_v3(uuid,text,uuid,text,text,text,uuid)'::regprocedure]) AND (NOT prosecdef OR NOT coalesce(proconfig @> ARRAY['search_path=""'],false))) THEN RAISE EXCEPTION 'Streamlined function boundary differs';END IF;
 IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.coreaml_reporting_routes'::regclass) THEN RAISE EXCEPTION 'Reporting route RLS missing';END IF;
 IF (SELECT state FROM pg_temp.filing_upgrade_before) IS DISTINCT FROM (${snapshotSql(true)}) THEN RAISE EXCEPTION 'Protected records changed during streamlined reporting installation';END IF;
 END $$;`;}
function main(){
 h.assertLocal();assert.equal(h.DB,'supabase_db_sentinel-aml');assert.equal(h.API,'http://127.0.0.1:55321');
 const sql=fs.readFileSync(path.join(h.ROOT,'sql/coreaml-filing-streamlined-v3-local.sql'),'utf8').replace(/\r/g,''),oldSql=fs.readFileSync(path.join(h.ROOT,'sql/coreaml-filing-review-v2-local.sql'),'utf8').replace(/\r/g,''),base=fs.readFileSync(path.join(h.ROOT,'sql/coreaml-filing-workspace-local.sql'),'utf8').replace(/\r/g,''),stamp='coreaml_filing_v3:'+hash(sql);
 assert.equal(read("SELECT obj_description('public.coreaml_filing_drafts'::regclass);"),'coreaml_filing_v1:'+hash(base),'Existing filing workspace differs');
 assert.equal(read("SELECT col_description('public.coreaml_filing_drafts'::regclass,(SELECT attnum FROM pg_attribute WHERE attrelid='public.coreaml_filing_drafts'::regclass AND attname='prepared_by'));"),'coreaml_filing_v2:'+hash(oldSql),'Install the independent-review database upgrade first');
 assert.equal(read("SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid='public.suspicious_transaction_reports'::regclass AND t.tgname='trg_network_contagion' AND t.tgenabled='D' AND md5(p.prosrc)='30dd775e66c84360d03e2766ab475928';"),'1','Existing propagation quarantine differs');
 const installed=read("SELECT to_regclass('public.coreaml_reporting_routes') IS NOT NULL;")==='t';
 const foundation=v2.functions(fs.readFileSync(path.join(h.ROOT,'scripts/filing-tests/streamlined-foundation.sql'),'utf8').replace(/\r/g,''));
 verifyFunctions(foundation.filter(f=>!installed||!['public.coreaml_review_decision','public.coreaml_case_worklist_priority','public.coreaml_my_review_submissions'].includes(f.name)));
 if(installed){assert.equal(read("SELECT obj_description('public.coreaml_reporting_routes'::regclass);"),stamp,'Different streamlined reporting installation exists; it will not be overwritten');verifyFunctions(v2.functions(sql));}
 else verifyFunctions(v2.functions(oldSql));
 verifyFunctions(v2.functions(base).filter(f=>!['coreaml_private.filing_context','public.coreaml_filing_commit'].includes(f.name)));
 verifyFunctions(v2.functions(base).filter(f=>f.name==='public.coreaml_filing_commit').map(f=>({...f,name:'coreaml_private.filing_commit_v1'})));
 const before=JSON.parse(read(snapshotSql(installed)+';')),folder=path.join(h.ROOT,'.coreaml-local/filing-streamlined-v3');fs.mkdirSync(folder,{recursive:true});const file=path.join(folder,'install-'+Date.now()+'.json'),record={at:new Date().toISOString(),installed_before:installed,sql_sha256:hash(sql),status:'CHECKED',protected_before:before};const journal=()=>fs.writeFileSync(file,JSON.stringify(record,null,2)+'\n');journal();
 const plan='BEGIN;CREATE TEMP TABLE filing_upgrade_before ON COMMIT DROP AS '+snapshotSql(installed)+';'+(installed?'':sql+`COMMENT ON TABLE public.coreaml_reporting_routes IS ${h.lit(stamp)};`)+probeSql();
 h.query(plan+'ROLLBACK;');record.status='ROLLBACK_PROBE_PASSED';journal();record.status='COMMIT_REQUESTED';journal();h.query(plan+'COMMIT;');record.status='COMMIT_CONFIRMED';journal();
 record.protected_after=JSON.parse(read(snapshotSql(true)+';'));assert.deepEqual(record.protected_after,before,'Protected records changed; preserve the installation report');record.status='VERIFIED';journal();
 console.log('PASS Same-plan rollback probe, trusted role reads and restricted reporting permissions');console.log('PASS Existing cases, customers, reports, preparations, approvals, exports and recorded responses preserved');console.log('Streamlined reporting installed. Report: '+path.relative(h.ROOT,file));console.log('Restart Edge Functions and hard-refresh CoreAML. No reports, approvals or external responses were created during installation.');
}
if(require.main===module)try{main();}catch(e){console.error('Streamlined reporting installation stopped: '+e.message);console.error('Preserve .coreaml-local/filing-streamlined-v3 and share the output. Do not reset the database.');process.exitCode=1;}
module.exports={main,snapshotSql,probeSql,sourceHashSql};
