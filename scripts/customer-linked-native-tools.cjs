'use strict';
const {ROOT,BANK,lit}=require('./aml-compatible-db.cjs');
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const normalize=text=>text.replace(/\r\n/g,'\n').trim().replace(/;$/,'');
const uuid=value=>typeof value==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
function validateFixture(f){assert(uuid(f.customer_id)&&Array.isArray(f.alert_ids)&&f.alert_ids.length===2&&f.alert_ids.every(uuid)&&new Set(f.alert_ids).size===2);assert(/^GroupClaimTest-[0-9a-f-]{36}$/i.test(f.marker));}
function validateContract(actual,expected){
 const reduced=list=>list.map(t=>({name:t.name,enabled:t.enabled,trigger_definition:normalize(t.trigger_definition),function_definition:normalize(t.function_definition)})).sort((a,b)=>a.name.localeCompare(b.name));
 assert.deepEqual(reduced(actual.customer_triggers),reduced(expected.customer_triggers),'Customer triggers differ from reviewed source; no fixture created');
 assert.equal(normalize(actual.risk_function_definition),normalize(expected.risk_function_definition),'Risk function differs from reviewed source');
 assert.deepEqual(actual.alert_trigger_names.sort(),['compatible_alert_guard','coreaml_guard_case_ownership','trigger_unified_risk_scoring']);
}
function contractSQL(){return `SELECT jsonb_build_object('customer_triggers',(SELECT jsonb_agg(jsonb_build_object('name',t.tgname,'enabled',t.tgenabled,'trigger_definition',pg_get_triggerdef(t.oid),'function_definition',pg_get_functiondef(t.tgfoid)) ORDER BY t.tgname) FROM pg_trigger t WHERE t.tgrelid='public.customers'::regclass AND NOT t.tgisinternal),'risk_function_definition',pg_get_functiondef('public.unified_risk_scoring()'::regprocedure),'alert_trigger_names',(SELECT jsonb_agg(tgname ORDER BY tgname) FROM pg_trigger WHERE tgrelid='public.alerts'::regclass AND NOT tgisinternal AND tgenabled='O'))::text;`;}
function snapshotSQL(f){
 validateFixture(f);const ids=f.alert_ids.map(id=>lit(id)+'::uuid').join(','),cust=lit(f.customer_id)+'::uuid';
 const hash=(table,alias,order='id',where='true')=>`(SELECT md5(coalesce(jsonb_agg(to_jsonb(${alias}) ORDER BY ${order})::text,'null')) FROM public.${table} ${alias} WHERE ${where})`;
 return `SELECT jsonb_build_object(
 'customers',${hash('customers','c','id','id IS DISTINCT FROM '+cust)},
 'alerts',${hash('alerts','a','id','id NOT IN ('+ids+')')},
 'risk_history',${hash('risk_score_history','h','id','customer_id IS DISTINCT FROM '+cust)},
 'claims',${hash('coreaml_case_claims','cl','id','anchor_alert_id NOT IN ('+ids+')')},
 'events',${hash('system_events','e','id',"coalesce(metadata->>'anchor_alert_id','') NOT IN ("+f.alert_ids.map(lit).join(',')+")")},
 'accounts',${hash('accounts','a')},'transactions',${hash('transactions','t')},
 'runs',${hash('coreaml_compatible_runs','r')},'results',${hash('coreaml_compatible_results','r')},
 'outbox',${hash('transaction_evaluation_outbox','o','transaction_id')},
 'archives',${hash('report_archives','r')},'drafts',${hash('investigation_drafts','d')},
 'reports',${hash('suspicious_transaction_reports','s')},'profiles',${hash('user_profiles','p')}
 )::text;`;
}
function assertSnapshot(before,after){const changed=Object.keys(before).filter(key=>before[key]!==after[key]);assert.equal(changed.length,0,'Existing state changed in: '+changed.join(', '));}
function fixtureStateSQL(f){validateFixture(f);const ids=f.alert_ids.map(id=>lit(id)+'::uuid').join(',');return `SELECT jsonb_build_object(
 'customer',(SELECT to_jsonb(c) FROM public.customers c WHERE id=${lit(f.customer_id)}::uuid),
 'history',(SELECT coalesce(jsonb_agg(to_jsonb(h) ORDER BY id),'[]'::jsonb) FROM public.risk_score_history h WHERE customer_id=${lit(f.customer_id)}::uuid),
 'alerts',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM public.alerts a WHERE id IN (${ids})),
 'claims',(SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY id),'[]'::jsonb) FROM public.coreaml_case_claims c WHERE anchor_alert_id IN (${ids})),
 'events',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY id),'[]'::jsonb) FROM public.system_events e WHERE metadata->>'anchor_alert_id' IN (${f.alert_ids.map(lit).join(',')}))
 )::text;`;}
