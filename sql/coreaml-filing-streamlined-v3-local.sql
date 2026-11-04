-- Single final reporting approval; no existing record is backfilled or reclassified.
ALTER TABLE public.coreaml_filing_drafts DROP CONSTRAINT coreaml_filing_drafts_state_check;
ALTER TABLE public.coreaml_filing_drafts ADD CONSTRAINT coreaml_filing_drafts_state_check CHECK(state IN ('PREPARED','EXPORTED','SUBMISSION_RECORDED','ACKNOWLEDGEMENT_RECORDED','REJECTION_RECORDED','PENDING_FINAL_REVIEW','RETURNED_FOR_PREPARATION','RETURNED_TO_INVESTIGATION','FINAL_APPROVED','OUTCOME_PENDING_CONFIRMATION','REPORTING_COMPLETED'));
CREATE TABLE public.coreaml_reporting_routes (
 report_id uuid PRIMARY KEY REFERENCES public.suspicious_transaction_reports(id),
 tenant_id text NOT NULL,maker_id uuid NOT NULL REFERENCES auth.users(id),
 route text NOT NULL CHECK(route='SINGLE_REVIEW'),created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.coreaml_reporting_routes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_reporting_routes FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.coreaml_prepare_case_report(p_alert_id uuid,p_expected_revision integer,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;ack jsonb;existing public.coreaml_reporting_routes%ROWTYPE;
BEGIN
 staff:=coreaml_private.case_workflow_staff(true);
 IF staff.role<>'compliance_officer' THEN RAISE EXCEPTION 'Assigned preparing officer required' USING ERRCODE='42501';END IF;
 ack:=public.coreaml_submit_case_review(p_alert_id,'EXECUTIVE',p_expected_revision,p_request_id);
 SELECT * INTO existing FROM public.coreaml_reporting_routes WHERE report_id=(ack->>'report_id')::uuid;
 IF NOT FOUND THEN
  IF (ack->>'replayed')::boolean THEN RAISE EXCEPTION 'This request belongs to the early guidance route' USING ERRCODE='22023';END IF;
  INSERT INTO public.coreaml_reporting_routes(report_id,tenant_id,maker_id,route) VALUES((ack->>'report_id')::uuid,staff.tenant_id,staff.id,'SINGLE_REVIEW');
 ELSIF existing.tenant_id<>staff.tenant_id OR existing.maker_id<>staff.id THEN RAISE EXCEPTION 'Reporting route unavailable' USING ERRCODE='42501';END IF;
 RETURN ack||jsonb_build_object('kind','REPORT','route','SINGLE_REVIEW');
END $$;
REVOKE ALL ON FUNCTION public.coreaml_prepare_case_report(uuid,integer,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_prepare_case_report(uuid,integer,uuid) TO authenticated;
CREATE OR REPLACE FUNCTION coreaml_private.reporting_review_context_v3(p_actor uuid,p_kind text,p_target uuid,p_lock boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;c public.coreaml_case_claims%ROWTYPE;a public.alerts%ROWTYPE;d public.investigation_drafts%ROWTYPE;r public.suspicious_transaction_reports%ROWTYPE;rows jsonb;fingerprint jsonb;total integer;pending integer;ids jsonb;
BEGIN
 SELECT * INTO p FROM public.user_profiles WHERE id=p_actor AND is_active IS TRUE AND role='head_of_compliance' FOR SHARE;
 IF NOT FOUND OR nullif(p.tenant_id,'') IS NULL THEN RAISE EXCEPTION 'Independent reporting reviewer required' USING ERRCODE='42501';END IF;
 IF p_kind NOT IN ('QA','EXECUTIVE') OR p_kind IS NULL OR p_target IS NULL THEN RAISE EXCEPTION 'Invalid review target' USING ERRCODE='22023';END IF;
 IF p_kind='EXECUTIVE' THEN
  SELECT * INTO r FROM public.suspicious_transaction_reports WHERE id=p_target AND tenant_id=p.tenant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Review unavailable' USING ERRCODE='42501';END IF;
  SELECT * INTO c FROM public.coreaml_case_claims WHERE tenant_id=p.tenant_id AND r.alert_id=ANY(alert_ids);
 ELSE SELECT * INTO c FROM public.coreaml_case_claims WHERE tenant_id=p.tenant_id AND p_target=ANY(alert_ids);END IF;
 IF NOT FOUND OR c.investigator_id=p.id OR cardinality(c.alert_ids)>2000 THEN RAISE EXCEPTION 'Independent managed case review required' USING ERRCODE='42501';END IF;
 SELECT * INTO a FROM public.alerts WHERE id=c.anchor_alert_id AND tenant_id=p.tenant_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Case anchor unavailable' USING ERRCODE='42501';END IF;
 IF a.customer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.customers WHERE id=a.customer_id AND tenant_id=p.tenant_id) THEN RAISE EXCEPTION 'Case customer unavailable' USING ERRCODE='42501';END IF;
 IF p_lock THEN
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p.tenant_id||':'||coalesce(a.customer_id::text,a.id::text),0));
  SELECT * INTO c FROM public.coreaml_case_claims WHERE id=c.id FOR UPDATE;
  PERFORM id FROM public.alerts WHERE id=ANY(c.alert_ids) ORDER BY id FOR UPDATE;
 END IF;
 SELECT count(*),count(*) FILTER(WHERE status=CASE WHEN p_kind='QA' THEN 'PENDING_QA_REVIEW' ELSE 'ESCALATED' END),jsonb_agg(to_jsonb(x) ORDER BY id)
 INTO total,pending,rows FROM public.alerts x WHERE id=ANY(c.alert_ids) AND tenant_id=p.tenant_id AND assigned_user_id=c.investigator_id AND case_reference=c.case_reference AND customer_id IS NOT DISTINCT FROM a.customer_id;
 IF total<>cardinality(c.alert_ids) OR pending<>total THEN RAISE EXCEPTION 'Case membership or pending state changed' USING ERRCODE='40001';END IF;
 IF p_lock THEN SELECT * INTO d FROM public.investigation_drafts WHERE case_reference=c.case_reference AND investigator_id=c.investigator_id AND tenant_id=p.tenant_id FOR UPDATE;
 ELSE SELECT * INTO d FROM public.investigation_drafts WHERE case_reference=c.case_reference AND investigator_id=c.investigator_id AND tenant_id=p.tenant_id;END IF;
 IF NOT FOUND OR d.status<>'SUBMITTED' OR d.alert_id<>c.anchor_alert_id OR d.revision<1 OR length(btrim(coalesce(d.draft_narrative,'')))<15 THEN RAISE EXCEPTION 'A submitted canonical draft is required' USING ERRCODE='40001';END IF;
 IF p_kind='EXECUTIVE' THEN
  IF p_lock THEN SELECT * INTO r FROM public.suspicious_transaction_reports WHERE id=p_target AND tenant_id=p.tenant_id FOR UPDATE;
  ELSE SELECT * INTO r FROM public.suspicious_transaction_reports WHERE id=p_target AND tenant_id=p.tenant_id;END IF;
  IF NOT FOUND THEN RAISE EXCEPTION 'Report unavailable' USING ERRCODE='42501';END IF;
  SELECT jsonb_agg(v::text ORDER BY v::text) INTO ids FROM unnest(c.alert_ids) v;
  IF r.status<>'PENDING_APPROVAL' OR r.locked_at IS NOT NULL OR r.alert_id<>c.anchor_alert_id
  OR r.generated_by IS DISTINCT FROM c.investigator_id OR (r.created_by IS NOT NULL AND r.created_by<>c.investigator_id)
  OR r.report_data->>'case_reference' IS DISTINCT FROM c.case_reference OR jsonb_typeof(r.report_data->'alert_ids') IS DISTINCT FROM 'array'
  THEN RAISE EXCEPTION 'Report has no confirmed canonical case linkage' USING ERRCODE='40001';END IF;
  IF (SELECT jsonb_agg(v ORDER BY v) FROM jsonb_array_elements(r.report_data->'alert_ids') v) IS DISTINCT FROM ids THEN RAISE EXCEPTION 'Report membership differs from the claimed case' USING ERRCODE='40001';END IF;
  IF pg_column_size(r.report_data)>1048576 THEN RAISE EXCEPTION 'Review snapshot is too large' USING ERRCODE='22023';END IF;
 END IF;
 IF pg_column_size(rows)>2097152 THEN RAISE EXCEPTION 'Recorded detection snapshot exceeds the review display limit' USING ERRCODE='22023';END IF;
 fingerprint:=jsonb_build_object('reviewer_id',p.id,'tenant_id',p.tenant_id,'claim',to_jsonb(c),'alerts',rows,'draft',to_jsonb(d),'report',CASE WHEN p_kind='EXECUTIVE' THEN to_jsonb(r) ELSE NULL END);
 RETURN jsonb_build_object('kind',p_kind,'target_id',p_target,'case_reference',c.case_reference,'alert_ids',c.alert_ids,'maker_id',c.investigator_id,'actor_id',p.id,'tenant_id',p.tenant_id,'draft_id',d.id,'revision',d.revision,
 'token',encode(sha256(convert_to(fingerprint::text,'UTF8')),'hex'),'detections',rows,'narrative',d.draft_narrative,'snapshot',d.evidence_snapshot,'report_data',CASE WHEN p_kind='EXECUTIVE' THEN r.report_data ELSE NULL END);
END $$;
REVOKE ALL ON FUNCTION coreaml_private.reporting_review_context_v3(uuid,text,uuid,boolean) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION coreaml_private.reporting_review_decision_v3(p_actor uuid,p_kind text,p_target_id uuid,p_expected_token text,p_decision text,p_notes text,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;ctx jsonb;old public.coreaml_review_actions%ROWTYPE;ids uuid[];new_status text;result jsonb;changed integer;
BEGIN
 SELECT * INTO p FROM public.user_profiles WHERE id=p_actor AND is_active IS TRUE AND role='head_of_compliance' FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Independent reporting reviewer required' USING ERRCODE='42501';END IF;
 IF p_kind IS NULL OR p_kind NOT IN ('QA','EXECUTIVE') OR p_target_id IS NULL OR p_decision IS NULL OR p_decision NOT IN ('APPROVE','REJECT') OR p_request_id IS NULL
 OR p_expected_token IS NULL OR p_expected_token !~ '^[a-f0-9]{64}$' OR p_notes IS NULL OR length(btrim(p_notes))<3 OR length(p_notes)>10000 THEN RAISE EXCEPTION 'Invalid review decision' USING ERRCODE='22023';END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('review-request:'||p_request_id::text,0));
 SELECT * INTO old FROM public.coreaml_review_actions WHERE request_id=p_request_id;
 IF FOUND THEN
  IF old.actor_id<>p.id OR old.tenant_id<>p.tenant_id THEN RAISE EXCEPTION 'Request unavailable' USING ERRCODE='42501';END IF;
  IF (old.kind,old.target_id,old.expected_token,old.decision,old.notes) IS DISTINCT FROM (p_kind,p_target_id,p_expected_token,p_decision,p_notes) THEN RAISE EXCEPTION 'Request reference reused with different content' USING ERRCODE='22023';END IF;
  RETURN old.result||jsonb_build_object('replayed',true);
 END IF;
 ctx:=coreaml_private.reporting_review_context_v3(p_actor,p_kind,p_target_id,true);
 IF ctx->>'token'<>p_expected_token THEN RAISE EXCEPTION 'Review changed; reload before deciding' USING ERRCODE='40001';END IF;
 SELECT array_agg(v::uuid) INTO ids FROM jsonb_array_elements_text(ctx->'alert_ids') v;
 IF p_kind='QA' OR p_decision='REJECT' THEN
  new_status:=CASE WHEN p_decision='APPROVE' THEN 'CLOSED' ELSE 'INVESTIGATING' END;
  UPDATE public.alerts SET status=new_status,qa_reviewed_by=CASE WHEN p_kind='QA' THEN p.id ELSE qa_reviewed_by END,
   qa_review_notes=CASE WHEN p_kind='QA' THEN p_notes ELSE qa_review_notes END,qa_reviewed_at=CASE WHEN p_kind='QA' THEN clock_timestamp() ELSE qa_reviewed_at END
  WHERE id=ANY(ids) AND tenant_id=p.tenant_id AND case_reference=ctx->>'case_reference' AND assigned_user_id=(ctx->>'maker_id')::uuid;
  GET DIAGNOSTICS changed=ROW_COUNT;IF changed<>cardinality(ids) THEN RAISE EXCEPTION 'Incomplete group decision' USING ERRCODE='40001';END IF;
  UPDATE public.investigation_drafts SET status=CASE WHEN new_status='CLOSED' THEN 'CLOSED' ELSE 'IN_PROGRESS' END,closed_at=CASE WHEN new_status='CLOSED' THEN clock_timestamp() ELSE NULL END,revision=revision+1,updated_at=clock_timestamp() WHERE id=(ctx->>'draft_id')::uuid;
 END IF;
 IF p_kind='EXECUTIVE' THEN
  UPDATE public.suspicious_transaction_reports SET status=CASE WHEN p_decision='APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,executive_justification=p_notes,reviewed_by=p.id,locked_at=clock_timestamp() WHERE id=p_target_id AND tenant_id=p.tenant_id AND status='PENDING_APPROVAL';
  GET DIAGNOSTICS changed=ROW_COUNT;IF changed<>1 THEN RAISE EXCEPTION 'Report state changed' USING ERRCODE='40001';END IF;
 END IF;
 result:=jsonb_build_object('request_id',p_request_id,'kind',p_kind,'target_id',p_target_id,'decision',p_decision,'case_reference',ctx->>'case_reference','alert_ids',ids,'actor_id',p.id,'maker_id',ctx->>'maker_id','replayed',false,'regulatory_submission',false);
 INSERT INTO public.coreaml_review_actions(request_id,kind,target_id,tenant_id,case_reference,actor_id,maker_id,decision,expected_token,notes,result) VALUES(p_request_id,p_kind,p_target_id,p.tenant_id,ctx->>'case_reference',p.id,(ctx->>'maker_id')::uuid,p_decision,p_expected_token,p_notes,result);
 INSERT INTO public.system_events(event_type,severity,message,tenant_id,user_id,metadata) VALUES(CASE WHEN p_kind='QA' THEN 'QA_REVIEW_CONFIRMED' ELSE 'EXECUTIVE_REVIEW_CONFIRMED' END,'INFO','Server-confirmed review decision; no regulatory submission',p.tenant_id::uuid,p.id,jsonb_build_object('request_id',p_request_id,'kind',p_kind,'target_id',p_target_id,'case_reference',ctx->>'case_reference','decision',p_decision,'regulatory_submission',false));
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.reporting_review_decision_v3(uuid,text,uuid,text,text,text,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.coreaml_review_decision(p_kind text,p_target_id uuid,p_expected_token text,p_decision text,p_notes text,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;ctx jsonb;old public.coreaml_review_actions%ROWTYPE;ids uuid[];new_status text;result jsonb;changed integer;
BEGIN
 p:=coreaml_private.review_staff();
 IF p_kind='EXECUTIVE' AND EXISTS(SELECT 1 FROM public.coreaml_reporting_routes WHERE report_id=p_target_id) THEN RAISE EXCEPTION 'Review this complete report in Final report approval' USING ERRCODE='42501';END IF;
 IF p_kind IS NULL OR p_kind NOT IN ('QA','EXECUTIVE') OR p_target_id IS NULL OR p_decision IS NULL OR p_decision NOT IN ('APPROVE','REJECT') OR p_request_id IS NULL
 OR p_expected_token IS NULL OR p_expected_token !~ '^[a-f0-9]{64}$' OR p_notes IS NULL OR length(btrim(p_notes))<3 OR length(p_notes)>10000 THEN RAISE EXCEPTION 'Invalid review decision' USING ERRCODE='22023';END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('review-request:'||p_request_id::text,0));
 SELECT * INTO old FROM public.coreaml_review_actions WHERE request_id=p_request_id;
 IF FOUND THEN
  IF old.actor_id<>p.id OR old.tenant_id<>p.tenant_id THEN RAISE EXCEPTION 'Request unavailable' USING ERRCODE='42501';END IF;
  IF (old.kind,old.target_id,old.expected_token,old.decision,old.notes) IS DISTINCT FROM (p_kind,p_target_id,p_expected_token,p_decision,p_notes) THEN RAISE EXCEPTION 'Request reference reused with different content' USING ERRCODE='22023';END IF;
  RETURN old.result||jsonb_build_object('replayed',true);
 END IF;
 ctx:=coreaml_private.review_context(p_kind,p_target_id,true);
 IF ctx->>'token'<>p_expected_token THEN RAISE EXCEPTION 'Review changed; reload before deciding' USING ERRCODE='40001';END IF;
 SELECT array_agg(v::uuid) INTO ids FROM jsonb_array_elements_text(ctx->'alert_ids') v;
 IF p_kind='QA' OR p_decision='REJECT' THEN
  new_status:=CASE WHEN p_decision='APPROVE' THEN 'CLOSED' ELSE 'INVESTIGATING' END;
  UPDATE public.alerts SET status=new_status,qa_reviewed_by=CASE WHEN p_kind='QA' THEN p.id ELSE qa_reviewed_by END,
   qa_review_notes=CASE WHEN p_kind='QA' THEN p_notes ELSE qa_review_notes END,qa_reviewed_at=CASE WHEN p_kind='QA' THEN clock_timestamp() ELSE qa_reviewed_at END
  WHERE id=ANY(ids) AND tenant_id=p.tenant_id AND case_reference=ctx->>'case_reference' AND assigned_user_id=(ctx->>'maker_id')::uuid;
  GET DIAGNOSTICS changed=ROW_COUNT;IF changed<>cardinality(ids) THEN RAISE EXCEPTION 'Incomplete group decision' USING ERRCODE='40001';END IF;
  UPDATE public.investigation_drafts SET status=CASE WHEN new_status='CLOSED' THEN 'CLOSED' ELSE 'IN_PROGRESS' END,closed_at=CASE WHEN new_status='CLOSED' THEN clock_timestamp() ELSE NULL END,revision=revision+1,updated_at=clock_timestamp() WHERE id=(ctx->>'draft_id')::uuid;
 END IF;
 IF p_kind='EXECUTIVE' THEN
  UPDATE public.suspicious_transaction_reports SET status=CASE WHEN p_decision='APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END,executive_justification=p_notes,reviewed_by=p.id,locked_at=clock_timestamp() WHERE id=p_target_id AND tenant_id=p.tenant_id AND status='PENDING_APPROVAL';
  GET DIAGNOSTICS changed=ROW_COUNT;IF changed<>1 THEN RAISE EXCEPTION 'Report state changed' USING ERRCODE='40001';END IF;
 END IF;
 result:=jsonb_build_object('request_id',p_request_id,'kind',p_kind,'target_id',p_target_id,'decision',p_decision,'case_reference',ctx->>'case_reference','alert_ids',ids,'actor_id',p.id,'maker_id',ctx->>'maker_id','replayed',false,'regulatory_submission',false);
 INSERT INTO public.coreaml_review_actions(request_id,kind,target_id,tenant_id,case_reference,actor_id,maker_id,decision,expected_token,notes,result) VALUES(p_request_id,p_kind,p_target_id,p.tenant_id,ctx->>'case_reference',p.id,(ctx->>'maker_id')::uuid,p_decision,p_expected_token,p_notes,result);
 INSERT INTO public.system_events(event_type,severity,message,tenant_id,user_id,metadata) VALUES(CASE WHEN p_kind='QA' THEN 'QA_REVIEW_CONFIRMED' ELSE 'EXECUTIVE_REVIEW_CONFIRMED' END,'INFO','Server-confirmed review decision; no regulatory submission',p.tenant_id::uuid,p.id,jsonb_build_object('request_id',p_request_id,'kind',p_kind,'target_id',p_target_id,'case_reference',ctx->>'case_reference','decision',p_decision,'regulatory_submission',false));
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION coreaml_private.filing_context(p_actor uuid,p_report uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;r public.suspicious_transaction_reports%ROWTYPE;c public.coreaml_case_claims%ROWTYPE;s public.coreaml_review_submissions%ROWTYPE;receipt public.coreaml_review_actions%ROWTYPE;source jsonb;txs jsonb;refs text[];linked integer;
BEGIN
 SELECT * INTO staff FROM public.user_profiles WHERE id=p_actor AND is_active IS TRUE AND role IN ('head_of_compliance','compliance_officer');
 IF NOT FOUND OR nullif(staff.tenant_id,'') IS NULL THEN RAISE EXCEPTION 'Active reporting staff required' USING ERRCODE='42501';END IF;
 SELECT * INTO r FROM public.suspicious_transaction_reports WHERE id=p_report AND tenant_id=staff.tenant_id AND ((status='APPROVED' AND locked_at IS NOT NULL AND reviewed_by IS NOT NULL) OR (status='PENDING_APPROVAL' AND locked_at IS NULL AND reviewed_by IS NULL AND EXISTS(SELECT 1 FROM public.coreaml_reporting_routes route WHERE route.report_id=p_report AND route.tenant_id=staff.tenant_id AND route.maker_id=generated_by)));
 IF NOT FOUND THEN RAISE EXCEPTION 'Approved report unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO c FROM public.coreaml_case_claims WHERE anchor_alert_id=r.alert_id AND tenant_id=r.tenant_id AND investigator_id=r.generated_by AND case_reference=r.report_data->>'case_reference';
 IF NOT FOUND THEN RAISE EXCEPTION 'Approved case linkage unavailable' USING ERRCODE='42501';END IF;
 IF staff.role='compliance_officer' AND c.investigator_id<>staff.id THEN RAISE EXCEPTION 'Only the assigned officer may access this preparation' USING ERRCODE='42501';END IF;
 IF r.report_data->>'purpose' IS DISTINCT FROM 'EXECUTIVE_REVIEW_NOT_FILING' OR jsonb_typeof(r.report_data->'alert_ids') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Unconfirmed approved package' USING ERRCODE='40001';END IF;
 IF (SELECT jsonb_agg(v ORDER BY v) FROM jsonb_array_elements(r.report_data->'alert_ids') v) IS DISTINCT FROM (SELECT jsonb_agg(to_jsonb(x::text) ORDER BY x::text) FROM unnest(c.alert_ids) x) THEN RAISE EXCEPTION 'Approved membership changed' USING ERRCODE='40001';END IF;
 SELECT count(*) INTO linked FROM public.alerts WHERE id=ANY(c.alert_ids) AND tenant_id=r.tenant_id AND case_reference=c.case_reference AND assigned_user_id=c.investigator_id;
 IF linked<>cardinality(c.alert_ids) THEN RAISE EXCEPTION 'Incomplete approved case' USING ERRCODE='40001';END IF;
 SELECT * INTO s FROM public.coreaml_review_submissions WHERE request_id::text=r.report_data->>'submission_request_id' AND tenant_id=r.tenant_id AND kind='EXECUTIVE' AND actor_id=c.investigator_id AND case_reference=c.case_reference AND result->>'report_id'=r.id::text;
 IF NOT FOUND OR s.snapshot->>'narrative' IS DISTINCT FROM r.investigator_notes OR s.snapshot->'evidence_snapshot' IS DISTINCT FROM r.report_data->'evidence_snapshot' THEN RAISE EXCEPTION 'Sealed submission differs from approved report' USING ERRCODE='40001';END IF;
 IF r.status='APPROVED' THEN
 SELECT * INTO receipt FROM public.coreaml_review_actions WHERE target_id=r.id AND tenant_id=r.tenant_id AND kind='EXECUTIVE' AND decision='APPROVE' AND actor_id=r.reviewed_by ORDER BY created_at DESC LIMIT 1;
 IF NOT FOUND OR receipt.case_reference<>c.case_reference OR receipt.maker_id<>c.investigator_id OR receipt.notes IS DISTINCT FROM r.executive_justification THEN RAISE EXCEPTION 'Approval receipt unavailable' USING ERRCODE='40001';END IF;
 ELSE
  IF NOT EXISTS(SELECT 1 FROM public.investigation_drafts d WHERE d.id::text=r.report_data->>'draft_id' AND d.alert_id=c.anchor_alert_id AND d.investigator_id=c.investigator_id AND d.tenant_id=c.tenant_id AND d.case_reference=c.case_reference AND d.status='SUBMITTED' AND d.revision::text=r.report_data->>'draft_revision' AND d.draft_narrative=s.snapshot->>'narrative' AND d.evidence_snapshot=s.snapshot->'evidence_snapshot') OR EXISTS(SELECT 1 FROM public.alerts WHERE id=ANY(c.alert_ids) AND status<>'ESCALATED') THEN RAISE EXCEPTION 'Sealed investigation changed' USING ERRCODE='40001';END IF;
 END IF;
 IF jsonb_typeof(s.snapshot->'evidence_snapshot'->'txs') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Saved transaction references unavailable' USING ERRCODE='40001';END IF;
 SELECT array_agg(DISTINCT value) INTO refs FROM jsonb_array_elements_text(s.snapshot->'evidence_snapshot'->'txs');
 IF coalesce(cardinality(refs),0)>500 THEN RAISE EXCEPTION 'Report exceeds transaction limit' USING ERRCODE='22023';END IF;
 IF EXISTS(SELECT 1 FROM unnest(refs) ref WHERE (SELECT count(*) FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id JOIN public.customers cu ON cu.id=a.customer_id WHERE t.transaction_reference=ref AND cu.tenant_id=r.tenant_id)<>1) THEN RAISE EXCEPTION 'Pinned transaction is missing, ambiguous or outside bank scope' USING ERRCODE='40001';END IF;
 IF EXISTS(SELECT 1 FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND a.transaction_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.transactions t WHERE t.id=a.transaction_id AND t.transaction_reference=ANY(coalesce(refs,ARRAY[]::text[])))) THEN RAISE EXCEPTION 'A detected transaction is absent from submitted evidence pins' USING ERRCODE='40001';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',t.id,'reference',t.transaction_reference,'amount',t.amount::text,'currency',t.currency,'timestamp',t.transaction_timestamp,'direction',t.transaction_type,'channel',t.channel,'narration',t.narration,'account_number',a.account_number,'counterparty_name',t.counterparty_name,'counterparty_account',t.counterparty_account,'counterparty_bank',t.counterparty_bank) ORDER BY t.transaction_reference),'[]') INTO txs FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id JOIN public.customers cu ON cu.id=a.customer_id WHERE t.transaction_reference=ANY(coalesce(refs,ARRAY[]::text[])) AND cu.tenant_id=r.tenant_id;
 source:=jsonb_build_object('report_id',r.id,'tenant_id',r.tenant_id,'alert_id',r.alert_id,'case_reference',c.case_reference,'owner_id',c.investigator_id,'approved_by',r.reviewed_by,'approved_at',r.locked_at,'approval_request_id',receipt.request_id,'approval_notes',r.executive_justification,'submission_request_id',s.request_id,'narrative',s.snapshot->>'narrative','pins',s.snapshot->'evidence_snapshot','transactions',txs,
 'subject',(SELECT jsonb_build_object('name',coalesce(nullif(cu.entity_name,''),nullif(concat_ws(' ',cu.first_name,cu.last_name),''),'Name not recorded'),'customer_type',cu.customer_type) FROM public.alerts a JOIN public.customers cu ON cu.id=a.customer_id AND cu.tenant_id=r.tenant_id WHERE a.id=r.alert_id),
 'synthetic',EXISTS(SELECT 1 FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND (coalesce(a.evidence::text,'') ~* '(SYNTHETIC|FICTIONAL|DEMO)' OR coalesce(a.alert_ref,'') LIKE 'DEMO-%')));
 IF pg_column_size(source)>2097152 THEN RAISE EXCEPTION 'Reporting source exceeds display limit' USING ERRCODE='22023';END IF;
 RETURN jsonb_build_object('report_status',r.status,'report_route',(SELECT route FROM public.coreaml_reporting_routes WHERE report_id=r.id),'source',source,'source_hash',encode(sha256(convert_to(source::text,'UTF8')),'hex'));
END $$;
CREATE OR REPLACE FUNCTION public.coreaml_filing_commit(p_actor uuid,p_report_id uuid,p_request_id uuid,p_action text,p_revision integer,p_source_hash text,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;ctx jsonb;d public.coreaml_filing_drafts%ROWTYPE;prior public.coreaml_filing_events%ROWTYPE;submitted public.coreaml_filing_events%ROWTYPE;final_review public.coreaml_filing_events%ROWTYPE;outcome public.coreaml_filing_events%ROWTYPE;fingerprint text;xml_hash text;result jsonb;ev jsonb;new_state text;notes text;
BEGIN
 IF p_actor IS NULL OR p_report_id IS NULL OR p_request_id IS NULL OR p_action IS NULL OR p_action NOT IN ('SAVE','EXPORT','SUBMISSION','ACKNOWLEDGEMENT','REJECTION','SUBMIT_REPORT','APPROVE_REPORT','RETURN_REPORT','CONFIRM_OUTCOME') OR p_revision IS NULL OR p_revision<0 OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR pg_column_size(p_payload)>2097152 THEN RAISE EXCEPTION 'Invalid reporting operation' USING ERRCODE='22023';END IF;
 ctx:=coreaml_private.filing_context(p_actor,p_report_id);
 SELECT * INTO staff FROM public.user_profiles WHERE id=p_actor;
 PERFORM pg_advisory_xact_lock(hashtextextended('filing-request:'||p_request_id::text,0));
 fingerprint:=encode(sha256(convert_to(jsonb_build_object('actor',p_actor,'report',p_report_id,'action',p_action,'revision',p_revision,'source_hash',p_source_hash,'payload',p_payload)::text,'UTF8')),'hex');
 SELECT * INTO prior FROM public.coreaml_filing_events WHERE request_id=p_request_id;
 IF FOUND THEN IF prior.actor_id<>p_actor OR prior.report_id<>p_report_id OR prior.input_hash<>fingerprint THEN RAISE EXCEPTION 'Request ID reused for different content' USING ERRCODE='22023';END IF;RETURN prior.result||jsonb_build_object('replayed',true);END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('filing-report:'||p_report_id::text,0));
 ctx:=coreaml_private.filing_context(p_actor,p_report_id);
 IF p_source_hash IS DISTINCT FROM ctx->>'source_hash' THEN RAISE EXCEPTION 'Approved source changed; reload this report' USING ERRCODE='40001';END IF;
 SELECT * INTO d FROM public.coreaml_filing_drafts WHERE report_id=p_report_id FOR UPDATE;
 IF coalesce(d.revision,0)<>p_revision THEN RAISE EXCEPTION 'Reporting revision conflict; reload this report' USING ERRCODE='40001';END IF;
 IF p_action IN ('SAVE','SUBMIT_REPORT') THEN
  IF staff.role<>'compliance_officer' OR p_actor::text<>ctx->'source'->>'owner_id' THEN RAISE EXCEPTION 'Only the assigned compliance officer may prepare or record external responses' USING ERRCODE='42501';END IF;
 ELSIF p_action IN ('APPROVE_REPORT','RETURN_REPORT','CONFIRM_OUTCOME') THEN
  IF staff.role<>'head_of_compliance' THEN RAISE EXCEPTION 'Independent Head of Compliance action required' USING ERRCODE='42501';END IF;
 END IF;
 xml_hash:=CASE WHEN d.report_id IS NULL THEN NULL ELSE encode(sha256(convert_to(d.xml_content,'UTF8')),'hex') END;
 IF p_action='SAVE' THEN
  IF d.state IS NOT NULL AND d.state NOT IN ('PREPARED','RETURNED_FOR_PREPARATION','FINAL_APPROVED','EXPORTED','REJECTION_RECORDED') THEN RAISE EXCEPTION 'This version is frozen; use its review or response handoff' USING ERRCODE='40001';END IF;
  result:=coreaml_private.filing_commit_v1(p_actor,p_report_id,p_request_id,p_action,p_revision,p_source_hash,p_payload);
  UPDATE public.coreaml_filing_drafts SET prepared_by=p_actor,submitted_request_id=NULL,final_review_request_id=NULL,pending_outcome_id=NULL WHERE report_id=p_report_id;
  UPDATE public.coreaml_filing_events SET evidence=evidence||jsonb_build_object('prepared_by',p_actor,'approval_invalidated',d.final_review_request_id IS NOT NULL) WHERE request_id=p_request_id;
  RETURN result;
 END IF;
 IF d.report_id IS NULL THEN RAISE EXCEPTION 'The assigned officer must save a reporting preparation first' USING ERRCODE='40001';END IF;
 IF p_action IN ('SUBMIT_REPORT','APPROVE_REPORT','EXPORT','SUBMISSION') AND d.source_hash<>p_source_hash THEN RAISE EXCEPTION 'Preparation source changed; return it to the officer' USING ERRCODE='40001';END IF;
 IF p_action IN ('SUBMIT_REPORT','APPROVE_REPORT','EXPORT') THEN
  IF p_payload->>'xml_hash' IS DISTINCT FROM xml_hash OR p_payload->>'schema_hash' IS NULL OR p_payload->>'schema_hash' !~ '^[a-f0-9]{64}$' OR length(coalesce(p_payload->>'schema_label','')) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Validated XML and schema do not match the saved version' USING ERRCODE='40001';END IF;
 END IF;
 IF p_action='SUBMIT_REPORT' THEN
  IF d.prepared_by IS DISTINCT FROM p_actor OR d.state NOT IN ('PREPARED','RETURNED_FOR_PREPARATION','REJECTION_RECORDED') THEN RAISE EXCEPTION 'Save your preparation revision before submitting it for final review' USING ERRCODE='40001';END IF;
  new_state:='PENDING_FINAL_REVIEW';
  ev:=jsonb_build_object('xml_hash',xml_hash,'source_hash',p_source_hash,'schema_hash',p_payload->>'schema_hash','schema_label',p_payload->>'schema_label','mode',d.mode,'report_type',d.report_type,'reference',d.reference);
  UPDATE public.coreaml_filing_drafts SET submitted_request_id=p_request_id,final_review_request_id=NULL WHERE report_id=p_report_id;
 ELSIF p_action='APPROVE_REPORT' THEN
  IF d.state<>'PENDING_FINAL_REVIEW' OR d.prepared_by IS NULL OR d.prepared_by=p_actor THEN RAISE EXCEPTION 'A different officer must prepare and submit this version' USING ERRCODE='42501';END IF;
  SELECT * INTO submitted FROM public.coreaml_filing_events WHERE request_id=d.submitted_request_id AND report_id=p_report_id AND tenant_id=d.tenant_id AND action='SUBMIT_REPORT' AND revision=d.revision AND actor_id=d.prepared_by;
  IF NOT FOUND OR submitted.evidence->>'xml_hash' IS DISTINCT FROM xml_hash OR submitted.evidence->>'source_hash' IS DISTINCT FROM p_source_hash OR submitted.evidence->>'schema_hash' IS DISTINCT FROM p_payload->>'schema_hash' THEN RAISE EXCEPTION 'The submitted version or schema changed; return it for preparation' USING ERRCODE='40001';END IF;
  notes:=btrim(coalesce(p_payload->>'notes',''));IF length(notes)<3 OR length(notes)>10000 THEN RAISE EXCEPTION 'Enter a final review decision note' USING ERRCODE='22023';END IF;
  IF ctx->>'report_status'='PENDING_APPROVAL' THEN
   PERFORM coreaml_private.reporting_review_decision_v3(p_actor,'EXECUTIVE',p_report_id,(coreaml_private.reporting_review_context_v3(p_actor,'EXECUTIVE',p_report_id,true)->>'token'),'APPROVE',notes,p_request_id);
   ctx:=coreaml_private.filing_context(p_actor,p_report_id);
   UPDATE public.coreaml_filing_drafts SET source_hash=ctx->>'source_hash',source_snapshot=ctx->'source' WHERE report_id=p_report_id;
  END IF;
  new_state:='FINAL_APPROVED';ev:=submitted.evidence||jsonb_build_object('reviewed_source_hash',p_source_hash,'source_hash',ctx->>'source_hash','combined_investigation_approval',ctx->>'report_route'='SINGLE_REVIEW')||jsonb_build_object('notes',notes,'reviewed_by',p_actor,'prepared_by',d.prepared_by,'submission_request_id',submitted.request_id);
  UPDATE public.coreaml_filing_drafts SET final_review_request_id=p_request_id WHERE report_id=p_report_id;
 ELSIF p_action='RETURN_REPORT' THEN
  IF d.state NOT IN ('PENDING_FINAL_REVIEW','FINAL_APPROVED','EXPORTED') THEN RAISE EXCEPTION 'This version is not available for an internal return' USING ERRCODE='40001';END IF;
  notes:=btrim(coalesce(p_payload->>'notes',''));IF length(notes)<3 OR length(notes)>10000 THEN RAISE EXCEPTION 'Enter feedback for the preparing officer' USING ERRCODE='22023';END IF;
  IF p_payload->>'return_scope'='INVESTIGATION' THEN
   IF ctx->>'report_route' IS DISTINCT FROM 'SINGLE_REVIEW' OR ctx->>'report_status'<>'PENDING_APPROVAL' OR d.state<>'PENDING_FINAL_REVIEW' THEN RAISE EXCEPTION 'Only an unapproved complete package may return to investigation' USING ERRCODE='40001';END IF;
   PERFORM coreaml_private.reporting_review_decision_v3(p_actor,'EXECUTIVE',p_report_id,(coreaml_private.reporting_review_context_v3(p_actor,'EXECUTIVE',p_report_id,true)->>'token'),'REJECT',notes,p_request_id);
   new_state:='RETURNED_TO_INVESTIGATION';
  ELSE new_state:='RETURNED_FOR_PREPARATION';END IF;
  ev:=jsonb_build_object('notes',notes,'mode',d.mode,'xml_hash',xml_hash,'prepared_by',d.prepared_by,'external_rejection',false,'return_scope',coalesce(p_payload->>'return_scope','REPORT'));
  UPDATE public.coreaml_filing_drafts SET final_review_request_id=NULL,submitted_request_id=NULL WHERE report_id=p_report_id;
 ELSIF p_action IN ('EXPORT','SUBMISSION') THEN
  SELECT * INTO final_review FROM public.coreaml_filing_events WHERE request_id=d.final_review_request_id AND report_id=p_report_id AND tenant_id=d.tenant_id AND action='APPROVE_REPORT' AND revision=d.revision AND actor_id<>d.prepared_by;
  IF NOT FOUND OR d.prepared_by IS NULL OR final_review.evidence->>'xml_hash' IS DISTINCT FROM xml_hash OR final_review.evidence->>'source_hash' IS DISTINCT FROM p_source_hash THEN RAISE EXCEPTION 'Final approval for this exact report version is required' USING ERRCODE='42501';END IF;
  IF p_action='EXPORT' THEN
   IF d.state NOT IN ('FINAL_APPROVED','EXPORTED') OR final_review.evidence->>'schema_hash' IS DISTINCT FROM p_payload->>'schema_hash' THEN RAISE EXCEPTION 'Current schema/version has no matching final approval' USING ERRCODE='40001';END IF;
   IF d.state='FINAL_APPROVED' THEN UPDATE public.coreaml_filing_drafts SET state='PREPARED' WHERE report_id=p_report_id;END IF;
  ELSE
   IF d.state<>'EXPORTED' THEN RAISE EXCEPTION 'Export the approved report version before recording submission' USING ERRCODE='40001';END IF;
  END IF;
  result:=coreaml_private.filing_commit_v1(p_actor,p_report_id,p_request_id,p_action,p_revision,p_source_hash,p_payload);
  UPDATE public.coreaml_filing_events SET evidence=evidence||jsonb_build_object('final_approval_request_id',d.final_review_request_id,'prepared_by',d.prepared_by) WHERE request_id=p_request_id;
  RETURN result;
 ELSIF p_action IN ('ACKNOWLEDGEMENT','REJECTION') THEN
  IF d.state<>'SUBMISSION_RECORDED' THEN RAISE EXCEPTION 'Record the actual goAML/NFIU response against a submitted version' USING ERRCODE='40001';END IF;
  result:=coreaml_private.filing_commit_v1(p_actor,p_report_id,p_request_id,p_action,p_revision,p_source_hash,p_payload);
  new_state:=CASE WHEN p_action='REJECTION' THEN 'REJECTION_RECORDED' ELSE 'REPORTING_COMPLETED' END;result:=result||jsonb_build_object('state',new_state);
  UPDATE public.coreaml_filing_drafts SET state=new_state,pending_outcome_id=NULL,final_review_request_id=CASE WHEN p_action='REJECTION' THEN NULL ELSE final_review_request_id END WHERE report_id=p_report_id;
  UPDATE public.coreaml_filing_events e SET result=e.result||jsonb_build_object('state',new_state),evidence=e.evidence||jsonb_build_object('case_closure_required',p_action='ACKNOWLEDGEMENT','routine_confirmation_required',false)||jsonb_build_object('entry_source','AUTHORIZED_USER_MANUAL_ENTRY','externally_verified',false,'external_response',true) WHERE request_id=p_request_id;
  RETURN result;
 ELSE
  IF d.state<>'OUTCOME_PENDING_CONFIRMATION' THEN RAISE EXCEPTION 'An officer-recorded external response is required' USING ERRCODE='40001';END IF;
  SELECT * INTO outcome FROM public.coreaml_filing_events WHERE request_id=d.pending_outcome_id AND report_id=p_report_id AND tenant_id=d.tenant_id AND revision=d.revision AND action IN ('ACKNOWLEDGEMENT','REJECTION') AND actor_id<>p_actor;
  IF NOT FOUND OR outcome.actor_id::text<>ctx->'source'->>'owner_id' OR p_payload->>'outcome_id' IS DISTINCT FROM outcome.request_id::text THEN RAISE EXCEPTION 'Confirm the exact officer-recorded response' USING ERRCODE='42501';END IF;
  notes:=btrim(coalesce(p_payload->>'notes',''));IF length(notes)<3 OR length(notes)>10000 THEN RAISE EXCEPTION 'Enter an outcome confirmation note' USING ERRCODE='22023';END IF;
  new_state:=CASE WHEN outcome.action='REJECTION' THEN 'REJECTION_RECORDED' ELSE 'REPORTING_COMPLETED' END;
  ev:=jsonb_build_object('mode',d.mode,'notes',notes,'outcome_id',outcome.request_id,'response_kind',outcome.action,'confirmed_by',p_actor,'recorded_by',outcome.actor_id,'entry_source','LEGACY_RESPONSE_RESOLUTION','externally_verified',false,'case_closure_required',new_state='REPORTING_COMPLETED');
  UPDATE public.coreaml_filing_drafts SET pending_outcome_id=NULL,final_review_request_id=CASE WHEN outcome.action='REJECTION' THEN NULL ELSE final_review_request_id END WHERE report_id=p_report_id;
 END IF;
 UPDATE public.coreaml_filing_drafts SET state=new_state,updated_by=p_actor,updated_at=clock_timestamp() WHERE report_id=p_report_id;
 result:=jsonb_build_object('request_id',p_request_id,'report_id',p_report_id,'actor_id',p_actor,'tenant_id',d.tenant_id,'revision',d.revision,'state',new_state,'action',p_action,'replayed',false,'externally_verified',false);
 ev:=ev||jsonb_build_object('client_request_hash',p_payload->>'client_request_hash');
 INSERT INTO public.coreaml_filing_events(request_id,report_id,tenant_id,actor_id,action,revision,input_hash,result,evidence) VALUES(p_request_id,p_report_id,d.tenant_id,p_actor,p_action,d.revision,fingerprint,result,ev);
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.coreaml_filing_read_v2(p_report_id uuid DEFAULT NULL,p_offset integer DEFAULT 0,p_case_reference text DEFAULT NULL,p_queue text DEFAULT 'ALL') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;ctx jsonb;rows jsonb;total integer;events jsonb;draft public.coreaml_filing_drafts%ROWTYPE;
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF staff.role NOT IN ('compliance_officer','head_of_compliance') THEN RAISE EXCEPTION 'Authorized reporting role required' USING ERRCODE='42501';END IF;
 IF p_offset IS NULL OR p_offset<0 OR p_offset>1000000 OR p_queue IS NULL OR p_queue NOT IN ('ALL','PREPARATION','FINAL_REVIEW','FILING','OUTCOMES','COMPLETED') THEN RAISE EXCEPTION 'Invalid reporting page' USING ERRCODE='22023';END IF;
 IF p_case_reference IS NOT NULL THEN
  IF p_report_id IS NOT NULL OR length(p_case_reference)>200 OR p_case_reference NOT LIKE 'CASE-%' THEN RAISE EXCEPTION 'Invalid case reference' USING ERRCODE='22023';END IF;
  SELECT id INTO p_report_id FROM public.suspicious_transaction_reports WHERE tenant_id=staff.tenant_id AND (status='APPROVED' OR (status='PENDING_APPROVAL' AND EXISTS(SELECT 1 FROM public.coreaml_reporting_routes route WHERE route.report_id=suspicious_transaction_reports.id AND route.tenant_id=staff.tenant_id))) AND (staff.role='head_of_compliance' OR generated_by=staff.id) AND report_data->>'case_reference'=p_case_reference ORDER BY coalesce(locked_at,created_at) DESC,id LIMIT 1;
  IF p_report_id IS NULL THEN RAISE EXCEPTION 'Approved case unavailable' USING ERRCODE='42501';END IF;
 END IF;
 IF p_report_id IS NULL THEN
  WITH scoped AS (SELECT r.*,f.state,f.mode,f.revision,coalesce(cu.entity_name,nullif(concat_ws(' ',cu.first_name,cu.last_name),''),'Name not recorded') AS entity_name FROM public.suspicious_transaction_reports r LEFT JOIN public.coreaml_filing_drafts f ON f.report_id=r.id AND f.tenant_id=r.tenant_id LEFT JOIN public.alerts a ON a.id=r.alert_id AND a.tenant_id=r.tenant_id LEFT JOIN public.customers cu ON cu.id=a.customer_id AND cu.tenant_id=r.tenant_id WHERE r.tenant_id=staff.tenant_id AND (r.status='APPROVED' OR (r.status='PENDING_APPROVAL' AND EXISTS(SELECT 1 FROM public.coreaml_reporting_routes route WHERE route.report_id=r.id AND route.tenant_id=staff.tenant_id))) AND (staff.role='head_of_compliance' OR r.generated_by=staff.id)),
  filtered AS (SELECT * FROM scoped WHERE p_queue='ALL' OR (p_queue='PREPARATION' AND (state IS NULL OR state IN ('PREPARED','RETURNED_FOR_PREPARATION','REJECTION_RECORDED'))) OR (p_queue='FINAL_REVIEW' AND state='PENDING_FINAL_REVIEW') OR (p_queue='FILING' AND state IN ('FINAL_APPROVED','EXPORTED','SUBMISSION_RECORDED')) OR (p_queue='OUTCOMES' AND state IN ('SUBMISSION_RECORDED','OUTCOME_PENDING_CONFIRMATION','ACKNOWLEDGEMENT_RECORDED')) OR (p_queue='COMPLETED' AND state='REPORTING_COMPLETED')),
  page AS (SELECT id,report_data->>'case_reference' AS case_reference,locked_at AS approved_at,created_at AS sealed_at,status AS report_status,entity_name,state,mode,revision FROM filtered ORDER BY coalesce(locked_at,created_at) DESC,id LIMIT 25 OFFSET p_offset)
  SELECT (SELECT count(*) FROM filtered),coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY coalesce(approved_at,sealed_at) DESC,id) FROM page),'[]') INTO total,rows;
  RETURN jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'role',staff.role,'rows',rows,'total',total,'offset',p_offset,'limit',25,'queue',p_queue,'as_of',transaction_timestamp());
 END IF;
 ctx:=coreaml_private.filing_context(staff.id,p_report_id);
 SELECT * INTO draft FROM public.coreaml_filing_drafts WHERE report_id=p_report_id AND tenant_id=staff.tenant_id;
 SELECT coalesce(jsonb_agg(jsonb_build_object('request_id',e.request_id,'actor_id',e.actor_id,'actor_name',(SELECT full_name FROM public.user_profiles p WHERE p.id=e.actor_id AND p.tenant_id=e.tenant_id),'action',e.action,'revision',e.revision,'at',e.created_at,'evidence',e.evidence) ORDER BY e.created_at DESC),'[]') INTO events FROM (SELECT * FROM public.coreaml_filing_events WHERE report_id=p_report_id AND tenant_id=staff.tenant_id ORDER BY created_at DESC LIMIT 101) e;
 IF jsonb_array_length(events)>100 THEN RAISE EXCEPTION 'Reporting history exceeds the 100-entry display limit' USING ERRCODE='22023';END IF;
 RETURN ctx||jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'role',staff.role,'owner_name',(SELECT full_name FROM public.user_profiles p WHERE p.id=(ctx->'source'->>'owner_id')::uuid AND p.tenant_id=staff.tenant_id),'preparer_name',(SELECT full_name FROM public.user_profiles p WHERE p.id=draft.prepared_by AND p.tenant_id=staff.tenant_id),'draft',CASE WHEN draft.report_id IS NULL THEN NULL ELSE to_jsonb(draft)-'source_snapshot' END,'events',events,'as_of',transaction_timestamp());
