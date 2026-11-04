-- Local review foundation. Existing report propagation is quarantined, not replaced with inferred links.
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid WHERE t.tgrelid='public.suspicious_transaction_reports'::regclass AND t.tgname='trg_network_contagion' AND md5(p.prosrc)='30dd775e66c84360d03e2766ab475928') THEN RAISE EXCEPTION 'Unreviewed report propagation trigger; installation stopped';END IF;
END $$;
ALTER TABLE public.suspicious_transaction_reports DISABLE TRIGGER trg_network_contagion;
COMMENT ON TRIGGER trg_network_contagion ON public.suspicious_transaction_reports IS 'Quarantined: unscoped risk propagation. Verified counterparty policy is not installed.';
CREATE TABLE public.coreaml_review_actions(
 request_id uuid PRIMARY KEY,kind text NOT NULL CHECK(kind IN ('QA','EXECUTIVE')),target_id uuid NOT NULL,
 tenant_id text NOT NULL,case_reference text NOT NULL REFERENCES public.coreaml_case_claims(case_reference),
 actor_id uuid NOT NULL REFERENCES auth.users(id),maker_id uuid NOT NULL REFERENCES auth.users(id),
 decision text NOT NULL CHECK(decision IN ('APPROVE','REJECT')),expected_token text NOT NULL,notes text NOT NULL,
 result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(kind,target_id,expected_token)
);
ALTER TABLE public.coreaml_review_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_review_actions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.coreaml_review_actions TO authenticated;
CREATE POLICY review_receipts_head_read ON public.coreaml_review_actions FOR SELECT TO authenticated USING(EXISTS(
 SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.is_active IS TRUE AND p.role='head_of_compliance'
 AND p.tenant_id=coreaml_review_actions.tenant_id AND auth.jwt()->'app_metadata'->>'role'=p.role AND auth.jwt()->'app_metadata'->>'tenant_id'=p.tenant_id));
CREATE FUNCTION coreaml_private.review_staff() RETURNS public.user_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid() FOR SHARE;
 IF NOT FOUND OR p.is_active IS NOT TRUE OR p.role<>'head_of_compliance' OR nullif(p.tenant_id,'') IS NULL
 OR auth.jwt()->'app_metadata'->>'role' IS DISTINCT FROM p.role OR auth.jwt()->'app_metadata'->>'tenant_id' IS DISTINCT FROM p.tenant_id THEN RAISE EXCEPTION 'Active trusted head-of-compliance profile required' USING ERRCODE='42501';END IF;
 RETURN p;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.review_staff() FROM PUBLIC,anon,authenticated;
CREATE FUNCTION coreaml_private.review_context(p_kind text,p_target uuid,p_lock boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;c public.coreaml_case_claims%ROWTYPE;a public.alerts%ROWTYPE;d public.investigation_drafts%ROWTYPE;r public.suspicious_transaction_reports%ROWTYPE;rows jsonb;fingerprint jsonb;total integer;pending integer;ids jsonb;
BEGIN
 p:=coreaml_private.review_staff();
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
REVOKE ALL ON FUNCTION coreaml_private.review_context(text,uuid,boolean) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.coreaml_load_review(p_kind text,p_target_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN RETURN coreaml_private.review_context(p_kind,p_target_id,false);END $$;
REVOKE ALL ON FUNCTION public.coreaml_load_review(text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_load_review(text,uuid) TO authenticated;
CREATE FUNCTION public.coreaml_review_decision(p_kind text,p_target_id uuid,p_expected_token text,p_decision text,p_notes text,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;ctx jsonb;old public.coreaml_review_actions%ROWTYPE;ids uuid[];new_status text;result jsonb;changed integer;
BEGIN
 p:=coreaml_private.review_staff();
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
REVOKE ALL ON FUNCTION public.coreaml_review_decision(text,uuid,text,text,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_review_decision(text,uuid,text,text,text,uuid) TO authenticated;
CREATE FUNCTION coreaml_private.guard_report_review() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF current_user IN ('authenticated','anon') THEN RAISE EXCEPTION 'Reports are server managed; no direct report writes' USING ERRCODE='42501';END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.guard_report_review() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER coreaml_guard_report_review BEFORE INSERT OR UPDATE OR DELETE ON public.suspicious_transaction_reports FOR EACH ROW EXECUTE FUNCTION coreaml_private.guard_report_review();
NOTIFY pgrst,'reload schema';
