'use strict';
const assert=require('node:assert/strict');
const {BANK,lit}=require('./aml-compatible-db.cjs');
const {validateFixture,snapshotSQL,fixtureStateSQL}=require('./customer-linked-native-tools.cjs');
const U=n=>`f0000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
const normalize=s=>s.replace(/\r\n/g,'\n').trim();
function body(source,name){const start=source.indexOf('FUNCTION '+name+'(');assert(start>=0,'Reviewed function missing: '+name);const tail=source.slice(start),a=tail.indexOf('AS $$')+5,b=tail.indexOf('$$;',a);assert(a>=5&&b>a);return normalize(tail.slice(a,b));}
function claims(actor,role='compliance_officer',bank=BANK){return `SET LOCAL ROLE authenticated;SELECT set_config('request.jwt.claims',${lit(JSON.stringify({sub:actor,role:'authenticated',app_metadata:{role,tenant_id:bank}}))},true);`;}
function stateSQL(f){return `SELECT jsonb_build_object('original',(${snapshotSQL(f).replace(/;\s*$/,'')})::jsonb,'fixture',(${fixtureStateSQL(f).replace(/;\s*$/,'')})::jsonb,'actions',(SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY request_id),'[]'::jsonb) FROM public.coreaml_case_actions a))::text;`;}
function probeSQL(f,peer){
 validateFixture(f);assert(/^[0-9a-f-]{36}$/i.test(f.owner_id)&&/^[0-9a-f-]{36}$/i.test(peer));
 const anchor=lit(f.alert_ids[0])+'::uuid',member=lit(f.alert_ids[1])+'::uuid',customer=lit(f.customer_id)+'::uuid';
 const pins=lit(JSON.stringify({entity_ids:[f.customer_id],transaction_refs:[]}))+'::jsonb';
 const narrative=lit('Synthetic rollback-only investigation narrative. No financial event.');
 const save=(id,rev=0,text=narrative,snapshot=pins)=>`public.coreaml_case_action(${anchor},'SAVE',${rev},'${U(id)}'::uuid,${text},${snapshot})`;
 const close=(id,rev=1)=>`public.coreaml_case_action(${member},'CLOSE',${rev},'${U(id)}'::uuid)`;
 const deny=(expr,pattern)=>`DO $deny$ BEGIN BEGIN PERFORM ${expr};RAISE EXCEPTION 'PROBE_UNEXPECTED_SUCCESS';EXCEPTION WHEN OTHERS THEN IF SQLERRM='PROBE_UNEXPECTED_SUCCESS' OR SQLERRM NOT LIKE ${lit('%'+pattern+'%')} THEN RAISE;END IF;END;END $deny$;`;
 return `SAVEPOINT workflow_probe;
 CREATE TEMP TABLE coreaml_workflow_before(value jsonb) ON COMMIT DROP;INSERT INTO coreaml_workflow_before VALUES((${stateSQL(f).replace(/;\s*$/,'')})::jsonb);
 ${claims(f.owner_id)}
 DO $load$ DECLARE r jsonb;BEGIN r:=public.coreaml_load_case_draft(${member});IF r->>'exists'<>'false' OR (r->>'revision')::int<>0 OR r->>'case_reference'<>${lit(f.case_reference)} OR r->>'read_only'<>'false' THEN RAISE EXCEPTION 'Empty load contract mismatch';END IF;END $load$;
 DO $save$ DECLARE r jsonb;s jsonb;BEGIN r:=${save(1)};s:=public.coreaml_case_action(${member},'SAVE',0,'${U(1)}',${narrative},${pins});IF r->>'revision'<>'1' OR r->>'status'<>'IN_PROGRESS' OR s->>'replayed'<>'true' OR (s-'replayed') IS DISTINCT FROM (r-'replayed') THEN RAISE EXCEPTION 'Save/replay receipt mismatch';END IF;END $save$;
 ${deny(save(2), 'revision conflict')}
 ${deny(save(1,0,lit('Different content cannot reuse this request.')), 'different content')}
 ${deny(save(3,1,narrative,lit('{"entity_ids":["00000000-0000-4000-8000-000000000000"],"transaction_refs":[]}')+'::jsonb'), 'Pinned entity unavailable')}
 ${deny(save(4,1,narrative,lit('{"entity_ids":[],"transaction_refs":["UNAVAILABLE-WORKFLOW-PROBE"]}')+'::jsonb'), 'Pinned transaction unavailable')}
 DO $direct$ BEGIN
 BEGIN UPDATE public.alerts SET details='PROBE MUST NOT REPLACE DETECTION EVIDENCE' WHERE id=${anchor};IF FOUND THEN RAISE EXCEPTION 'PROBE_UNEXPECTED_SUCCESS';END IF;EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN DELETE FROM public.alerts WHERE id=${member};IF FOUND THEN RAISE EXCEPTION 'PROBE_UNEXPECTED_SUCCESS';END IF;EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN UPDATE public.investigation_drafts SET draft_narrative='direct overwrite' WHERE alert_id=${anchor};IF FOUND THEN RAISE EXCEPTION 'PROBE_UNEXPECTED_SUCCESS';END IF;EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN DELETE FROM public.investigation_drafts WHERE alert_id=${anchor};IF FOUND THEN RAISE EXCEPTION 'PROBE_UNEXPECTED_SUCCESS';END IF;EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN DELETE FROM public.coreaml_case_actions WHERE request_id='${U(1)}';IF FOUND THEN RAISE EXCEPTION 'PROBE_UNEXPECTED_SUCCESS';END IF;EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 END $direct$;
 ${claims(peer)}
 ${deny(`public.coreaml_load_case_draft(${anchor})`,'Case unavailable')}
 ${deny(save(5,1),'Case unavailable')}
 ${claims(f.owner_id,'compliance_officer','b0000000-0000-4000-8000-000000000999')}
 ${deny(`public.coreaml_load_case_draft(${anchor})`,'Active authorized bank profile required')}
 SET LOCAL ROLE postgres;
 CREATE FUNCTION coreaml_private.workflow_probe_audit_fault() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $fault$ BEGIN IF NEW.event_type IN ('CASE_DRAFT_SAVED','CASE_CLOSED') THEN RAISE EXCEPTION 'Injected workflow audit failure';END IF;RETURN NEW;END $fault$;
 REVOKE ALL ON FUNCTION coreaml_private.workflow_probe_audit_fault() FROM PUBLIC,anon,authenticated;
 CREATE TRIGGER workflow_probe_audit_fault BEFORE INSERT ON public.system_events FOR EACH ROW EXECUTE FUNCTION coreaml_private.workflow_probe_audit_fault();
 ${claims(f.owner_id)}
 ${deny(save(6,1,lit('A new narrative that must roll back when audit insertion fails.')),'Injected workflow audit failure')}
 ${deny(close(7),'Injected workflow audit failure')}
 DO $rolled$ DECLARE r jsonb;BEGIN r:=public.coreaml_load_case_draft(${anchor});IF r->>'revision'<>'1' OR r->>'draft_narrative'<>${narrative} OR r->>'case_status'<>'INVESTIGATING' THEN RAISE EXCEPTION 'Audit failure left partial workflow changes';END IF;END $rolled$;
 SET LOCAL ROLE postgres;DROP TRIGGER workflow_probe_audit_fault ON public.system_events;DROP FUNCTION coreaml_private.workflow_probe_audit_fault();
 ${claims(f.owner_id)}
 DO $close$ DECLARE r jsonb;s jsonb;l jsonb;BEGIN r:=${close(8)};s:=public.coreaml_case_action(${anchor},'CLOSE',1,'${U(8)}');l:=public.coreaml_load_case_draft(${member});IF r->>'revision'<>'2' OR r->>'status'<>'CLOSED' OR s->>'replayed'<>'true' OR (r-'replayed') IS DISTINCT FROM (s-'replayed') OR l->>'read_only'<>'true' OR l->>'status'<>'CLOSED' THEN RAISE EXCEPTION 'Close/replay/read contract mismatch';END IF;END $close$;
 ${deny(save(9,2),'no longer open')}
 SET LOCAL ROLE postgres;
 DO $protected$ DECLARE b jsonb;n jsonb;BEGIN SELECT value INTO b FROM coreaml_workflow_before;n:=(${stateSQL(f).replace(/;\s*$/,'')})::jsonb;
 IF n->'fixture'->'customer' IS DISTINCT FROM b->'fixture'->'customer' OR n->'fixture'->'history' IS DISTINCT FROM b->'fixture'->'history' OR n->'fixture'->'claims' IS DISTINCT FROM b->'fixture'->'claims' THEN RAISE EXCEPTION 'Workflow changed customer, risk or claim state';END IF;
 IF (SELECT jsonb_agg(x-'status' ORDER BY x->>'id') FROM jsonb_array_elements(n->'fixture'->'alerts') x) IS DISTINCT FROM (SELECT jsonb_agg(x-'status' ORDER BY x->>'id') FROM jsonb_array_elements(b->'fixture'->'alerts') x) THEN RAISE EXCEPTION 'Workflow changed immutable alert evidence';END IF;
 IF EXISTS(SELECT 1 FROM public.alerts WHERE id IN (${anchor},${member}) AND status<>'CLOSED') OR (SELECT count(*) FROM public.coreaml_case_actions)<>2 OR (SELECT count(*) FROM public.system_events WHERE metadata->>'request_id' IN ('${U(1)}','${U(8)}'))<>2 THEN RAISE EXCEPTION 'Closure scope or exactly-once audit mismatch';END IF;
 IF ((n->'original')-'drafts') IS DISTINCT FROM ((b->'original')-'drafts') THEN RAISE EXCEPTION 'Workflow changed unrelated state';END IF;
 END $protected$;
 ROLLBACK TO SAVEPOINT workflow_probe;RELEASE SAVEPOINT workflow_probe;`;
}
function installationSQL(f,peer,beforeOriginal,beforeFixture,sql,installed=false){
 const originalExpr='('+snapshotSQL(f).replace(/;\s*$/,'')+')::jsonb',fixtureExpr='('+fixtureStateSQL(f).replace(/;\s*$/,'')+')::jsonb';
 const sameData=`DO $same$ BEGIN IF ${originalExpr} IS DISTINCT FROM ${lit(JSON.stringify(beforeOriginal))}::jsonb OR ${fixtureExpr} IS DISTINCT FROM ${lit(JSON.stringify(beforeFixture))}::jsonb THEN RAISE EXCEPTION 'Data changed before or during workflow installation';END IF;END $same$;`;
 return `BEGIN;SET LOCAL lock_timeout='5s';LOCK TABLE public.investigation_drafts,public.coreaml_case_claims,public.alerts IN SHARE ROW EXCLUSIVE MODE;
 ${sameData}
 ${installed?'':sql}
 CREATE TEMP TABLE workflow_install_before(value jsonb) ON COMMIT DROP;INSERT INTO workflow_install_before VALUES((${stateSQL(f).replace(/;\s*$/,'')})::jsonb);
 ${probeSQL(f,peer)}
 DO $rollback$ BEGIN IF (${stateSQL(f).replace(/;\s*$/,'')})::jsonb IS DISTINCT FROM (SELECT value FROM workflow_install_before) THEN RAISE EXCEPTION 'Rollback probe left persistent data changes';END IF;
 IF to_regprocedure('coreaml_private.workflow_probe_audit_fault()') IS NOT NULL THEN RAISE EXCEPTION 'Fault injection survived';END IF;
 IF has_function_privilege('anon','public.coreaml_load_case_draft(uuid)','EXECUTE') OR has_function_privilege('anon','public.coreaml_case_action(uuid,text,integer,uuid,text,jsonb)','EXECUTE') OR has_table_privilege('authenticated','public.coreaml_case_actions','INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER') OR has_table_privilege('authenticated','public.investigation_drafts','INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER') OR has_table_privilege('authenticated','public.alerts','TRUNCATE,TRIGGER') THEN RAISE EXCEPTION 'Unexpected workflow privileges';END IF;END $rollback$;
 ${sameData}COMMIT;`;
}
module.exports={body,normalize,claims,stateSQL,probeSQL,installationSQL};
