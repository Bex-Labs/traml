import fs from 'node:fs';import path from 'node:path';import assert from 'node:assert/strict';import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const {PGlite}=await import(process.env.COREAML_PG_TEST_LIBRARY||new URL('./filing-tests/node_modules/@electric-sql/pglite/dist/index.js',import.meta.url).href);
const db=new PGlite();
const {createRequire}=await import('node:module');const require=createRequire(import.meta.url);const upgrade=require('./apply-filing-review-v2-local.cjs');
const legacySql=fs.readFileSync(path.join(root,'sql/coreaml-filing-workspace-local.sql'),'utf8').replace(/\r\n/g,'\n');
const head='11111111-1111-4111-8111-111111111111',maker='22222222-2222-4222-8222-222222222222',foreign='33333333-3333-4333-8333-333333333333',bank='a1000000-0000-4000-8000-000000000001',other='a1000000-0000-4000-8000-000000000002',report='44444444-4444-4444-8444-444444444444',alert='55555555-5555-4555-8555-555555555555',submission='66666666-6666-4666-8666-666666666666',approval='77777777-7777-4777-8777-777777777777';
await db.exec(`CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role;CREATE SCHEMA auth;CREATE SCHEMA coreaml_private;
CREATE TABLE auth.users(id uuid PRIMARY KEY);INSERT INTO auth.users VALUES('${head}'),('${maker}'),('${foreign}');
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.actor',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid PRIMARY KEY,tenant_id text,role text,is_active boolean,full_name text);
INSERT INTO public.user_profiles VALUES('${head}','${bank}','head_of_compliance',true,'Head'),('${maker}','${bank}','compliance_officer',true,'Maker'),('${foreign}','${other}','head_of_compliance',true,'Foreign head');
CREATE FUNCTION coreaml_private.review_staff() RETURNS public.user_profiles LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE p public.user_profiles%ROWTYPE;BEGIN SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid() AND is_active AND role='head_of_compliance';IF NOT FOUND THEN RAISE EXCEPTION 'Denied' USING ERRCODE='42501';END IF;RETURN p;END $$;
CREATE TABLE public.suspicious_transaction_reports(id uuid PRIMARY KEY,alert_id uuid,tenant_id text,generated_by uuid,created_by uuid,reviewed_by uuid,report_data jsonb,investigator_notes text,executive_justification text,status text,locked_at timestamptz);
CREATE TABLE public.coreaml_case_claims(id uuid PRIMARY KEY,anchor_alert_id uuid,alert_ids uuid[],tenant_id text,investigator_id uuid,case_reference text);
CREATE TABLE public.coreaml_review_submissions(request_id uuid PRIMARY KEY,tenant_id text,kind text,actor_id uuid,case_reference text,result jsonb,snapshot jsonb);
CREATE TABLE public.coreaml_review_actions(request_id uuid PRIMARY KEY,target_id uuid,tenant_id text,kind text,decision text,actor_id uuid,maker_id uuid,case_reference text,notes text,created_at timestamptz DEFAULT now());
CREATE TABLE public.alerts(id uuid PRIMARY KEY,tenant_id text,case_reference text,assigned_user_id uuid,customer_id uuid,transaction_id uuid,evidence jsonb,alert_ref text);
CREATE TABLE public.customers(id uuid PRIMARY KEY,tenant_id text,entity_name text,first_name text,last_name text,customer_type text);
CREATE TABLE public.accounts(id uuid PRIMARY KEY,customer_id uuid,account_number text);
CREATE TABLE public.transactions(id uuid PRIMARY KEY,account_id uuid,transaction_reference text,amount numeric,currency text,transaction_timestamp timestamptz,transaction_type text,channel text,narration text,counterparty_name text,counterparty_account text,counterparty_bank text);
INSERT INTO public.customers VALUES('${maker}','${bank}','Fictional Customer',NULL,NULL,'RETAIL');
INSERT INTO public.alerts VALUES('${alert}','${bank}','CASE-DEMO','${maker}','${maker}',NULL,'{"method":"SYNTHETIC"}','DEMO-ONE');
INSERT INTO public.coreaml_case_claims VALUES('${alert}','${alert}',ARRAY['${alert}']::uuid[],'${bank}','${maker}','CASE-DEMO');
INSERT INTO public.coreaml_review_submissions VALUES('${submission}','${bank}','EXECUTIVE','${maker}','CASE-DEMO',jsonb_build_object('report_id','${report}'),'{"narrative":"Approved narrative with enough text.","evidence_snapshot":{"entities":[],"txs":[]}}');
INSERT INTO public.suspicious_transaction_reports VALUES('${report}','${alert}','${bank}','${maker}','${maker}','${head}',jsonb_build_object('purpose','EXECUTIVE_REVIEW_NOT_FILING','case_reference','CASE-DEMO','alert_ids',jsonb_build_array('${alert}'),'submission_request_id','${submission}','evidence_snapshot','{"entities":[],"txs":[]}'::jsonb),'Approved narrative with enough text.','Approved for reporting','APPROVED',now());
INSERT INTO public.coreaml_review_actions(request_id,target_id,tenant_id,kind,decision,actor_id,maker_id,case_reference,notes) VALUES('${approval}','${report}','${bank}','EXECUTIVE','APPROVE','${head}','${maker}','CASE-DEMO','Approved for reporting');`);
// Reproduce the original Windows installation, including CRLF in PostgreSQL prosrc.
await db.exec(legacySql.replace(/\n/g,'\r\n'));
for(const f of upgrade.functions(legacySql)){
 const value=Object.values((await db.query(upgrade.sourceHashSql(f.name))).rows[0])[0];assert.equal(value,f.hash);
}
assert.deepEqual(upgrade.functions(legacySql),upgrade.functions(legacySql.replace(/\n/g,'\r\n')));
const originalContext=Object.values((await db.query("SELECT prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='coreaml_private' AND proname='filing_context'")).rows[0])[0];assert(originalContext.includes('\r\n'));
const receiptDdl=legacySql.match(/CREATE FUNCTION public\.coreaml_filing_receipt[^]*?\$\$;/)[0];
await db.exec('BEGIN;'+receiptDdl.replace('CREATE FUNCTION','CREATE OR REPLACE FUNCTION').replace('BEGIN','BEGIN\n -- Deliberately changed source for integrity regression\n'));
assert.notEqual(Object.values((await db.query(upgrade.sourceHashSql('public.coreaml_filing_receipt'))).rows[0])[0],upgrade.functions(legacySql).find(f=>f.name==='public.coreaml_filing_receipt').hash);await db.exec('ROLLBACK;');
console.log('PASS Windows CRLF function sources match LF expectations while actual source changes remain rejected');