END $$;
CREATE OR REPLACE FUNCTION public.coreaml_filing_progress(p_case_references text[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;rows jsonb;
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF staff.role NOT IN ('head_of_compliance','compliance_officer') THEN RAISE EXCEPTION 'Reporting access required' USING ERRCODE='42501';END IF;
 IF p_case_references IS NULL OR cardinality(p_case_references)>50 OR EXISTS(SELECT 1 FROM unnest(p_case_references) x WHERE x IS NULL OR length(x)>200 OR x NOT LIKE 'CASE-%') THEN RAISE EXCEPTION 'Invalid case progress request' USING ERRCODE='22023';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.case_reference),'[]') INTO rows FROM (SELECT DISTINCT ON (r.report_data->>'case_reference') r.report_data->>'case_reference' AS case_reference,f.state,f.mode,f.revision,(SELECT route FROM public.coreaml_reporting_routes WHERE report_id=r.id) AS route FROM public.suspicious_transaction_reports r LEFT JOIN public.coreaml_filing_drafts f ON f.report_id=r.id AND f.tenant_id=r.tenant_id WHERE r.tenant_id=staff.tenant_id AND (r.status='APPROVED' OR (r.status='PENDING_APPROVAL' AND EXISTS(SELECT 1 FROM public.coreaml_reporting_routes route WHERE route.report_id=r.id AND route.tenant_id=staff.tenant_id))) AND (staff.role='head_of_compliance' OR r.generated_by=staff.id) AND r.report_data->>'case_reference'=ANY(p_case_references) ORDER BY r.report_data->>'case_reference',coalesce(r.locked_at,r.created_at) DESC,r.id) x;
 RETURN jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'rows',rows);
