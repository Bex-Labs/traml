'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),Module=require('node:module');
const ROOT=path.resolve(__dirname,'..'),BANK='a1000000-0000-4000-8000-000000000001',API='http://127.0.0.1:55321';
const {PGlite}=require(process.env.COREAML_TEST_PGLITE_MODULE||path.join(ROOT,'.coreaml-test-tools/node_modules/@electric-sql/pglite'));
const U=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const lit=x=>"'"+String(x).replace(/'/g,"''")+"'";
function load(file,extras={}){const m=new Module(file,module);m.filename=file;m.paths=module.paths;m.require=name=>name==='./aml-compatible-db.cjs'?{ROOT,BANK,API,lit}:extras[name]||require(name);m._compile(fs.readFileSync(file,'utf8'),file);return m.exports;}
const native=load(path.join(ROOT,'scripts/customer-linked-native-tools.cjs'));
const tools=load(path.join(ROOT,'scripts/case-workflow-install-tools.cjs'),{'./customer-linked-native-tools.cjs':native});
let db,count=0;const pass=s=>{count++;console.log('PASS '+s);};
async function json(sql){return JSON.parse(Object.values((await db.query(sql)).rows[0])[0]);}
async function as(id,sql,role='compliance_officer',bank=BANK){await db.exec('BEGIN;'+tools.claims(id,role,bank));try{const r=await db.query(sql);await db.exec('COMMIT;');return r.rows[0]?.r;}catch(e){await db.exec('ROLLBACK;');throw e;}}
(async()=>{
 db=new PGlite();await db.exec(`CREATE ROLE authenticated;CREATE ROLE anon;CREATE SCHEMA auth;CREATE SCHEMA coreaml_private;
 CREATE TABLE auth.users(id uuid PRIMARY KEY);INSERT INTO auth.users VALUES('${U(1)}'),('${U(2)}'),('${U(3)}'),('${U(4)}');
 CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
 CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(auth.jwt()->>'sub','')::uuid $$;GRANT USAGE ON SCHEMA auth TO authenticated,anon;
 CREATE TABLE user_profiles(id uuid PRIMARY KEY,tenant_id text,role text,is_active boolean);
 INSERT INTO user_profiles VALUES('${U(1)}','${BANK}','compliance_officer',true),('${U(2)}','${BANK}','compliance_officer',true),('${U(3)}','${U(100)}','compliance_officer',true),('${U(4)}','${BANK}','head_of_compliance',true);
 CREATE TYPE public.risk_tier AS ENUM('LOW','MEDIUM','HIGH','VERY_HIGH');
 CREATE TABLE customers(id uuid PRIMARY KEY,tenant_id text,customer_type text,first_name text,last_name text,entity_name text,kyc_status text,risk_score numeric,risk_tier public.risk_tier,updated_at timestamptz);
 CREATE TABLE alerts(id uuid PRIMARY KEY,alert_ref text NOT NULL,rule_triggered text,severity text,status text,customer_id uuid REFERENCES customers(id),transaction_id uuid,tenant_id text,assigned_user_id uuid,created_at timestamptz DEFAULT now(),evidence jsonb DEFAULT '{}',details text);
 CREATE TABLE risk_score_history(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),customer_id uuid REFERENCES customers(id),previous_score integer,new_score integer,previous_tier text,new_tier text,change_reason text);
 CREATE TABLE system_events(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),event_type text,severity text,message text,tenant_id uuid,user_id uuid,metadata jsonb);
 CREATE TABLE accounts(id uuid PRIMARY KEY,customer_id uuid);CREATE TABLE transactions(id uuid PRIMARY KEY,account_id uuid,transaction_reference text);
 CREATE TABLE coreaml_compatible_runs(id uuid);CREATE TABLE coreaml_compatible_results(id uuid);CREATE TABLE transaction_evaluation_outbox(transaction_id uuid);CREATE TABLE report_archives(id uuid);CREATE TABLE suspicious_transaction_reports(id uuid);
 CREATE TABLE investigation_drafts(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id text NOT NULL,alert_id uuid REFERENCES alerts(id),investigator_id uuid REFERENCES auth.users(id),draft_narrative text,ai_explanation jsonb,evidence_snapshot jsonb,status text CONSTRAINT investigation_drafts_status_check CHECK(status IN('IN_PROGRESS','SUBMITTED','DISCARDED')),created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),UNIQUE(alert_id,investigator_id));
 ALTER TABLE investigation_drafts ENABLE ROW LEVEL SECURITY;
 CREATE POLICY owner_draft ON investigation_drafts FOR ALL TO authenticated USING(investigator_id=auth.uid()) WITH CHECK(investigator_id=auth.uid());
 CREATE POLICY head_draft ON investigation_drafts FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM user_profiles WHERE id=auth.uid() AND role='head_of_compliance' AND user_profiles.tenant_id=investigation_drafts.tenant_id));
 GRANT SELECT,INSERT,UPDATE,DELETE ON investigation_drafts TO authenticated;GRANT SELECT,UPDATE ON alerts TO authenticated;GRANT SELECT ON user_profiles TO authenticated;`);
 await db.exec(fs.readFileSync(path.join(ROOT,'sql/coreaml-null-customer-risk-guard-local.sql'),'utf8'));
 await db.exec('CREATE TRIGGER trigger_unified_risk_scoring AFTER INSERT OR UPDATE OF severity,status ON alerts FOR EACH ROW EXECUTE FUNCTION unified_risk_scoring();');
 await db.exec(fs.readFileSync(path.join(ROOT,'sql/coreaml-case-claim-local.sql'),'utf8'));
 const f={customer_id:U(10),alert_ids:[U(20),U(21)],marker:'GroupClaimTest-'+U(99),owner_id:U(1)};
 await db.exec(`INSERT INTO customers(id,tenant_id,entity_name,risk_score,risk_tier) VALUES('${U(10)}','${BANK}','Synthetic <entity>',10,'LOW'),('${U(11)}','${U(100)}','Other bank',10,'LOW');
 INSERT INTO accounts VALUES('${U(50)}','${U(10)}'),('${U(51)}','${U(11)}');INSERT INTO transactions VALUES('${U(60)}','${U(50)}','OWN-TX'),('${U(61)}','${U(51)}','OTHER-TX');
 INSERT INTO alerts(id,alert_ref,rule_triggered,severity,status,customer_id,tenant_id,evidence,details) VALUES('${U(20)}','A','fixture','HIGH','UNASSIGNED','${U(10)}','${BANK}','{"source":"immutable"}','Original detection reason');
 INSERT INTO alerts(id,alert_ref,rule_triggered,severity,status,customer_id,tenant_id,evidence,details) VALUES('${U(21)}','B','fixture','MEDIUM','UNASSIGNED','${U(10)}','${BANK}','{"source":"immutable"}','Original detection reason');`);
 const claim=await as(U(1),`SELECT coreaml_claim_case('${U(20)}') AS r`);f.case_reference=claim.case_reference;
 const beforeOriginal=await json(native.snapshotSQL(f)),beforeFixture=await json(native.fixtureStateSQL(f));
 const workflowSQL=fs.readFileSync(path.join(ROOT,'sql/coreaml-case-workflow-local.sql'),'utf8');
 await db.exec(tools.installationSQL(f,U(2),beforeOriginal,beforeFixture,workflowSQL));
 const before=await json(tools.stateSQL(f));assert.deepEqual(before.original,beforeOriginal);assert.deepEqual(before.fixture,beforeFixture);assert.deepEqual(before.actions,[]);pass('Exact installation transaction and rollback probes preserve every original and fixture row');
 await db.exec(tools.installationSQL(f,U(2),beforeOriginal,beforeFixture,workflowSQL,true));assert.deepEqual(await json(tools.stateSQL(f)),before);pass('Repeat verification reuses installed schema without persistent draft or action rows');

 const acceptance=load(path.join(ROOT,'scripts/case-workflow-acceptance-tools.cjs'),{'./verify-coreaml-kyc-browser-local.cjs':{networkAllowed:()=>true}});
 const baseline=await json(acceptance.fullStateSQL(f,tools.stateSQL));
 const boundary=acceptance.createBoundary(f,f.alert_ids[0]),url=new URL(API+'/rest/v1/rpc/coreaml_case_action');
 const readState=()=>json(acceptance.fullStateSQL(f,tools.stateSQL));
 function request(phase,id){return {p_alert_id:f.alert_ids[0],p_action:phase==='close'?'CLOSE':'SAVE',p_expected_revision:{initial:0,stale:0,final:1,close:2}[phase],p_request_id:U(id),...(phase==='close'?{}:{p_narrative:acceptance.TEXT[phase],p_snapshot:{entity_ids:[f.customer_id],transaction_refs:[]}})};}
 async function send(body){assert.equal(boundary.decide(url,'POST',body),null);return as(U(1),`SELECT public.coreaml_case_action(${lit(body.p_alert_id)}::uuid,${lit(body.p_action)},${body.p_expected_revision},${lit(body.p_request_id)}::uuid${body.p_action==='SAVE'?','+lit(body.p_narrative)+','+lit(JSON.stringify(body.p_snapshot))+'::jsonb':''}) AS r`);}
 boundary.arm('initial');const initial=request('initial',1000);const first=await send(initial);assert.equal(first.replayed,false);acceptance.assertState(baseline,await readState(),f,1,boundary.attempts);const saved=await readState();assert.equal((await send(initial)).replayed,true);assert.deepEqual(await readState(),saved);pass('Exact acceptance save/replay matches real PostgreSQL draft, receipt, audit and evidence checks');
 boundary.arm('stale');await assert.rejects(()=>send(request('stale',1001)),/revision conflict/);assert.deepEqual(await readState(),saved);pass('Actual stale revision rejection leaves the complete database snapshot unchanged');
 boundary.arm('final');assert.equal((await send(request('final',1002))).revision,2);acceptance.assertState(baseline,await readState(),f,2,boundary.attempts);pass('Final narrative reconciliation matches actual SQL revision and canonical pins');
 boundary.arm('close');const closing=request('close',1003);assert.equal((await send(closing)).status,'CLOSED');const closed=await readState();acceptance.assertState(baseline,closed,f,3,boundary.attempts);assert.equal((await send(closing)).replayed,true);assert.deepEqual(await readState(),closed);pass('Closure/retry match exact real PostgreSQL receipts while preserving risk and unrelated records');
 const loaded=await as(U(1),`SELECT coreaml_load_case_draft('${f.alert_ids[1]}') AS r`);assert.equal(loaded.read_only,true);assert.equal(loaded.status,'CLOSED');assert.equal(loaded.draft_narrative,acceptance.TEXT.final);pass('Closed group member loads the final canonical read-only draft');
 await db.close();db=null;console.log(count+' PostgreSQL acceptance-builder checks passed in isolation; native browser execution remains separate.');
})().catch(async e=>{console.error(e.stack);if(db)await db.close();process.exitCode=1;});
