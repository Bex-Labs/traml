'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),Module=require('node:module');
const ROOT=path.resolve(__dirname,'..'),BANK='a1000000-0000-4000-8000-000000000001';
const {PGlite}=require(process.env.COREAML_TEST_PGLITE_MODULE||path.join(ROOT,'.coreaml-test-tools/node_modules/@electric-sql/pglite'));
const U=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const lit=x=>"'"+String(x).replace(/'/g,"''")+"'";
const toolFile=path.join(ROOT,'scripts/customer-linked-native-tools.cjs'),moduleObject=new Module(toolFile,module);
moduleObject.filename=toolFile;moduleObject.paths=module.paths;moduleObject.require=name=>name==='./aml-compatible-db.cjs'?{ROOT,BANK,lit}:require(name);
moduleObject._compile(fs.readFileSync(toolFile,'utf8'),toolFile);const tools=moduleObject.exports;
let count=0;const pass=name=>{count++;console.log('PASS '+name);};
async function one(db,sql){return (await db.query(sql)).rows[0];}
async function json(db,sql){return JSON.parse(Object.values(await one(db,sql))[0]);}
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

let activeDB;
(async()=>{
 const db=activeDB=await setup(path.join(ROOT,'sql/coreaml-null-customer-risk-guard-local.sql'));
 await db.exec(fs.readFileSync(path.join(ROOT,'sql/coreaml-case-claim-local.sql'),'utf8'));
 await db.exec(`ALTER TABLE customers ADD COLUMN customer_type text,ADD COLUMN first_name text,ADD COLUMN last_name text,ADD COLUMN entity_name text,ADD COLUMN industry text,ADD COLUMN geography text,ADD COLUMN tenant_id text,ADD COLUMN kyc_status text DEFAULT 'PENDING',ADD COLUMN id_url text,ADD COLUMN utility_bill_url text;
 CREATE TABLE investigation_drafts(id uuid);CREATE TABLE suspicious_transaction_reports(id uuid);
 INSERT INTO auth.users VALUES('${U(2)}');INSERT INTO user_profiles VALUES('${U(2)}','${BANK}','compliance_officer',true);
 CREATE SCHEMA vault;CREATE TABLE vault.decrypted_secrets(name text,decrypted_secret text);
 CREATE SCHEMA net;CREATE TABLE net.calls(id integer);CREATE FUNCTION net.http_post(url text,headers jsonb,body jsonb) RETURNS bigint LANGUAGE plpgsql AS $$ BEGIN INSERT INTO net.calls VALUES(1);RETURN 1;END $$;
 CREATE FUNCTION coreaml_private.compatible_alert_guard() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW;END $$;
 CREATE TRIGGER compatible_alert_guard BEFORE INSERT OR UPDATE ON alerts FOR EACH ROW EXECUTE FUNCTION coreaml_private.compatible_alert_guard();`);
 const contract=JSON.parse(fs.readFileSync(path.join(ROOT,'scripts/fixtures/customer-linked-trigger-contract.json'),'utf8'));
 for(const t of contract.customer_triggers)await db.exec(t.function_definition.trim()+';'+t.trigger_definition+';');
 tools.validateContract(await json(db,tools.contractSQL()),contract);pass('Reviewed customer and risk function contract matches executable fixture');
 const changed=structuredClone(contract);changed.customer_triggers[0].function_definition+=' -- changed';assert.throws(()=>tools.validateContract(awaitDummy(),changed));
 function awaitDummy(){return {...contract,alert_trigger_names:['compatible_alert_guard','coreaml_guard_case_ownership','trigger_unified_risk_scoring']};}
 pass('Unreviewed trigger source is rejected');
 const f={customer_id:U(40),alert_ids:[U(41),U(42)],marker:'GroupClaimTest-'+U(99)};
 const original=await json(db,tools.snapshotSQL(f));
 await db.exec(tools.setupSQL(f)+tools.probeSQL(f,[U(1),U(2)])+'COMMIT;');pass('Exact native setup, group retry, peer denial and second-member failure probes execute');
 tools.assertSnapshot(original,await json(db,tools.snapshotSQL(f)));pass('Committed isolated fixture leaves pre-existing table fingerprints unchanged');
 const before=await json(db,tools.fixtureStateSQL(f));assert.equal(Number(before.customer.risk_score),40);assert.equal(before.history.length,2);assert(before.alerts.every(a=>a.status==='UNASSIGNED'));pass('Savepoints remove every probe claim and fault object before fixture commit');
 assert.equal(Number((await one(db,'SELECT count(*) AS n FROM net.calls')).n),0);pass('Unconfigured webhook produces no network queue invocation');
 await db.exec('BEGIN;'+tools.claimsSQL(U(1)));await db.query(`SELECT public.coreaml_claim_case('${f.alert_ids[0]}')`);await db.exec('COMMIT;');
 tools.assertClaim(await json(db,tools.fixtureStateSQL(f)),f,U(1),before);pass('Claim state confirms grouped ownership, evidence, risk and single audit');
 const wrong=await json(db,tools.fixtureStateSQL(f));wrong.history.push({...wrong.history[0],id:U(80)});assert.throws(()=>tools.assertClaim(wrong,f,U(1),before));pass('Extra history cannot be hidden by fixture exclusions');
 const f2={customer_id:U(50),alert_ids:[U(51),U(52)],marker:'GroupClaimTest-'+U(98)};
 await db.exec("INSERT INTO vault.decrypted_secrets VALUES('project_url','https://example.invalid'),('anon_key','test-public-key'),('match_entity_webhook_secret','test-webhook-secret')");
 await assert.rejects(()=>db.exec(tools.setupSQL(f2)+tools.probeSQL(f2,[U(1),U(2)])+'COMMIT;'),/webhook is configured/);await db.exec('ROLLBACK;');
 assert.equal(Number((await one(db,`SELECT count(*) AS n FROM customers WHERE id='${f2.customer_id}'`)).n),0);assert.equal(Number((await one(db,'SELECT count(*) AS n FROM net.calls')).n),0);pass('Configured webhook blocks all fixture insertion and network work');
 const drift={...original,profiles:'changed'};assert.throws(()=>tools.assertSnapshot(original,drift),/profiles/);pass('State failures identify the changed table');
 await db.close();console.log(count+' native-builder safety/integration checks passed in isolated PostgreSQL; real native race remains pending.');
})().catch(async error=>{console.error(error.message);if(activeDB)await activeDB.close();process.exitCode=1;});