function canonical(state){return {customer:state.customer,history:state.history,alerts:state.alerts.map(({status,assigned_user_id,case_reference,...fields})=>fields)};}
function assertClaim(state,f,actor,before){
 assert.deepEqual(canonical(state),canonical(before),'Claim changed risk state or canonical alert evidence');
 assert.equal(state.alerts.length,2);assert(state.alerts.every(a=>a.status==='INVESTIGATING'&&a.assigned_user_id===actor));
 assert.equal(new Set(state.alerts.map(a=>a.case_reference)).size,1);assert(state.alerts[0].case_reference?.startsWith('CASE-'));
 assert.equal(state.claims.length,1);assert.deepEqual([...state.claims[0].alert_ids].sort(),[...f.alert_ids].sort());assert.equal(state.claims[0].case_reference,state.alerts[0].case_reference);assert.equal(state.claims[0].investigator_id,actor);
 assert.equal(state.events.length,1);assert.equal(state.events[0].user_id,actor);assert.equal(state.events[0].metadata.case_ref,state.claims[0].case_reference);
}
function claimsSQL(actor){assert(uuid(actor));return `SET LOCAL ROLE authenticated;DO $claims$ BEGIN PERFORM set_config('request.jwt.claims',${lit(JSON.stringify({sub:actor,role:'authenticated',app_metadata:{role:'compliance_officer',tenant_id:BANK}}))},true);END $claims$;`;}
function setupSQL(f){
 validateFixture(f);
 return `BEGIN ISOLATION LEVEL REPEATABLE READ;
 -- Refuse before any fixture write if the reviewed webhook could enqueue a request.
 DO $gate$ BEGIN IF (SELECT count(DISTINCT name)=3 FROM vault.decrypted_secrets WHERE name IN ('project_url','anon_key','match_entity_webhook_secret') AND nullif(decrypted_secret,'') IS NOT NULL) THEN RAISE EXCEPTION 'Identity webhook is configured; no linked fixture created';END IF;END $gate$;
 INSERT INTO public.customers(id,customer_type,first_name,last_name,entity_name,tenant_id,kyc_status,risk_score,risk_tier)
 VALUES (${lit(f.customer_id)}::uuid,'INDIVIDUAL','Synthetic',${lit(f.marker)},${lit('Synthetic '+f.marker)},${lit(BANK)},'PENDING',10,'LOW');
 ${f.alert_ids.map((id,i)=>`INSERT INTO public.alerts(id,alert_ref,rule_triggered,severity,status,customer_id,tenant_id,evidence,details) VALUES (${lit(id)}::uuid,${lit(f.marker+'-'+i)},${lit(f.marker)},${lit(i===0?'HIGH':'MEDIUM')},'UNASSIGNED',${lit(f.customer_id)}::uuid,${lit(BANK)},${lit(JSON.stringify({method:'SYNTHETIC_GROUP_CLAIM_ACCEPTANCE',fixture:f.marker,customer_id:f.customer_id}))}::jsonb,${lit('Synthetic group claim '+i+'; no financial event.')});`).join('\n')}
 DO $risk$ BEGIN IF NOT EXISTS(SELECT 1 FROM public.customers WHERE id=${lit(f.customer_id)}::uuid AND risk_score=40 AND risk_tier::text='MEDIUM') OR (SELECT count(*) FROM public.risk_score_history WHERE customer_id=${lit(f.customer_id)}::uuid)<>2 THEN RAISE EXCEPTION 'Unexpected linked fixture risk calculation';END IF;END $risk$;`;
}
function probeSQL(f,actors){
 validateFixture(f);assert(actors.length===2&&actors.every(uuid));const ids=f.alert_ids.map(id=>lit(id)+'::uuid').join(',');const state='('+fixtureStateSQL(f).replace(/;\s*$/,'')+')::jsonb';
 const fault='case_group_fault_'+f.customer_id.replace(/-/g,'');
 return `CREATE TEMP TABLE coreaml_group_before(value jsonb) ON COMMIT DROP;INSERT INTO coreaml_group_before VALUES (${state});
 SAVEPOINT group_success_probe;
 ${claimsSQL(actors[0])}
 DO $claim$ DECLARE result jsonb; replay jsonb;BEGIN
 result:=public.coreaml_claim_case(${lit(f.alert_ids[0])}::uuid);replay:=public.coreaml_claim_case(${lit(f.alert_ids[1])}::uuid);
 IF result->'alert_ids' IS DISTINCT FROM (SELECT to_jsonb(array_agg(x ORDER BY x)) FROM unnest(ARRAY[${ids}]) x) OR replay->>'case_reference' IS DISTINCT FROM result->>'case_reference' OR replay->>'replayed'<>'true' THEN RAISE EXCEPTION 'Group claim/replay mismatch';END IF;
 END $claim$;
 ${claimsSQL(actors[1])}
 DO $denial$ BEGIN
 BEGIN PERFORM public.coreaml_claim_case(${lit(f.alert_ids[1])}::uuid);RAISE EXCEPTION 'Second officer unexpectedly stole group';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'Alert already claimed%' THEN RAISE;END IF;END;
 END $denial$;
 SET LOCAL ROLE postgres;
 DO $state$ DECLARE old_value jsonb;new_value jsonb;BEGIN SELECT value INTO old_value FROM coreaml_group_before;new_value:=${state};
 IF new_value->'customer' IS DISTINCT FROM old_value->'customer' OR new_value->'history' IS DISTINCT FROM old_value->'history' OR jsonb_array_length(new_value->'claims')<>1 OR jsonb_array_length(new_value->'events')<>1 THEN RAISE EXCEPTION 'Claim changed risk state or duplicated audit';END IF;
 IF (SELECT jsonb_agg(x-'status'-'assigned_user_id'-'case_reference') FROM jsonb_array_elements(new_value->'alerts') x) IS DISTINCT FROM (SELECT jsonb_agg(x-'status'-'assigned_user_id'-'case_reference') FROM jsonb_array_elements(old_value->'alerts') x) THEN RAISE EXCEPTION 'Claim changed canonical evidence';END IF;
 IF EXISTS(SELECT 1 FROM public.alerts WHERE id IN (${ids}) AND (status IS DISTINCT FROM 'INVESTIGATING' OR assigned_user_id IS DISTINCT FROM ${lit(actors[0])}::uuid)) THEN RAISE EXCEPTION 'Group ownership mismatch';END IF;
 IF (SELECT count(DISTINCT case_reference) FROM public.alerts WHERE id IN (${ids}))<>1 THEN RAISE EXCEPTION 'Group case references differ';END IF;
 END $state$;
 ROLLBACK TO SAVEPOINT group_success_probe;RELEASE SAVEPOINT group_success_probe;
 SAVEPOINT group_failure_probe;
 CREATE TEMP TABLE coreaml_group_counter(n integer);INSERT INTO coreaml_group_counter VALUES(0);
 CREATE FUNCTION coreaml_private.${fault}() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $fault$ DECLARE position integer;BEGIN
 IF NEW.id=ANY(ARRAY[${ids}]) AND NEW.status='INVESTIGATING' THEN UPDATE pg_temp.coreaml_group_counter SET n=n+1 RETURNING n INTO position;IF position=2 THEN RAISE EXCEPTION 'Injected second group-member failure';END IF;END IF;RETURN NEW;END $fault$;
 REVOKE ALL ON FUNCTION coreaml_private.${fault}() FROM PUBLIC,anon,authenticated;
 CREATE TRIGGER ${fault} BEFORE UPDATE ON public.alerts FOR EACH ROW EXECUTE FUNCTION coreaml_private.${fault}();
 ${claimsSQL(actors[0])}
 DO $failure$ BEGIN BEGIN PERFORM public.coreaml_claim_case(${lit(f.alert_ids[0])}::uuid);RAISE EXCEPTION 'Injected group failure did not occur';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Injected second group-member failure' THEN RAISE;END IF;END;END $failure$;
 SET LOCAL ROLE postgres;
 DO $rollback$ BEGIN IF ${state} IS DISTINCT FROM (SELECT value FROM coreaml_group_before) THEN RAISE EXCEPTION 'Failed group did not roll back all fixture state';END IF;END $rollback$;
 ROLLBACK TO SAVEPOINT group_failure_probe;RELEASE SAVEPOINT group_failure_probe;
 DO $clean$ BEGIN IF to_regprocedure(${lit('coreaml_private.'+fault+'()')}) IS NOT NULL THEN RAISE EXCEPTION 'Fault injection function survived rollback';END IF;END $clean$;`;
}
module.exports={validateContract,contractSQL,snapshotSQL,assertSnapshot,fixtureStateSQL,canonical,assertClaim,claimsSQL,setupSQL,probeSQL,validateFixture};
