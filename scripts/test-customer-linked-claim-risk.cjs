'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const ROOT=path.resolve(__dirname,'..'),BANK='a1000000-0000-4000-8000-000000000001';
const {PGlite}=require(process.env.COREAML_TEST_PGLITE_MODULE||path.join(ROOT,'.coreaml-test-tools/node_modules/@electric-sql/pglite'));
const U=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
let count=0;const pass=name=>{count++;console.log('PASS '+name);};
async function setup(file){const db=new PGlite();await db.exec(`CREATE ROLE authenticated;CREATE ROLE anon;CREATE SCHEMA auth;CREATE SCHEMA coreaml_private;
CREATE TABLE auth.users(id uuid PRIMARY KEY);INSERT INTO auth.users VALUES('${U(1)}');
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(auth.jwt()->>'sub','')::uuid $$;GRANT USAGE ON SCHEMA auth TO authenticated,anon;
CREATE TYPE public.risk_tier AS ENUM ('LOW','MEDIUM','HIGH','VERY_HIGH');
CREATE TABLE customers(id uuid PRIMARY KEY,risk_score numeric,risk_tier public.risk_tier,updated_at timestamptz);
CREATE TABLE alerts(id uuid PRIMARY KEY,alert_ref text NOT NULL,rule_triggered text,severity text,status text,customer_id uuid REFERENCES customers(id),transaction_id uuid,tenant_id text,assigned_user_id uuid,created_at timestamptz DEFAULT now(),evidence jsonb DEFAULT '{}',details text);
CREATE TABLE risk_score_history(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),customer_id uuid REFERENCES customers(id),previous_score integer,new_score integer,previous_tier text,new_tier text,change_reason text);
CREATE TABLE user_profiles(id uuid PRIMARY KEY,tenant_id text,role text,is_active boolean);
INSERT INTO user_profiles VALUES('${U(1)}','${BANK}','compliance_officer',true);
CREATE TABLE system_events(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),event_type text,severity text,message text,tenant_id uuid,user_id uuid,metadata jsonb);
GRANT SELECT,UPDATE ON alerts TO authenticated;GRANT SELECT ON user_profiles TO authenticated;
CREATE TABLE accounts(id uuid);CREATE TABLE transactions(id uuid);CREATE TABLE coreaml_compatible_runs(id uuid);CREATE TABLE coreaml_compatible_results(id uuid);CREATE TABLE transaction_evaluation_outbox(transaction_id uuid);CREATE TABLE report_archives(id uuid);
INSERT INTO customers(id,risk_score,risk_tier) VALUES('${U(10)}',10,'LOW'),('${U(11)}',10,'LOW');`);
await db.exec(fs.readFileSync(file,'utf8'));await db.exec('CREATE TRIGGER trigger_unified_risk_scoring AFTER INSERT OR UPDATE OF severity,status ON alerts FOR EACH ROW EXECUTE FUNCTION unified_risk_scoring();');return db;}

