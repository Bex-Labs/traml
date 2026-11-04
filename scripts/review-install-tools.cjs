'use strict';
const assert=require('node:assert/strict');
const q=v=>"'"+String(v).replace(/'/g,"''")+"'";
function probeSQL(f){for(const id of Object.values(f))assert(/^[a-f0-9-]{36}$/i.test(id));const {bank,maker,head,other,qa,qaMember,executive,execMember,report,qaClaim,execClaim,qaDraft,execDraft,qaRequest,execRequest,rejectRequest,faultRequest,qaReject}=f;
const ref1='ReviewProbe-'+qa,ref2='ReviewProbe-'+executive;
const role=(id,r,b=bank)=>`PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',${q(id)},'role','authenticated','app_metadata',jsonb_build_object('tenant_id',${q(b)},'role',${q(r)}))::text,true);EXECUTE 'SET LOCAL ROLE authenticated';`;
return `
INSERT INTO public.alerts(id,alert_ref,customer_id,transaction_id,rule_triggered,severity,status,assigned_user_id,tenant_id,case_reference,evidence) VALUES
 (${q(qa)},${q('Probe-'+qa)},NULL,NULL,'Review rollback probe','MEDIUM','PENDING_QA_REVIEW',${q(maker)},${q(bank)},${q(ref1)},'{}'),
 (${q(qaMember)},${q('Probe-'+qaMember)},NULL,NULL,'Review rollback probe','MEDIUM','PENDING_QA_REVIEW',${q(maker)},${q(bank)},${q(ref1)},'{}'),
 (${q(executive)},${q('Probe-'+executive)},NULL,NULL,'Review rollback probe','MEDIUM','ESCALATED',${q(maker)},${q(bank)},${q(ref2)},'{}'),
 (${q(execMember)},${q('Probe-'+execMember)},NULL,NULL,'Review rollback probe','MEDIUM','ESCALATED',${q(maker)},${q(bank)},${q(ref2)},'{}');
INSERT INTO public.coreaml_case_claims(id,anchor_alert_id,tenant_id,investigator_id,case_reference,alert_ids) VALUES
 (${q(qaClaim)},${q(qa)},${q(bank)},${q(maker)},${q(ref1)},ARRAY[${q(qa)},${q(qaMember)}]::uuid[]),
 (${q(execClaim)},${q(executive)},${q(bank)},${q(maker)},${q(ref2)},ARRAY[${q(executive)},${q(execMember)}]::uuid[]);
INSERT INTO public.investigation_drafts(id,tenant_id,alert_id,investigator_id,case_reference,revision,status,draft_narrative,evidence_snapshot) VALUES
 (${q(qaDraft)},${q(bank)},${q(qa)},${q(maker)},${q(ref1)},1,'SUBMITTED','Isolated rollback review narrative.','{"entities":[],"txs":[]}'),
 (${q(execDraft)},${q(bank)},${q(executive)},${q(maker)},${q(ref2)},1,'SUBMITTED','Isolated rollback review narrative.','{"entities":[],"txs":[]}');
INSERT INTO public.suspicious_transaction_reports(id,alert_id,tenant_id,generated_by,created_by,status,report_data,investigator_notes) VALUES
 (${q(report)},${q(executive)},${q(bank)},${q(maker)},${q(maker)},'PENDING_APPROVAL',jsonb_build_object('case_reference',${q(ref2)},'alert_ids',jsonb_build_array(${q(executive)},${q(execMember)})),'Isolated rollback report');
DO $$ DECLARE ctx jsonb;ack jsonb;again jsonb;n integer;BEGIN
 ${role(maker,'compliance_officer')}
 BEGIN PERFORM public.coreaml_load_review('QA',${q(qa)});RAISE EXCEPTION 'Officer was allowed to decide';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 EXECUTE 'RESET ROLE';
 ${role(head,'head_of_compliance','a1000000-0000-4000-8000-000000000002')}
 BEGIN PERFORM public.coreaml_load_review('QA',${q(qa)});RAISE EXCEPTION 'Forged bank accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(head,'head_of_compliance')}
 ctx:=public.coreaml_load_review('QA',${q(qa)});
 BEGIN PERFORM public.coreaml_review_decision('QA',${q(qa)},repeat('0',64),'APPROVE','Reviewed rollback case',${q(qaRequest)});RAISE EXCEPTION 'Stale token accepted';EXCEPTION WHEN serialization_failure THEN NULL;END;
 ack:=public.coreaml_review_decision('QA',${q(qa)},ctx->>'token','APPROVE','Reviewed rollback case',${q(qaRequest)});
 again:=public.coreaml_review_decision('QA',${q(qa)},ctx->>'token','APPROVE','Reviewed rollback case',${q(qaRequest)});
 IF again->>'replayed'<>'true' OR ack->>'regulatory_submission'<>'false' THEN RAISE EXCEPTION 'Receipt replay incorrect';END IF;
 BEGIN PERFORM public.coreaml_review_decision('QA',${q(qa)},ctx->>'token','REJECT','Changed content',${q(qaRequest)});RAISE EXCEPTION 'UUID content reuse accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 BEGIN UPDATE public.suspicious_transaction_reports SET status='APPROVED' WHERE id=${q(report)};RAISE EXCEPTION 'Direct report update succeeded';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN DELETE FROM public.coreaml_review_actions WHERE request_id=${q(qaRequest)};RAISE EXCEPTION 'Receipt deletion succeeded';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 EXECUTE 'RESET ROLE';
 IF (SELECT count(*) FROM public.alerts WHERE id=ANY(ARRAY[${q(qa)},${q(qaMember)}]::uuid[]) AND status='CLOSED' AND qa_reviewed_by=${q(head)})<>2 THEN RAISE EXCEPTION 'QA group not closed';END IF;
 IF (SELECT count(*) FROM public.system_events WHERE metadata->>'request_id'=${q(qaRequest)})<>1 THEN RAISE EXCEPTION 'Duplicate or missing QA audit';END IF;
 ${role(head,'head_of_compliance')}
 ctx:=public.coreaml_load_review('EXECUTIVE',${q(report)});
 ack:=public.coreaml_review_decision('EXECUTIVE',${q(report)},ctx->>'token','APPROVE','Approved for report preparation only',${q(execRequest)});
 EXECUTE 'RESET ROLE';
 IF (SELECT status FROM public.suspicious_transaction_reports WHERE id=${q(report)})<>'APPROVED' OR ack->>'regulatory_submission'<>'false' OR (SELECT count(*) FROM public.alerts WHERE id=ANY(ARRAY[${q(executive)},${q(execMember)}]::uuid[]) AND status='ESCALATED')<>2 THEN RAISE EXCEPTION 'Executive approval side effects incorrect';END IF;
 -- Rollback-only resets prepare an independent rejection and injected audit-failure probe.
 UPDATE public.suspicious_transaction_reports SET status='PENDING_APPROVAL',locked_at=NULL,reviewed_by=NULL WHERE id=${q(report)};
 ${role(head,'head_of_compliance')}
 ctx:=public.coreaml_load_review('EXECUTIVE',${q(report)});
 ack:=public.coreaml_review_decision('EXECUTIVE',${q(report)},ctx->>'token','REJECT','Return for further investigation',${q(rejectRequest)});
 EXECUTE 'RESET ROLE';
 IF (SELECT status FROM public.investigation_drafts WHERE id=${q(execDraft)})<>'IN_PROGRESS' OR (SELECT count(*) FROM public.alerts WHERE id=ANY(ARRAY[${q(executive)},${q(execMember)}]::uuid[]) AND status='INVESTIGATING')<>2 THEN RAISE EXCEPTION 'Rejection did not reopen exact group';END IF;
 UPDATE public.alerts SET status='PENDING_QA_REVIEW' WHERE id=ANY(ARRAY[${q(qa)},${q(qaMember)}]::uuid[]);
 UPDATE public.investigation_drafts SET status='SUBMITTED',closed_at=NULL WHERE id=${q(qaDraft)};
END $$;
CREATE FUNCTION coreaml_private.review_probe_fault() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.metadata->>'request_id'=${q(faultRequest)} THEN RAISE EXCEPTION 'Isolated review audit fault';END IF;RETURN NEW;END $$;
CREATE TRIGGER review_probe_fault BEFORE INSERT ON public.system_events FOR EACH ROW EXECUTE FUNCTION coreaml_private.review_probe_fault();
DO $$ DECLARE ctx jsonb;v integer;BEGIN
 SELECT revision INTO v FROM public.investigation_drafts WHERE id=${q(qaDraft)};
 ${role(head,'head_of_compliance')}
 ctx:=public.coreaml_load_review('QA',${q(qa)});
 BEGIN PERFORM public.coreaml_review_decision('QA',${q(qa)},ctx->>'token','APPROVE','Audit rollback probe',${q(faultRequest)});RAISE EXCEPTION 'Audit fault failed';EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Isolated review audit fault' THEN RAISE;END IF;END;
 EXECUTE 'RESET ROLE';
 IF EXISTS(SELECT 1 FROM public.coreaml_review_actions WHERE request_id=${q(faultRequest)}) OR (SELECT revision FROM public.investigation_drafts WHERE id=${q(qaDraft)})<>v OR (SELECT count(*) FROM public.alerts WHERE id=ANY(ARRAY[${q(qa)},${q(qaMember)}]::uuid[]) AND status='PENDING_QA_REVIEW')<>2 THEN RAISE EXCEPTION 'Audit failure did not roll back full decision';END IF;
 ${role(head,'head_of_compliance')}
 ctx:=public.coreaml_load_review('QA',${q(qa)});
 PERFORM public.coreaml_review_decision('QA',${q(qa)},ctx->>'token','REJECT','Further evidence required',${q(qaReject)});
 EXECUTE 'RESET ROLE';
 IF (SELECT count(*) FROM public.alerts WHERE id=ANY(ARRAY[${q(qa)},${q(qaMember)}]::uuid[]) AND status='INVESTIGATING')<>2 THEN RAISE EXCEPTION 'QA rejection did not reopen group';END IF;
 IF has_function_privilege('anon','public.coreaml_review_decision(text,uuid,text,text,text,uuid)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous review execution granted';END IF;
 IF EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.suspicious_transaction_reports'::regclass AND tgname='trg_network_contagion' AND tgenabled<>'D') THEN RAISE EXCEPTION 'Unsafe propagation remained enabled';END IF;
END $$;
`;}
module.exports={probeSQL};
