'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),vm=require('node:vm');
const ROOT=path.resolve(__dirname,'..'),BANK='a1000000-0000-4000-8000-000000000001';
const {PGlite}=require(process.env.COREAML_TEST_PGLITE_MODULE||path.join(ROOT,'.coreaml-test-tools/node_modules/@electric-sql/pglite'));
const U=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const lit=x=>"'"+String(x).replace(/'/g,"''")+"'";
let passes=0;const pass=name=>{passes++;console.log('PASS '+name);};
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
async function linked(db){
 const snapshots=[];
 for(const sql of [
 `INSERT INTO alerts(id,alert_ref,customer_id,severity,status) VALUES('${U(20)}','LOW-1','${U(10)}','LOW','UNASSIGNED')`,
 `INSERT INTO alerts(id,alert_ref,customer_id,severity,status) VALUES('${U(21)}','HIGH-1','${U(10)}','HIGH','UNASSIGNED')`,
 `INSERT INTO alerts(id,alert_ref,customer_id,severity,status) VALUES('${U(22)}','CRITICAL-1','${U(10)}','CRITICAL','UNASSIGNED')`,
 `INSERT INTO alerts(id,alert_ref,customer_id,severity,status) VALUES('${U(23)}','MEDIUM-1','${U(10)}','MEDIUM','UNASSIGNED')`,
 `UPDATE alerts SET status='DISMISSED' WHERE id='${U(22)}'`,
 `UPDATE alerts SET severity='MEDIUM' WHERE id='${U(21)}'`,
 `INSERT INTO alerts(id,alert_ref,customer_id,severity,status) VALUES('${U(24)}','OTHER-CUSTOMER','${U(11)}','CRITICAL','UNASSIGNED')`,
 `UPDATE alerts SET status=status WHERE id='${U(24)}'`]){
 await db.exec(sql);snapshots.push((await one(db,`SELECT jsonb_build_object('customers',(SELECT jsonb_agg(jsonb_build_object('id',id,'score',risk_score,'tier',risk_tier) ORDER BY id) FROM customers),'history',(SELECT coalesce(jsonb_agg(jsonb_build_object('customer_id',customer_id,'previous_score',previous_score,'new_score',new_score,'previous_tier',previous_tier,'new_tier',new_tier,'reason',change_reason) ORDER BY change_reason,new_score),'[]'::jsonb) FROM risk_score_history)) AS state`)).state);
 }return snapshots;}
function loadModule(file,mocks){const object={exports:{}};const req=name=>Object.prototype.hasOwnProperty.call(mocks,name)?mocks[name]:require(name);vm.runInNewContext(fs.readFileSync(file,'utf8'),{require:req,module:object,console,process:{argv:[],env:{}},AbortSignal,URL,Buffer});return object.exports;}
(async()=>{
 const old=await setup(path.join(ROOT,'scripts/fixtures/unified-risk-before-null-guard.sql'));const expected=await linked(old);const oldCount=(await one(old,'SELECT count(*)::int AS n FROM risk_score_history')).n;
 await old.exec(`INSERT INTO alerts(id,alert_ref,severity,status) VALUES('${U(30)}','NULL-OLD','LOW','UNASSIGNED')`);
 assert.equal((await one(old,'SELECT count(*)::int AS n FROM risk_score_history WHERE customer_id IS NULL')).n,1);pass('Reviewed old trigger reproduces an orphan history on null-customer insert');await old.close();
 const db=await setup(path.join(ROOT,'sql/coreaml-null-customer-risk-guard-local.sql'));const actual=await linked(db);assert.deepEqual(actual,expected);
 for(const name of ['Low severity preserves existing baseline','High severity scoring unchanged','Critical aggregation unchanged','Medium aggregation unchanged','Dismissal recalculation unchanged','Severity-change recalculation unchanged','Separate customer scoring unchanged','Unchanged scoring creates no extra history'])pass(name);
 assert.equal((await one(db,'SELECT count(*)::int AS n FROM risk_score_history')).n,oldCount);
 await db.exec(`INSERT INTO alerts(id,alert_ref,severity,status) VALUES('${U(30)}','NULL-NEW','LOW','UNASSIGNED');UPDATE alerts SET status='INVESTIGATING' WHERE id='${U(30)}';UPDATE alerts SET severity='CRITICAL' WHERE id='${U(30)}';`);
 assert.equal((await one(db,'SELECT count(*)::int AS n FROM risk_score_history WHERE customer_id IS NULL')).n,0);assert.equal((await one(db,'SELECT count(*)::int AS n FROM risk_score_history')).n,oldCount);pass('Null-customer insert, status and severity changes create no risk history');
 await db.exec(fs.readFileSync(path.join(ROOT,'sql/coreaml-case-claim-local.sql'),'utf8'));
 const helpers={ROOT,BANK,API:'http://127.0.0.1:55321',DB:'test',lit};
 const acceptance=loadModule(path.join(ROOT,'scripts/verify-case-claim-acceptance-local.cjs'),{'./aml-compatible-db.cjs':helpers,'./aml-browser-readiness.cjs':{},'./verify-coreaml-kyc-browser-local.cjs':{}});
 const installer=loadModule(path.join(ROOT,'scripts/apply-null-customer-risk-guard-local.cjs'),{'./aml-compatible-db.cjs':helpers,'./verify-case-claim-acceptance-local.cjs':acceptance});
 const sql=acceptance.fingerprintSQL([U(40)]);const before=(await one(db,sql)).md5;
 await db.exec('BEGIN;'+installer.probeSQL(U(40),U(1),before)+'ROLLBACK;');assert.equal((await one(db,sql)).md5,before);pass('Exact local installer probe verifies insertion, claiming and rollback preserve state');
 const resume='0f27350e-d2be-4d65-8e4e-21401f52a907';const prior={run_id:resume,fixture:{created:true,marker:'CaseAcceptance-'+resume,browser_alert_id:U(50),race_alert_id:U(51)},diagnostics:{phases:[],race:[]}};
 assert.equal(acceptance.validateRecovery(prior,resume).length,2);assert.throws(()=>acceptance.validateRecovery({...prior,diagnostics:{phases:[{}],race:[]}},resume));assert.throws(()=>acceptance.validateRecovery(prior,U(999)));pass('Recovery rejects unknown baselines and runs that already reached browser actions');
 const reasons=['fixture-1','fixture-2'];const history=reasons.map((reason,i)=>({id:U(70+i),customer_id:null,previous_score:null,previous_tier:null,new_score:10,new_tier:'LOW',change_reason:reason}));
 assert.equal(acceptance.orphanHistoryIds(history,reasons).length,2);
 for(const change of [rows=>rows.push({...rows[0],id:U(99)}),rows=>rows[0].customer_id=U(10),rows=>rows[0].new_score=11,rows=>rows[0].change_reason='unrelated']){const copy=structuredClone(history);change(copy);assert.throws(()=>acceptance.orphanHistoryIds(copy,reasons));}
 pass('Historical accounting cannot exclude extra, linked or unrelated risk rows');
 await db.close();console.log(passes+' isolated PostgreSQL/recovery checks passed; native local installation remains separate.');
})().catch(error=>{console.error(error);process.exitCode=1;});
