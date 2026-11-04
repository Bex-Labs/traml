'use strict';
const fs=require('node:fs'),path=require('node:path'),{randomUUID}=require('node:crypto');
const {ROOT,BANK,query,assertLocal,lit}=require('./aml-compatible-db.cjs');
function fingerprint(){return query(`BEGIN TRANSACTION READ ONLY;SELECT md5(jsonb_build_object('alerts',(SELECT jsonb_agg(to_jsonb(a)-'case_reference' ORDER BY id) FROM public.alerts a),'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM public.system_events e),'customers',(SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM public.customers c),'accounts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.accounts a),'transactions',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.transactions t))::text);COMMIT;`);}
function officer(){const id=query(`BEGIN TRANSACTION READ ONLY;SELECT id FROM public.user_profiles WHERE tenant_id=${lit(BANK)} AND role='compliance_officer' AND is_active IS TRUE ORDER BY id LIMIT 1;COMMIT;`);if(!/^[0-9a-f-]{36}$/i.test(id))throw Error('No active local compliance officer');return id;}
function probe(actor){
 const id=randomUUID(),other=randomUUID(),claims=JSON.stringify({sub:actor,role:'authenticated',app_metadata:{role:'compliance_officer',tenant_id:BANK}});
 return `SAVEPOINT claim_probe;
 -- These synthetic alerts have no customer, so the probe cannot sweep existing alerts.
 INSERT INTO public.alerts(id,alert_ref,rule_triggered,severity,status,tenant_id,created_at,evidence,details)
 VALUES (${lit(id)}::uuid,${lit('CLAIM-PROBE-'+id)},'Local claim probe','LOW','UNASSIGNED',${lit(BANK)},now(),'{}','Synthetic rollback-only claim probe'),
 (${lit(other)}::uuid,${lit('CLAIM-PROBE-'+other)},'Local claim probe','LOW','UNASSIGNED',${lit(BANK)},now(),'{}','Synthetic second alert');
 SET LOCAL ROLE authenticated;
 DO $probe$ DECLARE receipt jsonb; retry jsonb; BEGIN
 PERFORM set_config('request.jwt.claims',${lit(claims)},true);
 receipt:=public.coreaml_claim_case(${lit(id)}::uuid);
 IF receipt->'alert_ids' <> jsonb_build_array(${lit(id)}) THEN RAISE EXCEPTION 'Probe swept unrelated alerts'; END IF;
 retry:=public.coreaml_claim_case(${lit(id)}::uuid);
 IF retry->>'case_reference' IS DISTINCT FROM receipt->>'case_reference' OR retry->>'replayed'<>'true' THEN RAISE EXCEPTION 'Retry did not replay original claim'; END IF;
 IF (SELECT count(*) FROM public.coreaml_case_claims WHERE anchor_alert_id=${lit(id)}::uuid)<>1 THEN RAISE EXCEPTION 'Duplicate claim receipt'; END IF;
 IF (SELECT evidence FROM public.alerts WHERE id=${lit(id)}::uuid) IS DISTINCT FROM '{}'::jsonb OR (SELECT details FROM public.alerts WHERE id=${lit(id)}::uuid) IS DISTINCT FROM 'Synthetic rollback-only claim probe' THEN RAISE EXCEPTION 'Detection evidence changed'; END IF;
 IF (SELECT status FROM public.alerts WHERE id=${lit(other)}::uuid) IS DISTINCT FROM 'UNASSIGNED' THEN RAISE EXCEPTION 'Unrelated alert changed'; END IF;
 BEGIN
 UPDATE public.alerts SET assigned_user_id=null WHERE id=${lit(id)}::uuid;
 RAISE EXCEPTION 'Direct ownership change unexpectedly succeeded';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
 UPDATE public.coreaml_case_claims SET case_reference='FORGED' WHERE anchor_alert_id=${lit(id)}::uuid;
 RAISE EXCEPTION 'Receipt mutation unexpectedly succeeded';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 END $probe$;
 SET LOCAL ROLE postgres;
 DO $probe$ BEGIN
 IF (SELECT count(*) FROM public.system_events WHERE metadata->>'anchor_alert_id'=${lit(id)})<>1 THEN RAISE EXCEPTION 'Audit event missing or duplicated'; END IF;
 END $probe$;
 ROLLBACK TO SAVEPOINT claim_probe;
 RELEASE SAVEPOINT claim_probe;`;
}
function run(install=false){
 assertLocal();
 const before=fingerprint(),actor=officer();
 const sql=install?fs.readFileSync(path.join(ROOT,'sql/coreaml-case-claim-local.sql'),'utf8'):'';
 const afterExpression=`(SELECT md5(jsonb_build_object('alerts',(SELECT jsonb_agg(to_jsonb(a)-'case_reference' ORDER BY id) FROM public.alerts a),'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM public.system_events e),'customers',(SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM public.customers c),'accounts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.accounts a),'transactions',(SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.transactions t))::text))`;
 query('BEGIN;'+sql+probe(actor)+`DO $unchanged$ BEGIN IF ${afterExpression} IS DISTINCT FROM ${lit(before)} THEN RAISE EXCEPTION 'Existing state changed; rolling back'; END IF; END $unchanged$;`+(install?'COMMIT;':'ROLLBACK;'));
 if(fingerprint()!==before)throw Error('State changed after transaction; stop and inspect before rerunning');
 const report={generated_at:new Date().toISOString(),scope:install?'Local atomic claim installation and rollback probe':'Local rollback-only atomic claim probe',pass:8,fail:0,checks:['One null-customer anchor claimed without sweeping unrelated alerts','Retry returns original claim reference','Exactly one claim receipt','Canonical evidence and reason unchanged','Unrelated alert unchanged','Direct browser ownership write denied','Browser receipt mutation denied','One audit event; probe and existing financial state unchanged'],limitations:['Simulates an authenticated database role; does not verify browser claiming.','Multi-session concurrency and the complete drafting/closure workflow remain unverified.','No persistent alerts, claims, audit events, deposits or filings created by the probe.']};
 const output=path.join(ROOT,'.coreaml-local',install?'case-claim-install.json':'case-claim-verification.json');fs.mkdirSync(path.dirname(output),{recursive:true});if(fs.existsSync(output))fs.copyFileSync(output,output.replace(/\.json$/,'-before-'+Date.now()+'.json'));fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.log(install?'Local claim schema installed; rollback probe passed.':'Local rollback-only claim probe passed.');console.log('8 checks passed. Report: '+path.relative(ROOT,output));
}
module.exports={run,probe};