await db.exec(`CREATE FUNCTION coreaml_private.case_workflow_staff(p_write boolean) RETURNS public.user_profiles LANGUAGE plpgsql SECURITY DEFINER AS $$ DECLARE p public.user_profiles%ROWTYPE;BEGIN SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid() AND is_active AND role IN ('head_of_compliance','compliance_officer');IF NOT FOUND THEN RAISE EXCEPTION 'Denied' USING ERRCODE='42501';END IF;RETURN p;END $$;`);
const scalar=async(sql,args=[])=>Object.values((await db.query(sql,args)).rows[0])[0];
async function asActor(id,fn){await db.query("SELECT set_config('request.actor',$1,false)",[id]);await db.exec('SET ROLE authenticated');try{return await fn();}finally{await db.exec('RESET ROLE');}}
const source0=await asActor(head,()=>scalar('SELECT public.coreaml_filing_read($1,0,NULL)',[report]));
const save={mode:'TEST',report_type:'SAR',reference:'CASE-DEMO',xml:'<report/>',client_request_hash:'a'.repeat(64)};
await scalar("SELECT public.coreaml_filing_commit($1,$2,$3,'SAVE',0,$4,$5)",[head,report,crypto.randomUUID(),source0.source_hash,save]);
const prior=await scalar('SELECT to_jsonb(f) FROM public.coreaml_filing_drafts f');
await db.exec(fs.readFileSync(path.join(root,'sql/coreaml-filing-review-v2-local.sql'),'utf8'));
const migrated=await scalar("SELECT to_jsonb(f)-ARRAY['prepared_by','submitted_request_id','final_review_request_id','pending_outcome_id'] FROM public.coreaml_filing_drafts f");assert.deepEqual(migrated,prior);
assert.equal(await scalar('SELECT final_review_request_id FROM public.coreaml_filing_drafts'),null);
console.log('PASS Upgrade preserves existing preparation and does not invent a preparer or final approval');
let ctx=await asActor(maker,()=>scalar("SELECT public.coreaml_filing_read_v2($1,0,NULL,'ALL')",[report]));assert.equal(ctx.role,'compliance_officer');assert.equal(ctx.source.owner_id,maker);
await assert.rejects(()=>asActor(foreign,()=>scalar("SELECT public.coreaml_filing_read_v2($1,0,NULL,'ALL')",[report])));
const peer='99999999-9999-4999-8999-999999999999';await db.query('INSERT INTO auth.users VALUES($1)',[peer]);await db.query("INSERT INTO public.user_profiles VALUES($1,$2,'compliance_officer',true,'Peer')",[peer,bank]);
await assert.rejects(()=>asActor(peer,()=>scalar("SELECT public.coreaml_filing_read_v2($1,0,NULL,'ALL')",[report])));
await assert.rejects(()=>asActor(head,()=>db.exec("SELECT * FROM public.coreaml_filing_events")));
console.log('PASS Assigned officer can read own package; peer and other-bank direct access are denied');
assert.equal(await scalar("SELECT has_function_privilege('service_role','coreaml_private.filing_commit_v1(uuid,uuid,uuid,text,integer,text,jsonb)','EXECUTE')"),false);console.log('PASS The former head-only commit implementation cannot be invoked to bypass the new review gate');