END $$;
CREATE OR REPLACE FUNCTION public.coreaml_case_worklist_priority(p_kind text DEFAULT 'CASES',p_search text DEFAULT '',p_status text DEFAULT 'ALL',p_owner text DEFAULT 'ALL',p_from timestamptz DEFAULT NULL,p_until timestamptz DEFAULT NULL,p_offset integer DEFAULT 0,p_limit integer DEFAULT 25,p_sort text DEFAULT 'NEWEST',p_severity text DEFAULT 'ALL',p_min_hours integer DEFAULT 0,p_waiting_only boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;result jsonb;pattern text;as_of timestamptz:=transaction_timestamp();
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF p_kind IS NULL OR p_kind NOT IN ('CASES','QA','EXECUTIVE') OR p_search IS NULL OR length(p_search)>120 OR p_status IS NULL OR p_status NOT IN ('ALL','INVESTIGATING','PENDING_QA_REVIEW','ESCALATED','CLOSED','MIXED') OR p_owner IS NULL OR p_owner NOT IN ('ALL','MINE') OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 OR p_limit IS NULL OR p_limit<1 OR p_limit>50 OR (p_from IS NOT NULL AND p_until IS NOT NULL AND p_from>=p_until) THEN RAISE EXCEPTION 'Invalid worklist filters' USING ERRCODE='22023';END IF;
 IF p_sort IS NULL OR p_sort NOT IN ('NEWEST','OLDEST','SEVERITY') OR p_severity IS NULL OR p_severity NOT IN ('ALL','CRITICAL','HIGH','MEDIUM','LOW','UNRECORDED') OR p_min_hours IS NULL OR p_min_hours<0 OR p_min_hours>87600 OR p_waiting_only IS NULL THEN RAISE EXCEPTION 'Invalid priority filters' USING ERRCODE='22023';END IF;
 IF p_kind<>'CASES' AND staff.role<>'head_of_compliance' THEN RAISE EXCEPTION 'Head-of-compliance review access required' USING ERRCODE='42501';END IF;
 pattern:='%'||replace(replace(replace(btrim(p_search),E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_')||'%';
 WITH managed AS (
 SELECT c.*,a.customer_id,a.rule_triggered,coalesce(nullif(cu.entity_name,''),nullif(btrim(concat_ws(' ',cu.first_name,cu.last_name)),''),'Unlinked case') AS entity_name,
 left(coalesce(p.full_name,''),200) AS owner_name,g.member_count,g.status,g.consistent,g.severity_rank,g.unknown_severity_count
 FROM public.coreaml_case_claims c JOIN public.alerts a ON a.id=c.anchor_alert_id AND a.tenant_id=c.tenant_id
 LEFT JOIN public.customers cu ON cu.id=a.customer_id AND cu.tenant_id=c.tenant_id
 LEFT JOIN public.user_profiles p ON p.id=c.investigator_id AND p.tenant_id=c.tenant_id
 CROSS JOIN LATERAL (SELECT count(*)::integer AS member_count,max(CASE upper(btrim(x.severity)) WHEN 'CRITICAL' THEN 4 WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END) AS severity_rank,count(*) FILTER(WHERE x.severity IS NULL OR upper(btrim(x.severity)) NOT IN ('CRITICAL','HIGH','MEDIUM','LOW'))::integer AS unknown_severity_count,CASE WHEN count(DISTINCT x.status)=1 THEN min(x.status) ELSE 'MIXED' END AS status,
 count(*)=cardinality(c.alert_ids) AND count(DISTINCT x.status)=1 AS consistent
 FROM public.alerts x WHERE x.id=ANY(c.alert_ids) AND x.tenant_id=c.tenant_id AND x.assigned_user_id=c.investigator_id AND x.case_reference=c.case_reference AND x.customer_id IS NOT DISTINCT FROM a.customer_id) g
 WHERE c.tenant_id=staff.tenant_id AND cardinality(c.alert_ids) BETWEEN 1 AND 2000 AND c.anchor_alert_id=ANY(c.alert_ids)
 AND (p_kind='CASES' OR c.investigator_id<>staff.id) AND (staff.role='head_of_compliance' OR c.investigator_id=staff.id) AND (p_owner='ALL' OR c.investigator_id=staff.id)
 AND g.member_count=cardinality(c.alert_ids) AND (a.customer_id IS NULL OR cu.id IS NOT NULL)
 ), candidates AS (
 SELECT c.anchor_alert_id AS id,c.anchor_alert_id AS alert_id,c.case_reference,c.customer_id,c.entity_name,c.rule_triggered,c.severity_rank,c.unknown_severity_count,
 CASE WHEN c.consistent THEN c.status ELSE 'MIXED' END AS status,c.investigator_id AS owner_id,c.owner_name,c.member_count,c.consistent,
 CASE WHEN p_kind='QA' THEN s.created_at ELSE c.claimed_at END AS occurred_at,
 CASE WHEN c.consistent AND c.status='INVESTIGATING' THEN c.claimed_at WHEN c.consistent AND c.status='PENDING_QA_REVIEW' THEN s.created_at WHEN c.consistent AND c.status='ESCALATED' AND r.status='PENDING_APPROVAL' THEN r.created_at ELSE NULL END AS waiting_since,
 CASE WHEN c.consistent AND c.status='INVESTIGATING' THEN 'CLAIM' WHEN c.consistent AND c.status='PENDING_QA_REVIEW' THEN 'QA_SUBMISSION' WHEN c.consistent AND c.status='ESCALATED' AND r.status='PENDING_APPROVAL' THEN 'EXECUTIVE_SUBMISSION' WHEN c.consistent AND c.status='ESCALATED' AND r.status='APPROVED' THEN 'INTERNAL_PREPARATION' WHEN c.consistent AND c.status='ESCALATED' THEN 'REVIEW_TIMESTAMP_MISSING' ELSE 'NOT_WAITING' END AS age_basis,
 c.consistent AND (c.status IN ('INVESTIGATING','PENDING_QA_REVIEW') OR (c.status='ESCALATED' AND coalesce(r.status,'')<>'APPROVED')) AS is_waiting
 FROM managed c LEFT JOIN LATERAL (SELECT s.created_at FROM public.coreaml_review_submissions s JOIN public.investigation_drafts d ON d.id::text=s.result->>'draft_id' AND d.case_reference=s.case_reference AND d.tenant_id=s.tenant_id AND d.investigator_id=s.actor_id AND d.alert_id=c.anchor_alert_id AND d.status='SUBMITTED' AND s.result->>'revision'=d.revision::text WHERE s.case_reference=c.case_reference AND s.tenant_id=staff.tenant_id AND s.kind='QA' ORDER BY expected_revision DESC,s.created_at DESC,s.request_id DESC LIMIT 1) s ON true
 LEFT JOIN LATERAL (SELECT r.status,r.created_at FROM public.suspicious_transaction_reports r JOIN public.investigation_drafts d ON d.id::text=r.report_data->>'draft_id' AND d.revision::text=r.report_data->>'draft_revision' AND d.case_reference=c.case_reference AND d.alert_id=c.anchor_alert_id AND d.tenant_id=staff.tenant_id AND d.investigator_id=c.investigator_id AND d.status='SUBMITTED' WHERE r.alert_id=c.anchor_alert_id AND r.tenant_id=staff.tenant_id AND r.generated_by=c.investigator_id AND r.report_data->>'case_reference'=c.case_reference AND r.report_data->'alert_ids'=to_jsonb(c.alert_ids) ORDER BY r.created_at DESC,r.id DESC LIMIT 1) r ON true
 WHERE p_kind IN ('CASES','QA') AND (p_kind='CASES' OR (c.consistent AND c.status='PENDING_QA_REVIEW'))
 UNION ALL
 SELECT r.id,c.anchor_alert_id,c.case_reference,c.customer_id,c.entity_name,c.rule_triggered,c.severity_rank,c.unknown_severity_count,'PENDING_APPROVAL',c.investigator_id,c.owner_name,c.member_count,c.consistent,r.created_at,r.created_at,'EXECUTIVE_SUBMISSION',true
 FROM public.suspicious_transaction_reports r JOIN managed c ON r.alert_id=c.anchor_alert_id AND r.tenant_id=c.tenant_id AND r.generated_by=c.investigator_id
 WHERE p_kind='EXECUTIVE' AND NOT EXISTS(SELECT 1 FROM public.coreaml_reporting_routes route WHERE route.report_id=r.id AND route.tenant_id=staff.tenant_id) AND r.status='PENDING_APPROVAL' AND r.locked_at IS NULL AND r.report_data->'alert_ids'=to_jsonb(c.alert_ids) AND c.consistent AND c.status='ESCALATED' AND r.report_data->>'case_reference'=c.case_reference
 ), aged AS (SELECT *,CASE severity_rank WHEN 4 THEN 'CRITICAL' WHEN 3 THEN 'HIGH' WHEN 2 THEN 'MEDIUM' WHEN 1 THEN 'LOW' ELSE 'UNKNOWN' END AS severity,
 CASE WHEN NOT is_waiting THEN 'NOT_WAITING' WHEN waiting_since IS NULL THEN 'MISSING' WHEN waiting_since>as_of THEN 'FUTURE' ELSE 'RECORDED' END AS age_quality,
 CASE WHEN is_waiting AND waiting_since<=as_of THEN floor(extract(epoch FROM as_of-waiting_since))::bigint ELSE NULL END AS age_seconds FROM candidates), filtered AS (
 SELECT * FROM aged WHERE (NOT p_waiting_only OR is_waiting) AND (p_min_hours=0 OR age_seconds>=p_min_hours::bigint*3600)
 AND (p_severity='ALL' OR (p_severity='UNRECORDED' AND unknown_severity_count>0) OR severity=p_severity) AND (p_status='ALL' OR status=p_status) AND (p_from IS NULL OR occurred_at>=p_from) AND (p_until IS NULL OR occurred_at<p_until)
 AND (case_reference ILIKE pattern ESCAPE E'\\' OR entity_name ILIKE pattern ESCAPE E'\\' OR rule_triggered ILIKE pattern ESCAPE E'\\')
 ), page AS (SELECT * FROM filtered ORDER BY CASE WHEN p_sort='SEVERITY' THEN is_waiting::integer END DESC NULLS LAST,CASE WHEN p_sort='SEVERITY' THEN severity_rank END DESC NULLS LAST,CASE WHEN p_sort='SEVERITY' THEN waiting_since END ASC NULLS LAST,CASE WHEN p_sort='OLDEST' THEN occurred_at END ASC NULLS LAST,CASE WHEN p_sort='NEWEST' THEN occurred_at END DESC NULLS LAST,id DESC OFFSET p_offset LIMIT p_limit)
 SELECT jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'kind',p_kind,'sort',p_sort,'as_of',as_of,'offset',p_offset,'limit',p_limit,'total',(SELECT count(*) FROM filtered),'rows',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY CASE WHEN p_sort='SEVERITY' THEN is_waiting::integer END DESC NULLS LAST,CASE WHEN p_sort='SEVERITY' THEN severity_rank END DESC NULLS LAST,CASE WHEN p_sort='SEVERITY' THEN waiting_since END ASC NULLS LAST,CASE WHEN p_sort='OLDEST' THEN occurred_at END ASC NULLS LAST,CASE WHEN p_sort='NEWEST' THEN occurred_at END DESC NULLS LAST,id DESC) FROM page x),'[]'::jsonb)) INTO result;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION public.coreaml_my_review_submissions() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;rows jsonb;
