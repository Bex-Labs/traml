'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {ROOT,BANK,query,assertLocal,lit}=require('./aml-compatible-db.cjs');
const {contractSQL,validateContract,validateFixture,snapshotSQL,fixtureStateSQL}=require('./customer-linked-native-tools.cjs');
const {body,normalize,installationSQL}=require('./case-workflow-install-tools.cjs');
const RUN='b4b94f13-5991-4436-8692-b19c8665b92c';
function main(){
 assertLocal();
 const input=path.join(ROOT,'.coreaml-local/customer-linked-claim',RUN,'results.json');
 const receipt=JSON.parse(fs.readFileSync(input,'utf8')),f=receipt.fixture;validateFixture(f);
 assert.equal(receipt.run_id,RUN);assert.equal(receipt.checks.length,6);assert(receipt.checks.every(c=>c.result==='PASS'),'Prior linked acceptance is incomplete');
 assert.equal(f.marker,'GroupClaimTest-'+RUN);assert.equal(f.owner_id,'aacb70b4-8b48-40f6-9c59-f2a38e0445d6');assert.equal(f.case_reference,'CASE-d3fd62ee-b6a8-4533-9fa7-c6fc65fa8120');
 const contract=JSON.parse(fs.readFileSync(path.join(ROOT,'scripts/fixtures/customer-linked-trigger-contract.json'),'utf8'));
 validateContract(JSON.parse(query('BEGIN READ ONLY;'+contractSQL()+'COMMIT;')),contract);
 const beforeOriginal=JSON.parse(query('BEGIN READ ONLY;'+snapshotSQL(f)+'COMMIT;'));
 const beforeFixture=JSON.parse(query('BEGIN READ ONLY;'+fixtureStateSQL(f)+'COMMIT;'));
 assert.equal(beforeFixture.customer.id,f.customer_id);assert.equal(beforeFixture.customer.tenant_id,BANK);assert.equal(Number(beforeFixture.customer.risk_score),40);assert.equal(beforeFixture.customer.risk_tier,'MEDIUM');assert.equal(beforeFixture.history.length,2);
 assert.equal(beforeFixture.claims.length,1);assert.equal(beforeFixture.claims[0].case_reference,f.case_reference);assert.equal(beforeFixture.claims[0].investigator_id,f.owner_id);
 assert.deepEqual([...beforeFixture.claims[0].alert_ids].sort(),[...f.alert_ids].sort());assert.equal(beforeFixture.alerts.length,2);
 assert(beforeFixture.alerts.every(a=>a.status==='INVESTIGATING'&&a.assigned_user_id===f.owner_id&&a.case_reference===f.case_reference&&a.customer_id===f.customer_id&&a.tenant_id===BANK),'Retained case is no longer the expected open fixture');
 const peer=query(`BEGIN READ ONLY;SELECT id FROM public.user_profiles WHERE id='72855f6c-85db-4c78-b6c3-b42134a9cb99' AND tenant_id=${lit(BANK)} AND role='compliance_officer' AND is_active IS TRUE;COMMIT;`);assert.equal(peer,'72855f6c-85db-4c78-b6c3-b42134a9cb99','Verified synthetic peer unavailable');
 const sql=fs.readFileSync(path.join(ROOT,'sql/coreaml-case-workflow-local.sql'),'utf8');
 const installed=query("BEGIN READ ONLY;SELECT to_regclass('public.coreaml_case_actions') IS NOT NULL;COMMIT;")==='t';
 const source=installed?sql:fs.readFileSync(path.join(ROOT,'sql/coreaml-case-claim-local.sql'),'utf8');
 const claimSource=fs.readFileSync(path.join(ROOT,'sql/coreaml-case-claim-local.sql'),'utf8');
 const claimBody=query("BEGIN READ ONLY;SELECT prosrc FROM pg_proc WHERE oid='public.coreaml_claim_case(uuid)'::regprocedure;COMMIT;");
 assert.equal(normalize(claimBody),body(claimSource,'public.coreaml_claim_case'),'Claim function differs from reviewed source');
 const guard=query("BEGIN READ ONLY;SELECT prosrc FROM pg_proc WHERE oid='coreaml_private.guard_case_ownership()'::regprocedure;COMMIT;");
 assert.equal(normalize(guard),body(source,'coreaml_private.guard_case_ownership'),'Ownership guard differs from reviewed source; refusing overwrite');
 assert.equal(query('BEGIN READ ONLY;SELECT count(*) FROM public.investigation_drafts;COMMIT;'),'0','Existing drafts require a separate reviewed migration; no installation attempted');
 if(installed){
  for(const match of sql.matchAll(/CREATE (?:OR REPLACE )?FUNCTION ([\w.]+)\(([^)]*)\)[\s\S]*?AS \$\$([\s\S]*?)\$\$;/g)){
   const rows=JSON.parse(query(`BEGIN READ ONLY;SELECT coalesce(jsonb_agg(jsonb_build_object('body',p.prosrc,'config',p.proconfig,'definer',p.prosecdef)),'[]')::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=${lit(match[1].split('.')[0])} AND p.proname=${lit(match[1].split('.')[1])};COMMIT;`));
   assert.equal(rows.length,1,'Unexpected function overload');assert.equal(normalize(rows[0].body),normalize(match[3]),'Installed workflow body differs');assert(rows[0].config?.includes('search_path=""'),'Function search path differs');assert.equal(rows[0].definer,!match[1].includes('.guard_'));
  }
 }
 const result=query(installationSQL(f,peer,beforeOriginal,beforeFixture,sql,installed));
 // psql may print SET claims results; never echo database output or credentials.
 void result;
 const afterOriginal=JSON.parse(query('BEGIN READ ONLY;'+snapshotSQL(f)+'COMMIT;'));const afterFixture=JSON.parse(query('BEGIN READ ONLY;'+fixtureStateSQL(f)+'COMMIT;'));
 assert.deepEqual(afterOriginal,beforeOriginal);assert.deepEqual(afterFixture,beforeFixture);
 const checks=['Reviewed local stack, retained linked fixture and risk contract match','Owner load, group-member save retry and exact receipt replay pass','Stale revision and reused request with changed content are rejected','Unavailable entity and transaction pins are rejected','Peer access and mismatched trusted bank are rejected','Direct draft, receipt and claimed-alert writes cannot succeed','Audit failures roll back both save and group closure','Closure covers only receipt members and replays without duplicate audit','Customer, risk, canonical evidence and original records remain unchanged','Probe drafts, actions and temporary fault objects roll back completely','Anonymous execution and direct action writes are not granted'];
 const report={generated_at:new Date().toISOString(),scope:'Local database foundation only; all save and close probes rolled back',already_installed:installed,fixture:f,checks:checks.map(check=>({check,result:'PASS'})),summary:{pass:checks.length,fail:0},states:{before:beforeOriginal,after:afterOriginal},limitations:['Dashboard save/resume/close integration and signed-in browser acceptance are pending.','No persistent draft or closure was created. Existing fixtures remain open.','CLOSED still contributes to risk under the existing reviewed scoring policy.']};
 const output=path.join(ROOT,'.coreaml-local/case-workflow-install.json');fs.mkdirSync(path.dirname(output),{recursive:true});if(fs.existsSync(output))fs.copyFileSync(output,output.replace(/\.json$/,'-before-'+Date.now()+'.json'));fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');
 console.log(`Local draft/closure foundation ${installed?'rechecked':'installed'}; ${checks.length} rollback checks passed.`);console.log('Report: .coreaml-local/case-workflow-install.json');console.log('No persistent drafts, closures, cash, evaluations or filings created.');
}
if(require.main===module){try{main();}catch(error){console.error('Workflow installation stopped:',error.message);process.exitCode=1;}}
module.exports={main};