const original=await scalar("SELECT jsonb_build_object('reports',(SELECT jsonb_agg(to_jsonb(r)) FROM public.suspicious_transaction_reports r),'alerts',(SELECT jsonb_agg(to_jsonb(a)) FROM public.alerts a),'claims',(SELECT jsonb_agg(to_jsonb(c)) FROM public.coreaml_case_claims c))");
const commit=async(actor,action,revision,payload,id=crypto.randomUUID())=>{await db.exec('SET ROLE service_role');try{return await scalar('SELECT public.coreaml_filing_commit($1,$2,$3,$4,$5,$6,$7)',[actor,report,id,action,revision,ctx.source_hash,payload]);}finally{await db.exec('RESET ROLE');}};
const xmlHash=await scalar("SELECT encode(sha256(convert_to('<report/>','UTF8')),'hex')"),proof={xml_hash:xmlHash,schema_hash:'b'.repeat(64),schema_label:'TEST fixture schema',client_request_hash:'b'.repeat(64)};
await assert.rejects(()=>commit(head,'SAVE',1,save));await assert.rejects(()=>commit(head,'EXPORT',1,proof));
let saved=await commit(maker,'SAVE',1,save);let revision=saved.revision;await commit(maker,'SUBMIT_REPORT',revision,proof);
await assert.rejects(()=>commit(maker,'SAVE',revision,save));await assert.rejects(()=>commit(maker,'APPROVE_REPORT',revision,{...proof,notes:'Self approval'}));
await db.query("UPDATE public.user_profiles SET role='head_of_compliance' WHERE id=$1",[maker]);await assert.rejects(()=>commit(maker,'APPROVE_REPORT',revision,{...proof,notes:'Role-swapped self approval'}));await db.query("UPDATE public.user_profiles SET role='compliance_officer' WHERE id=$1",[maker]);
let queue=await asActor(head,()=>scalar("SELECT public.coreaml_filing_read_v2(NULL,0,NULL,'FINAL_REVIEW')"));assert.equal(queue.total,1);assert.equal(queue.rows[0].revision,revision);
await commit(head,'RETURN_REPORT',revision,{notes:'Complete the prepared report before final approval.'});assert.equal(await scalar('SELECT state FROM public.coreaml_filing_drafts'),'RETURNED_FOR_PREPARATION');
console.log('PASS Officer submission reaches the Head queue; self approval and under-review edits are blocked; internal return is distinct');
saved=await commit(maker,'SAVE',revision,save);revision=saved.revision;await commit(maker,'SUBMIT_REPORT',revision,proof);const approvalId=crypto.randomUUID();await commit(head,'APPROVE_REPORT',revision,{...proof,notes:'Reviewed this complete reporting version.'},approvalId);await assert.rejects(()=>commit(maker,'EXPORT',revision,proof));
saved=await commit(maker,'SAVE',revision,save);revision=saved.revision;assert.equal(await scalar('SELECT final_review_request_id FROM public.coreaml_filing_drafts'),null);await assert.rejects(()=>commit(head,'EXPORT',revision,proof));
// Replaying an earlier approval returns its receipt without reinstating it on the changed version.
assert.equal((await commit(head,'APPROVE_REPORT',revision-1,{...proof,notes:'Reviewed this complete reporting version.'},approvalId)).replayed,true);assert.equal(await scalar('SELECT state FROM public.coreaml_filing_drafts'),'PREPARED');
console.log('PASS Every post-approval save invalidates approval; replay cannot approve a newer version');
await commit(maker,'SUBMIT_REPORT',revision,proof);await assert.rejects(()=>commit(head,'APPROVE_REPORT',revision,{...proof,schema_hash:'c'.repeat(64),notes:'Changed schema'}));await commit(head,'APPROVE_REPORT',revision,{...proof,notes:'Final reporting version approved.'});const exp=crypto.randomUUID();await commit(head,'EXPORT',revision,proof,exp);
const submitId=crypto.randomUUID();const evidence={reference:'TEST-SUBMISSION',evidence_reference:'Secure demo evidence',occurred_at:new Date().toISOString(),notes:'Fictional workflow test',export_id:exp};await commit(head,'SUBMISSION',revision,evidence,submitId);await assert.rejects(()=>commit(maker,'SAVE',revision,save));await assert.rejects(()=>commit(head,'REJECTION',revision,{...evidence,submission_id:submitId}));
const rejectionId=crypto.randomUUID();await commit(maker,'REJECTION',revision,{...evidence,submission_id:submitId},rejectionId);assert.equal(await scalar('SELECT state FROM public.coreaml_filing_drafts'),'OUTCOME_PENDING_CONFIRMATION');await assert.rejects(()=>commit(maker,'SAVE',revision,save));
await assert.rejects(()=>commit(head,'CONFIRM_OUTCOME',revision,{outcome_id:crypto.randomUUID(),notes:'Wrong response'}));await commit(head,'CONFIRM_OUTCOME',revision,{outcome_id:rejectionId,notes:'Confirmed the recorded goAML/NFIU rejection evidence.'});assert.equal(await scalar('SELECT state FROM public.coreaml_filing_drafts'),'REJECTION_RECORDED');
console.log('PASS Only a final-approved version can be filed; external REJECTION remains an officer-recorded response requiring Head confirmation');
saved=await commit(maker,'SAVE',revision,save);revision=saved.revision;await commit(maker,'SUBMIT_REPORT',revision,proof);await commit(head,'APPROVE_REPORT',revision,{...proof,notes:'Corrected version reviewed.'});const exp2=crypto.randomUUID();await commit(head,'EXPORT',revision,proof,exp2);const submit2=crypto.randomUUID();await commit(head,'SUBMISSION',revision,{...evidence,export_id:exp2,occurred_at:new Date().toISOString()},submit2);const ackId=crypto.randomUUID();await commit(maker,'ACKNOWLEDGEMENT',revision,{...evidence,submission_id:submit2,occurred_at:new Date().toISOString()},ackId);
await commit(head,'CONFIRM_OUTCOME',revision,{outcome_id:ackId,notes:'Acknowledgement evidence checked and recorded.'});assert.equal(await scalar('SELECT state FROM public.coreaml_filing_drafts'),'REPORTING_COMPLETED');
const progress=await asActor(maker,()=>scalar('SELECT public.coreaml_filing_progress($1)',[['CASE-DEMO']]));assert.equal(progress.rows[0].state,'REPORTING_COMPLETED');assert.equal(progress.rows[0].mode,'TEST');assert.equal((await asActor(peer,()=>scalar('SELECT public.coreaml_filing_progress($1)',[['CASE-DEMO']]))).rows.length,0);
const archive=await asActor(maker,()=>scalar('SELECT public.coreaml_filing_export_read_v2($1)',[exp]));assert.equal(archive.xml,'<report/>');assert.equal(archive.revision,revision-1);
const after=await scalar("SELECT jsonb_build_object('reports',(SELECT jsonb_agg(to_jsonb(r)) FROM public.suspicious_transaction_reports r),'alerts',(SELECT jsonb_agg(to_jsonb(a)) FROM public.alerts a),'claims',(SELECT jsonb_agg(to_jsonb(c)) FROM public.coreaml_case_claims c))");assert.deepEqual(after,original);
console.log('PASS Confirmed acknowledgement updates reporting progress, retains earlier exports and preserves original cases and customers');
// Exercise the installer's exact in-transaction protection and both-role probes.
for(const table of ['investigation_drafts','report_archives','system_events'])await db.exec(`CREATE TABLE public.${table}(id uuid)`);
await db.exec(`CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT (current_setting('request.jwt.claims',true)::jsonb->>'sub')::uuid $$;`);
await db.exec('BEGIN;CREATE TEMP TABLE filing_upgrade_before ON COMMIT DROP AS '+upgrade.snapshotSql()+';'+upgrade.probeSql()+'ROLLBACK;');
await db.exec('BEGIN;CREATE TEMP TABLE filing_upgrade_before ON COMMIT DROP AS '+upgrade.snapshotSql()+";UPDATE public.customers SET first_name='Unexpected change';");
await assert.rejects(()=>db.exec(upgrade.probeSql()),/Protected records changed during upgrade/);await db.exec('ROLLBACK;');
for(const f of upgrade.functions(fs.readFileSync(path.join(root,'sql/coreaml-filing-review-v2-local.sql'),'utf8'))){assert.equal(await scalar(upgrade.sourceHashSql(f.name)),f.hash);}
console.log('PASS Exact installer probes cover both roles and reject changed protected records before commit');
await db.close();console.log('9 real PostgreSQL maker-checker and upgrade groups passed in an isolated fictional schema.');
