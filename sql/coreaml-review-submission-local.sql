CREATE OR REPLACE FUNCTION coreaml_private.review_context(p_kind text,p_target uuid,p_lock boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
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

-- Maker submission from saved canonical state. No client report payload or financial action is accepted.
CREATE TABLE public.coreaml_review_submissions(
 request_id uuid PRIMARY KEY,case_reference text NOT NULL REFERENCES public.coreaml_case_claims(case_reference),
 tenant_id text NOT NULL,actor_id uuid NOT NULL REFERENCES auth.users(id),kind text NOT NULL CHECK(kind IN ('QA','EXECUTIVE')),
 expected_revision integer NOT NULL CHECK(expected_revision>0),snapshot jsonb NOT NULL,result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(case_reference,expected_revision)
);
CREATE INDEX coreaml_review_submissions_owner ON public.coreaml_review_submissions(tenant_id,actor_id,created_at DESC);
ALTER TABLE public.coreaml_review_submissions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_review_submissions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.coreaml_review_submissions TO authenticated;
CREATE POLICY review_submissions_read ON public.coreaml_review_submissions FOR SELECT TO authenticated USING(EXISTS(
 SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.is_active IS TRUE AND p.tenant_id=coreaml_review_submissions.tenant_id
 AND auth.jwt()->'app_metadata'->>'tenant_id'=p.tenant_id AND auth.jwt()->'app_metadata'->>'role'=p.role
 AND (p.role='head_of_compliance' OR (p.role='compliance_officer' AND p.id=coreaml_review_submissions.actor_id))));
-- Existing permissive STR policies did not isolate reads. Restrict them without adding write authority.
CREATE POLICY coreaml_report_review_boundary ON public.suspicious_transaction_reports AS RESTRICTIVE FOR ALL TO authenticated
USING(EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.is_active IS TRUE AND p.tenant_id=suspicious_transaction_reports.tenant_id
 AND auth.jwt()->'app_metadata'->>'tenant_id'=p.tenant_id AND auth.jwt()->'app_metadata'->>'role'=p.role
 AND (p.role='head_of_compliance' OR (p.role='compliance_officer' AND p.id IN (suspicious_transaction_reports.generated_by,suspicious_transaction_reports.created_by)))))
WITH CHECK(EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.is_active IS TRUE AND p.tenant_id=suspicious_transaction_reports.tenant_id
 AND auth.jwt()->'app_metadata'->>'tenant_id'=p.tenant_id AND auth.jwt()->'app_metadata'->>'role'=p.role
 AND (p.role='head_of_compliance' OR (p.role='compliance_officer' AND p.id IN (suspicious_transaction_reports.generated_by,suspicious_transaction_reports.created_by)))));
