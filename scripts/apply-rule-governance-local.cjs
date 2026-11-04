'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const h=require('./aml-compatible-db.cjs'),read=q=>h.query('BEGIN READ ONLY;'+q+'COMMIT;');
const hash=s=>crypto.createHash('sha256').update(s.replace(/\r\n/g,'\n')).digest('hex');
function snapshot(){return `SELECT jsonb_build_object(${['alerts','aml_rules','customers','accounts','transactions','investigation_drafts','suspicious_transaction_reports','coreaml_review_submissions','coreaml_review_actions','coreaml_case_actions'].map(t=>`${h.lit(t)},(SELECT md5(coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text)::text,'null')) FROM public.${t} x)`).join(',')})`;}
function functions(sql){const out=[];const re=/CREATE(?: OR REPLACE)? FUNCTION ([\w.]+)\(([^)]*)\)[\s\S]*?\bAS\s+(\$\w*\$)([\s\S]*?)\3\s*;/g;for(const m of sql.matchAll(re)){const types=m[2].trim()?m[2].split(',').map(x=>x.trim().split(/\s+/)[1]):[];out.push({signature:m[1]+'('+types.join(',')+')',md5:crypto.createHash('md5').update(m[4].replace(/\r\n/g,'\n')).digest('hex')});}assert(out.length>=8,'Expected complete governance function manifest');return out;}
function verifyInstalled(sql){for(const f of functions(sql))assert.equal(read(`SELECT md5(replace(prosrc,chr(13)||chr(10),chr(10))) FROM pg_proc WHERE oid=${h.lit(f.signature)}::regprocedure;`),f.md5,'Installed function differs: '+f.signature);}
function planSql(sql,stamp){
 return `BEGIN;SET LOCAL lock_timeout='5s';LOCK TABLE public.transactions IN SHARE ROW EXCLUSIVE MODE;CREATE TEMP TABLE governance_before ON COMMIT DROP AS ${snapshot()};`+sql+`COMMENT ON TABLE public.coreaml_rule_catalogue IS ${h.lit(stamp)};
 DO $$ BEGIN
 IF (SELECT jsonb_build_object FROM governance_before) IS DISTINCT FROM (${snapshot()}) THEN RAISE EXCEPTION 'Protected data changed';END IF;
 IF has_table_privilege('authenticated','public.coreaml_rule_deployments','INSERT') OR has_table_privilege('authenticated','public.aml_rules','INSERT') OR has_function_privilege('anon','public.coreaml_rule_change(text,jsonb,uuid)','EXECUTE') OR has_function_privilege('authenticated','public.coreaml_load_review_before_governance(text,uuid)','EXECUTE') OR has_function_privilege('authenticated','public.coreaml_case_action_before_governance(uuid,text,integer,uuid,text,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'Unexpected governance privileges';END IF;
 END $$;`;

}
function main(){h.assertLocal();assert.equal(h.DB,'supabase_db_sentinel-aml');const sql=fs.readFileSync(path.join(h.ROOT,'sql/coreaml-rule-governance-local.sql'),'utf8').replace(/\r\n/g,'\n'),stamp='coreaml_governance_v1:'+hash(sql);const exists=read("SELECT to_regclass('public.coreaml_rule_catalogue') IS NOT NULL;")==='t';
 if(exists){assert.equal(read("SELECT obj_description('public.coreaml_rule_catalogue'::regclass);"),stamp,'Different governance installation exists; it will not be overwritten');verifyInstalled(sql);console.log('Matching rule governance release is already installed.');return;}
 const expected=JSON.parse(fs.readFileSync(path.join(__dirname,'rule-governance-expected.json'),'utf8'));
 for(const [name,md5] of Object.entries(expected)){const got=read(`SELECT md5(replace(prosrc,chr(13)||chr(10),chr(10))) FROM pg_proc WHERE oid=${h.lit('public.'+name+(name==='coreaml_load_review'?'(text,uuid)':'(uuid,text,integer,uuid)'))}::regprocedure;`);assert.equal(got,md5,'Current review function differs: '+name);}
 const dir=path.join(h.ROOT,'.coreaml-local/rule-governance');fs.mkdirSync(dir,{recursive:true});const journal=path.join(dir,'install-'+Date.now()+'.json'),record={at:new Date().toISOString(),stamp,status:'CHECKED'};const save=()=>fs.writeFileSync(journal,JSON.stringify(record,null,2)+'\n');save();
 const plan=planSql(sql,stamp);
 h.query(plan+'ROLLBACK;');record.status='ROLLBACK_PROBE_PASSED';save();record.status='COMMIT_REQUESTED';save();h.query(plan+'COMMIT;');record.status='COMMIT_CONFIRMED';save();assert.equal(read("SELECT obj_description('public.coreaml_rule_catalogue'::regclass);"),stamp);verifyInstalled(sql);record.status='VERIFIED';save();console.log('PASS Same-plan rollback probe, protected-record preservation and restricted write permissions');console.log('Installed. No deployment was activated and existing rules and alerts remain unchanged.');console.log('Report: '+path.relative(h.ROOT,journal));}
if(require.main===module)try{main();}catch(e){console.error('Rule governance installation stopped: '+e.message);console.error('Preserve .coreaml-local/rule-governance and share the output. Do not reset the database.');process.exitCode=1;}
module.exports={snapshot,planSql,functions,main};
