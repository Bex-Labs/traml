'use strict';
const {probeSQL:reviewProbe}=require('./review-install-tools.cjs'),assert=require('node:assert/strict');
const q=v=>"'"+String(v).replace(/'/g,"''")+"'";
function submissionProbes(f){for(const id of Object.values(f))assert(/^[a-f0-9-]{36}$/i.test(id));const {bank,maker,head,other,foreign,qa,qaMember,executive,execMember,qaDraft,execDraft,qaSubmit,execSubmit,qaResubmit,headReject,headApprove,execApprove,submitFault,reportFault,quarantineFault}=f;
let seed=reviewProbe(f).split('DO $$ DECLARE ctx')[0];seed=seed.slice(0,seed.indexOf('INSERT INTO public.suspicious_transaction_reports')).replaceAll("'PENDING_QA_REVIEW'","'INVESTIGATING'").replaceAll("'ESCALATED'","'INVESTIGATING'").replaceAll("'SUBMITTED'","'IN_PROGRESS'");
const role=(id,r,b=bank)=>`PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',${q(id)},'role','authenticated','app_metadata',jsonb_build_object('tenant_id',${q(b)},'role',${q(r)}))::text,true);EXECUTE 'SET LOCAL ROLE authenticated';`;
return seed+`
DO $$ DECLARE a jsonb;b jsonb;c jsonb;report uuid;BEGIN
 ${role(head,'head_of_compliance')}
 BEGIN PERFORM public.coreaml_submit_case_review(${q(qa)},'QA',1,${q(qaSubmit)});RAISE EXCEPTION 'Checker submitted maker case';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(other,'compliance_officer')}
 BEGIN PERFORM public.coreaml_submit_case_review(${q(qa)},'QA',1,${q(qaSubmit)});RAISE EXCEPTION 'Peer submitted another owner case';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(maker,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 BEGIN PERFORM public.coreaml_submit_case_review(${q(qa)},'QA',1,${q(qaSubmit)});RAISE EXCEPTION 'Forged bank accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(maker,'compliance_officer')}
 BEGIN PERFORM public.coreaml_submit_case_review(${q(qa)},'QA',99,${q(qaSubmit)});RAISE EXCEPTION 'Stale saved revision submitted';EXCEPTION WHEN serialization_failure THEN NULL;END;
 a:=public.coreaml_submit_case_review(${q(qa)},'QA',1,${q(qaSubmit)});
 b:=public.coreaml_submit_case_review(${q(qa)},'QA',1,${q(qaSubmit)});
 IF a->>'status'<>'SUBMITTED' OR (a->>'revision')::int<>2 OR a->'report_id'<>'null'::jsonb OR b->>'replayed'<>'true' THEN RAISE EXCEPTION 'QA receipt incorrect';END IF;
 BEGIN PERFORM public.coreaml_submit_case_review(${q(qa)},'EXECUTIVE',1,${q(qaSubmit)});RAISE EXCEPTION 'Changed type replay accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 BEGIN DELETE FROM public.coreaml_review_submissions WHERE request_id=${q(qaSubmit)};RAISE EXCEPTION 'Submission receipt deletion allowed';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 IF jsonb_array_length(public.coreaml_my_review_submissions())<>1 THEN RAISE EXCEPTION 'Maker could not read own submission';END IF;
 EXECUTE 'RESET ROLE';
 IF (SELECT count(*) FROM public.system_events WHERE metadata->>'request_id'=${q(qaSubmit)})<>1 OR (SELECT count(*) FROM public.alerts WHERE id=ANY(ARRAY[${q(qa)},${q(qaMember)}]::uuid[]) AND status='PENDING_QA_REVIEW')<>2 THEN RAISE EXCEPTION 'Submission did not update exact group once';END IF;
 ${role(head,'head_of_compliance')}
 c:=public.coreaml_load_review('QA',${q(qa)});
 IF jsonb_array_length(c->'detections')<>2 THEN RAISE EXCEPTION 'Reviewer received an incomplete detection snapshot';END IF;
 PERFORM public.coreaml_review_decision('QA',${q(qa)},c->>'token','REJECT','Further recorded evidence is required',${q(headReject)});EXECUTE 'RESET ROLE';
 IF (SELECT revision FROM public.investigation_drafts WHERE id=${q(qaDraft)})<>3 THEN RAISE EXCEPTION 'Rejection did not advance saved revision';END IF;
 ${role(maker,'compliance_officer')}
 IF public.coreaml_my_review_submissions()->0->>'reviewer_notes'<>'Further recorded evidence is required' THEN RAISE EXCEPTION 'Maker cannot read returned review feedback';END IF;
 a:=public.coreaml_submit_case_review(${q(qa)},'QA',3,${q(qaResubmit)});
 IF public.coreaml_my_review_submissions()->0->>'reviewer_notes' IS NOT NULL THEN RAISE EXCEPTION 'Previous feedback was presented as a new review';END IF;
 IF jsonb_array_length(public.coreaml_my_review_submissions())<>1 OR public.coreaml_my_review_submissions()->0->>'request_id'<>${q(qaResubmit)} THEN RAISE EXCEPTION 'Latest submission per case is incorrect';END IF;EXECUTE 'RESET ROLE';
 ${role(head,'head_of_compliance')}
 c:=public.coreaml_load_review('QA',${q(qa)});
 PERFORM public.coreaml_review_decision('QA',${q(qa)},c->>'token','APPROVE','Dismissal review confirmed',${q(headApprove)});EXECUTE 'RESET ROLE';
 ${role(maker,'compliance_officer')}
 a:=public.coreaml_submit_case_review(${q(executive)},'EXECUTIVE',1,${q(execSubmit)});report:=(a->>'report_id')::uuid;
 b:=public.coreaml_submit_case_review(${q(executive)},'EXECUTIVE',1,${q(execSubmit)});
 IF b->>'report_id'<>report::text OR b->>'replayed'<>'true' OR a->>'regulatory_submission'<>'false' THEN RAISE EXCEPTION 'Executive replay generated another report';END IF;
 IF (SELECT count(*) FROM public.suspicious_transaction_reports WHERE id=report)<>1 THEN RAISE EXCEPTION 'Maker report read was denied';END IF;EXECUTE 'RESET ROLE';
 ${role(other,'compliance_officer')}
 IF (SELECT count(*) FROM public.suspicious_transaction_reports WHERE id=report)<>0 OR jsonb_array_length(public.coreaml_my_review_submissions())<>0 THEN RAISE EXCEPTION 'Same-bank peer read another maker report';END IF;EXECUTE 'RESET ROLE';
 ${role(foreign,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 IF (SELECT count(*) FROM public.suspicious_transaction_reports WHERE id=report)<>0 OR (SELECT count(*) FROM public.coreaml_review_submissions WHERE request_id=${q(execSubmit)})<>0 THEN RAISE EXCEPTION 'Foreign bank read review data';END IF;EXECUTE 'RESET ROLE';
 ${role(head,'head_of_compliance')}
 c:=public.coreaml_load_review('EXECUTIVE',report);
 PERFORM public.coreaml_review_decision('EXECUTIVE',report,c->>'token','APPROVE','Approved for preparation; no filing',${q(execApprove)});EXECUTE 'RESET ROLE';
 IF (SELECT status FROM public.suspicious_transaction_reports WHERE id=report)<>'APPROVED' OR (SELECT status FROM public.investigation_drafts WHERE id=${q(execDraft)})<>'SUBMITTED' THEN RAISE EXCEPTION 'Approval implied filing or unlocked draft';END IF;
 UPDATE public.alerts SET status='INVESTIGATING' WHERE id=ANY(ARRAY[${q(executive)},${q(execMember)}]::uuid[]);
 UPDATE public.investigation_drafts SET status='IN_PROGRESS',revision=3 WHERE id=${q(execDraft)};
END $$;
CREATE FUNCTION coreaml_private.submission_probe_audit_fault() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.metadata->>'request_id'=${q(submitFault)} THEN RAISE EXCEPTION 'Isolated submission audit fault';END IF;RETURN NEW;END $$;
CREATE TRIGGER submission_probe_audit_fault BEFORE INSERT ON public.system_events FOR EACH ROW EXECUTE FUNCTION coreaml_private.submission_probe_audit_fault();
CREATE FUNCTION coreaml_private.submission_probe_report_fault() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN IF NEW.report_data->>'submission_request_id'=${q(reportFault)} THEN RAISE EXCEPTION 'Isolated submission report fault';END IF;RETURN NEW;END $$;
CREATE TRIGGER submission_probe_report_fault BEFORE INSERT ON public.suspicious_transaction_reports FOR EACH ROW EXECUTE FUNCTION coreaml_private.submission_probe_report_fault();
DO $$ DECLARE n integer;BEGIN
 SELECT count(*) INTO n FROM public.suspicious_transaction_reports;
 ${role(maker,'compliance_officer')}
 BEGIN PERFORM public.coreaml_submit_case_review(${q(executive)},'EXECUTIVE',3,${q(submitFault)});RAISE EXCEPTION 'Audit failure did not occur';EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Isolated submission audit fault' THEN RAISE;END IF;END;
 BEGIN PERFORM public.coreaml_submit_case_review(${q(executive)},'EXECUTIVE',3,${q(reportFault)});RAISE EXCEPTION 'Report failure did not occur';EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'Isolated submission report fault' THEN RAISE;END IF;END;
 EXECUTE 'RESET ROLE';
 IF (SELECT count(*) FROM public.suspicious_transaction_reports)<>n OR EXISTS(SELECT 1 FROM public.coreaml_review_submissions WHERE request_id IN (${q(submitFault)},${q(reportFault)})) OR (SELECT revision FROM public.investigation_drafts WHERE id=${q(execDraft)})<>3 OR (SELECT count(*) FROM public.alerts WHERE id=ANY(ARRAY[${q(executive)},${q(execMember)}]::uuid[]) AND status='INVESTIGATING')<>2 THEN RAISE EXCEPTION 'Failed submission left partial state';END IF;
END $$;
ALTER TABLE public.suspicious_transaction_reports ENABLE TRIGGER trg_network_contagion;
DO $$ BEGIN
 ${role(maker,'compliance_officer')}
 BEGIN PERFORM public.coreaml_submit_case_review(${q(executive)},'EXECUTIVE',3,${q(quarantineFault)});RAISE EXCEPTION 'Unsafe propagation configuration accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 IF (SELECT revision FROM public.investigation_drafts WHERE id=${q(execDraft)})<>3 THEN RAISE EXCEPTION 'Quarantine failure advanced draft';END IF;
END $$;
ALTER TABLE public.suspicious_transaction_reports DISABLE TRIGGER trg_network_contagion;
DO $$ BEGIN
 IF has_function_privilege('anon','public.coreaml_submit_case_review(uuid,text,integer,uuid)','EXECUTE') OR has_table_privilege('authenticated','public.coreaml_review_submissions','INSERT') THEN RAISE EXCEPTION 'Submission API privileges widened';END IF;
END $$;
`;
}
module.exports={submissionProbes};