CREATE FUNCTION public.coreaml_submit_case_review(p_alert_id uuid,p_kind text,p_expected_revision integer,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;ctx jsonb;d public.investigation_drafts%ROWTYPE;old public.coreaml_review_submissions%ROWTYPE;ids uuid[];report_id uuid;result jsonb;sealed jsonb;changed integer;
BEGIN
 p:=coreaml_private.case_workflow_staff(true);
 IF p_alert_id IS NULL OR p_kind IS NULL OR p_kind NOT IN ('QA','EXECUTIVE') OR p_expected_revision IS NULL OR p_expected_revision<1 OR p_request_id IS NULL THEN RAISE EXCEPTION 'A confirmed saved revision and review type are required' USING ERRCODE='22023';END IF;
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('review-submit:'||p_request_id::text,0));
 SELECT * INTO old FROM public.coreaml_review_submissions WHERE request_id=p_request_id;
 IF FOUND THEN
  IF old.actor_id<>p.id OR old.tenant_id<>p.tenant_id THEN RAISE EXCEPTION 'Submission reference unavailable' USING ERRCODE='42501';END IF;
  IF old.kind<>p_kind OR old.expected_revision<>p_expected_revision OR old.result->>'alert_id'<>p_alert_id::text THEN RAISE EXCEPTION 'Submission reference reused with different content' USING ERRCODE='22023';END IF;
  RETURN old.result||jsonb_build_object('replayed',true);
 END IF;
 ctx:=coreaml_private.case_workflow_context(p_alert_id,true);
 IF ctx->>'case_status'<>'INVESTIGATING' OR (ctx->>'alert_id')::uuid<>p_alert_id OR (ctx->>'owner_id')::uuid<>p.id THEN RAISE EXCEPTION 'Only the owning officer may submit the canonical open case' USING ERRCODE='42501';END IF;
 IF ctx->>'customer_id' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.customers WHERE id=(ctx->>'customer_id')::uuid AND tenant_id=p.tenant_id) THEN RAISE EXCEPTION 'Case customer unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO d FROM public.investigation_drafts WHERE alert_id=p_alert_id AND investigator_id=p.id AND tenant_id=p.tenant_id FOR UPDATE;
 IF NOT FOUND OR d.case_reference IS DISTINCT FROM ctx->>'case_reference' OR d.status<>'IN_PROGRESS' OR d.revision<>p_expected_revision THEN RAISE EXCEPTION 'Saved revision changed; reload before submitting' USING ERRCODE='40001';END IF;
 IF length(btrim(coalesce(d.draft_narrative,'')))<15 OR length(d.draft_narrative)>20000 OR jsonb_typeof(d.evidence_snapshot) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'A saved narrative and evidence snapshot are required' USING ERRCODE='22023';END IF;
 SELECT array_agg(v::uuid) INTO ids FROM jsonb_array_elements_text(ctx->'alert_ids') v;
 sealed:=jsonb_build_object('narrative',d.draft_narrative,'evidence_snapshot',d.evidence_snapshot,'source_revision',d.revision);
 UPDATE public.alerts SET status=CASE WHEN p_kind='QA' THEN 'PENDING_QA_REVIEW' ELSE 'ESCALATED' END,qa_reviewed_by=CASE WHEN p_kind='QA' THEN NULL ELSE qa_reviewed_by END,qa_review_notes=CASE WHEN p_kind='QA' THEN NULL ELSE qa_review_notes END,qa_reviewed_at=CASE WHEN p_kind='QA' THEN NULL ELSE qa_reviewed_at END WHERE id=ANY(ids) AND tenant_id=p.tenant_id AND assigned_user_id=p.id AND case_reference=d.case_reference AND status='INVESTIGATING';
 GET DIAGNOSTICS changed=ROW_COUNT;IF changed<>cardinality(ids) THEN RAISE EXCEPTION 'Incomplete case submission' USING ERRCODE='40001';END IF;
 UPDATE public.investigation_drafts SET status='SUBMITTED',revision=revision+1,updated_at=clock_timestamp() WHERE id=d.id RETURNING * INTO d;
 IF p_kind='EXECUTIVE' THEN
  IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_proc f ON f.oid=t.tgfoid WHERE t.tgrelid='public.suspicious_transaction_reports'::regclass AND t.tgname='trg_network_contagion' AND t.tgenabled='D' AND pg_catalog.md5(f.prosrc)='30dd775e66c84360d03e2766ab475928') THEN RAISE EXCEPTION 'Report risk propagation is not in its reviewed quarantine state' USING ERRCODE='42501';END IF;
  INSERT INTO public.suspicious_transaction_reports(alert_id,tenant_id,generated_by,created_by,status,report_data,investigator_notes)
  VALUES(p_alert_id,p.tenant_id,p.id,p.id,'PENDING_APPROVAL',jsonb_build_object('purpose','EXECUTIVE_REVIEW_NOT_FILING','case_reference',d.case_reference,'alert_ids',ids,'draft_id',d.id,'draft_revision',d.revision,'evidence_snapshot',d.evidence_snapshot,'submission_request_id',p_request_id),d.draft_narrative) RETURNING id INTO report_id;
 END IF;
 result:=jsonb_build_object('request_id',p_request_id,'kind',p_kind,'alert_id',p_alert_id,'alert_ids',ids,'case_reference',d.case_reference,'draft_id',d.id,'actor_id',p.id,'tenant_id',p.tenant_id,'source_revision',p_expected_revision,'revision',d.revision,'status','SUBMITTED','report_id',report_id,'replayed',false,'regulatory_submission',false);
 INSERT INTO public.coreaml_review_submissions(request_id,case_reference,tenant_id,actor_id,kind,expected_revision,snapshot,result) VALUES(p_request_id,d.case_reference,p.tenant_id,p.id,p_kind,p_expected_revision,sealed,result);
 INSERT INTO public.system_events(event_type,severity,message,tenant_id,user_id,metadata) VALUES('CASE_REVIEW_SUBMITTED','INFO','Saved canonical case submitted for independent review; no regulatory submission',p.tenant_id::uuid,p.id,jsonb_build_object('request_id',p_request_id,'case_reference',d.case_reference,'kind',p_kind,'revision',d.revision,'report_id',report_id,'regulatory_submission',false));
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_submit_case_review(uuid,text,integer,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_submit_case_review(uuid,text,integer,uuid) TO authenticated;
CREATE FUNCTION public.coreaml_my_review_submissions() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;rows jsonb;
BEGIN
 p:=coreaml_private.case_workflow_staff(false);
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb) INTO rows FROM (
 SELECT latest.request_id,latest.kind,latest.case_reference,latest.created_at,latest.result->>'alert_id' AS alert_id,latest.result->>'report_id' AS report_id,
 latest.snapshot,latest.result->'revision' AS submitted_revision,d.status AS draft_status,d.revision AS current_revision,r.status AS report_status,CASE WHEN latest.kind='QA' THEN a.qa_review_notes ELSE r.executive_justification END AS reviewer_notes
 FROM (SELECT DISTINCT ON (s.case_reference) s.* FROM public.coreaml_review_submissions s WHERE s.tenant_id=p.tenant_id AND s.actor_id=p.id ORDER BY s.case_reference,s.expected_revision DESC,s.created_at DESC,s.request_id) latest
 JOIN public.investigation_drafts d ON d.id=(latest.result->>'draft_id')::uuid AND d.tenant_id=p.tenant_id AND d.investigator_id=p.id AND d.case_reference=latest.case_reference
 JOIN public.alerts a ON a.id=(latest.result->>'alert_id')::uuid AND a.tenant_id=p.tenant_id AND a.case_reference=latest.case_reference
 LEFT JOIN public.suspicious_transaction_reports r ON r.id=(latest.result->>'report_id')::uuid AND r.tenant_id=p.tenant_id
 ORDER BY latest.created_at DESC LIMIT 50) x;
 RETURN rows;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_my_review_submissions() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_my_review_submissions() TO authenticated;
NOTIFY pgrst,'reload schema';
