'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{randomUUID}=require('node:crypto');
const {ROOT,BANK,query,assertLocal,lit}=require('./aml-compatible-db.cjs');
const {fingerprint,fingerprintSQL}=require('./verify-case-claim-acceptance-local.cjs');
const normalize=value=>value.replace(/\r\n/g,'\n').trim().replace(/;$/,'');
function probeSQL(id,actor,before){
 const state='('+fingerprintSQL([id]).replace(/;\s*$/,'')+')';
 const unchanged=label=>`DO $check$ BEGIN IF ${state} IS DISTINCT FROM ${lit(before)} THEN RAISE EXCEPTION '${label} changed existing or risk-history state'; END IF; END $check$;`;
 const claims=JSON.stringify({sub:actor,role:'authenticated',app_metadata:{role:'compliance_officer',tenant_id:BANK}});
 return `SAVEPOINT null_risk_probe;
 INSERT INTO public.alerts(id,alert_ref,rule_triggered,severity,status,tenant_id,created_at,evidence,details)
 VALUES (${lit(id)}::uuid,${lit('NULL-RISK-PROBE-'+id)},'Null customer risk probe','LOW','UNASSIGNED',${lit(BANK)},now(),'{}','Rollback-only null customer risk probe');
 ${unchanged('Null-customer insertion')}
 SET LOCAL ROLE authenticated;
 DO $claim$ BEGIN PERFORM set_config('request.jwt.claims',${lit(claims)},true);PERFORM public.coreaml_claim_case(${lit(id)}::uuid);END $claim$;
 SET LOCAL ROLE postgres;
 ${unchanged('Null-customer claim')}
 ROLLBACK TO SAVEPOINT null_risk_probe;RELEASE SAVEPOINT null_risk_probe;
 ${unchanged('Rollback')}`;
}
function main(){
 assertLocal();const id=randomUUID();
 const previous=fs.readFileSync(path.join(ROOT,'scripts/fixtures/unified-risk-before-null-guard.sql'),'utf8');
 const fixed=fs.readFileSync(path.join(ROOT,'sql/coreaml-null-customer-risk-guard-local.sql'),'utf8');
 const current=query("BEGIN TRANSACTION READ ONLY;SELECT pg_get_functiondef('public.unified_risk_scoring()'::regprocedure);COMMIT;");
 assert([normalize(previous),normalize(fixed)].includes(normalize(current)),'Current risk function differs from the reviewed definition; refusing to overwrite it');
 const actor=query(`BEGIN TRANSACTION READ ONLY;SELECT id FROM public.user_profiles WHERE tenant_id=${lit(BANK)} AND role='compliance_officer' AND is_active IS TRUE ORDER BY id LIMIT 1;COMMIT;`);
 assert(/^[0-9a-f-]{36}$/i.test(actor),'Active local officer unavailable');
 const before=fingerprint([id]);
 query('BEGIN;'+fixed+probeSQL(id,actor,before)+'COMMIT;');
 assert.equal(fingerprint([id]),before,'State changed outside installation transaction; inspect before acceptance');
 const report={generated_at:new Date().toISOString(),pass:4,fail:0,checks:['Only the reviewed risk function body replaced','Null-customer insert creates no risk-history or existing-state change','Null-customer claim creates no risk-history or unrelated-state change','Rollback removes probe; pre-existing state unchanged'],limitations:['Historical orphan risk rows are retained, not deleted.','Linked-customer scoring is covered by separate isolated PostgreSQL tests; native acceptance must still resume.']};
 const output=path.join(ROOT,'.coreaml-local/null-customer-risk-guard-install.json');fs.mkdirSync(path.dirname(output),{recursive:true});if(fs.existsSync(output))fs.copyFileSync(output,output.replace(/\.json$/,'-before-'+Date.now()+'.json'));fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.log('Null-customer risk guard installed; 4 local checks passed.');console.log('Report: .coreaml-local/null-customer-risk-guard-install.json');
}
if(require.main===module){try{main();}catch(error){console.error('Risk guard installation failed:',error.message);process.exitCode=1;}}
module.exports={probeSQL,normalize};