async function one(db,sql){return (await db.query(sql)).rows[0];}
async function actor(db,id,sql){
 await db.exec('BEGIN;SET LOCAL ROLE authenticated;');
 await db.query("SELECT set_config('request.jwt.claims',$1,true)",[JSON.stringify({sub:U(id),role:'authenticated',app_metadata:{role:'compliance_officer',tenant_id:BANK}})]);
 try{const result=(await db.query(sql)).rows;await db.exec('COMMIT;');return result;}catch(error){await db.exec('ROLLBACK;');throw error;}
}
async function state(db){return (await one(db,"SELECT jsonb_build_object('customers',(SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM customers c),'history',(SELECT jsonb_agg(to_jsonb(h) ORDER BY id) FROM risk_score_history h)) AS value")).value;}
(async()=>{
 const db=await setup(path.join(ROOT,'sql/coreaml-null-customer-risk-guard-local.sql'));
 await db.exec(fs.readFileSync(path.join(ROOT,'sql/coreaml-case-claim-local.sql'),'utf8'));
 await db.exec(`INSERT INTO auth.users VALUES('${U(2)}');INSERT INTO user_profiles VALUES('${U(2)}','${BANK}','compliance_officer',true);
 INSERT INTO alerts(id,alert_ref,customer_id,severity,status,tenant_id,evidence,details) VALUES
 ('${U(20)}','GROUP-HIGH','${U(10)}','HIGH','UNASSIGNED','${BANK}','{"test":"high"}','High reason'),
 ('${U(21)}','GROUP-MEDIUM','${U(10)}','MEDIUM','UNASSIGNED','${BANK}','{"test":"medium"}','Medium reason'),
 ('${U(22)}','OTHER-CUSTOMER','${U(11)}','LOW','UNASSIGNED','${BANK}','{}','Other reason');`);
 const before=await state(db),canonical=(await db.query('SELECT id,customer_id,transaction_id,tenant_id,rule_triggered,severity,evidence,details FROM alerts ORDER BY id')).rows;
 const risk=await one(db,`SELECT risk_score,risk_tier FROM customers WHERE id='${U(10)}'`);assert.equal(Number(risk.risk_score),40);assert.equal(risk.risk_tier,'MEDIUM');pass('Real risk trigger establishes expected 40/MEDIUM fixture score');
 const result=(await actor(db,1,`SELECT public.coreaml_claim_case('${U(20)}') AS receipt`))[0].receipt;
 assert.deepEqual(result.alert_ids,[U(20),U(21)]);pass('One customer-linked claim takes both eligible alerts together');
 const rows=(await db.query(`SELECT status,assigned_user_id,case_reference FROM alerts WHERE customer_id='${U(10)}'`)).rows;
 assert(rows.every(r=>r.status==='INVESTIGATING'&&r.assigned_user_id===U(1)&&r.case_reference===result.case_reference));pass('All group members share one officer and one case reference');
 assert.deepEqual(await state(db),before);pass('Claim preserves full customer risk state, timestamps and risk history');
 assert.deepEqual((await db.query('SELECT id,customer_id,transaction_id,tenant_id,rule_triggered,severity,evidence,details FROM alerts ORDER BY id')).rows,canonical);pass('Canonical alert evidence and reasons are unchanged');
 assert.equal((await one(db,`SELECT status FROM alerts WHERE id='${U(22)}'`)).status,'UNASSIGNED');pass('Different customer is not swept into the group');
 const replay=(await actor(db,1,`SELECT public.coreaml_claim_case('${U(21)}') AS receipt`))[0].receipt;
 assert(replay.replayed&&replay.case_reference===result.case_reference);assert.equal((await one(db,'SELECT count(*)::integer AS n FROM coreaml_case_claims')).n,1);assert.equal((await one(db,'SELECT count(*)::integer AS n FROM system_events')).n,1);pass('Retry from another group member returns the same receipt and audit');
 await assert.rejects(()=>actor(db,2,`SELECT public.coreaml_claim_case('${U(21)}')`),/already claimed/);assert.deepEqual(await state(db),before);pass('Second officer cannot steal the group through another anchor');
 await db.exec(`INSERT INTO customers(id,risk_score,risk_tier) VALUES('${U(12)}',10,'LOW');
 INSERT INTO alerts(id,alert_ref,customer_id,severity,status,tenant_id,evidence,details) VALUES
 ('${U(30)}','FAIL-HIGH','${U(12)}','HIGH','UNASSIGNED','${BANK}','{}','Failure fixture high'),
 ('${U(31)}','FAIL-MEDIUM','${U(12)}','MEDIUM','UNASSIGNED','${BANK}','{}','Failure fixture medium');
 CREATE FUNCTION fail_second_group_member() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id='${U(31)}' AND NEW.status='INVESTIGATING' THEN RAISE EXCEPTION 'Injected second-member failure';END IF;RETURN NEW;END $$;
 CREATE TRIGGER fail_second_group_member BEFORE UPDATE ON alerts FOR EACH ROW EXECUTE FUNCTION fail_second_group_member();`);
 const failureBefore=await state(db);
 await assert.rejects(()=>actor(db,1,`SELECT public.coreaml_claim_case('${U(30)}')`),/Injected second-member failure/);
 assert((await db.query(`SELECT status,assigned_user_id,case_reference FROM alerts WHERE customer_id='${U(12)}'`)).rows.every(r=>r.status==='UNASSIGNED'&&r.assigned_user_id===null&&r.case_reference===null));pass('Failure on the second member rolls back the whole group');
 assert.deepEqual(await state(db),failureBefore);assert.equal((await one(db,'SELECT count(*)::integer AS n FROM coreaml_case_claims')).n,1);assert.equal((await one(db,'SELECT count(*)::integer AS n FROM system_events')).n,1);pass('Failed group leaves risk history, receipts and audits unchanged');
 await db.close();console.log(count+' isolated customer-linked group/risk checks passed; native customer trigger review remains required.');
})().catch(error=>{console.error(error);process.exitCode=1;});