BEGIN
 p:=coreaml_private.case_workflow_staff(false);
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO rows FROM (
 SELECT latest.request_id,latest.kind,latest.case_reference,latest.created_at,latest.result->>'alert_id' AS alert_id,latest.result->>'report_id' AS report_id,
 latest.snapshot,latest.result->'revision' AS submitted_revision,d.status AS draft_status,d.revision AS current_revision,r.status AS report_status,(SELECT route FROM public.coreaml_reporting_routes WHERE report_id=r.id) AS reporting_route,(SELECT state FROM public.coreaml_filing_drafts WHERE report_id=r.id AND tenant_id=p.tenant_id) AS reporting_state,(SELECT mode FROM public.coreaml_filing_drafts WHERE report_id=r.id AND tenant_id=p.tenant_id) AS reporting_mode,CASE WHEN latest.kind='QA' THEN a.qa_review_notes ELSE r.executive_justification END AS reviewer_notes
 FROM (SELECT DISTINCT ON (s.case_reference) s.* FROM public.coreaml_review_submissions s WHERE s.tenant_id=p.tenant_id AND s.actor_id=p.id ORDER BY s.case_reference,s.expected_revision DESC,s.created_at DESC,s.request_id) latest
 JOIN public.investigation_drafts d ON d.id=(latest.result->>'draft_id')::uuid AND d.tenant_id=p.tenant_id AND d.investigator_id=p.id AND d.case_reference=latest.case_reference
 JOIN public.alerts a ON a.id=(latest.result->>'alert_id')::uuid AND a.tenant_id=p.tenant_id AND a.case_reference=latest.case_reference
 LEFT JOIN public.suspicious_transaction_reports r ON r.id=(latest.result->>'report_id')::uuid AND r.tenant_id=p.tenant_id
 ORDER BY latest.created_at DESC LIMIT 50) x;
 RETURN rows;
END $$;
CREATE INDEX coreaml_reporting_pending_owner_idx ON public.suspicious_transaction_reports(tenant_id,generated_by,created_at DESC,id) WHERE status='PENDING_APPROVAL';
NOTIFY pgrst,'reload schema';
