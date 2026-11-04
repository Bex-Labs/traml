CREATE FUNCTION coreaml_private.case_workflow_staff(p_write boolean) RETURNS public.user_profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 IF p_write THEN SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid() FOR SHARE;
 ELSE SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid();END IF;
 IF NOT FOUND OR p.is_active IS NOT TRUE OR nullif(p.tenant_id,'') IS NULL OR p.role NOT IN ('compliance_officer','head_of_compliance')
 OR (p_write AND p.role<>'compliance_officer') OR (auth.jwt()->'app_metadata'->>'tenant_id') IS DISTINCT FROM p.tenant_id
 OR (auth.jwt()->'app_metadata'->>'role') IS DISTINCT FROM p.role THEN RAISE EXCEPTION 'Active authorized bank profile required' USING ERRCODE='42501';END IF;
 RETURN p;
END $$;
CREATE FUNCTION coreaml_private.case_workflow_context(p_alert_id uuid,p_write boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;c public.coreaml_case_claims%ROWTYPE;a public.alerts%ROWTYPE;total integer;opened integer;closed integer;
BEGIN
 p:=coreaml_private.case_workflow_staff(p_write);
 SELECT * INTO c FROM public.coreaml_case_claims WHERE tenant_id=p.tenant_id AND p_alert_id=ANY(alert_ids);
 IF NOT FOUND OR (c.investigator_id<>p.id AND (p_write OR p.role<>'head_of_compliance')) THEN RAISE EXCEPTION 'Case unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO a FROM public.alerts WHERE id=c.anchor_alert_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Case anchor unavailable';END IF;
 IF p_write THEN
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p.tenant_id||':'||coalesce(a.customer_id::text,a.id::text),0));
  PERFORM id FROM public.coreaml_case_claims WHERE id=c.id FOR UPDATE;
  PERFORM id FROM public.alerts WHERE id=ANY(c.alert_ids) ORDER BY id FOR UPDATE;
 END IF;
 SELECT count(*),count(*) FILTER(WHERE status='INVESTIGATING'),count(*) FILTER(WHERE status='CLOSED') INTO total,opened,closed
 FROM public.alerts WHERE id=ANY(c.alert_ids) AND tenant_id=p.tenant_id AND assigned_user_id=c.investigator_id AND case_reference=c.case_reference
 AND customer_id IS NOT DISTINCT FROM a.customer_id;
 IF total<>cardinality(c.alert_ids) OR (opened<>total AND closed<>total) THEN RAISE EXCEPTION 'Case membership or state changed';END IF;
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'case_reference',c.case_reference,'alert_id',c.anchor_alert_id,
 'alert_ids',c.alert_ids,'customer_id',a.customer_id,'owner_id',c.investigator_id,'case_status',CASE WHEN closed=total THEN 'CLOSED' ELSE 'INVESTIGATING' END,
 'read_only',p.id<>c.investigator_id OR p.role<>'compliance_officer' OR closed=total);
END $$;
CREATE FUNCTION coreaml_private.review_staff() RETURNS public.user_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid() FOR SHARE;
 IF NOT FOUND OR p.is_active IS NOT TRUE OR p.role<>'head_of_compliance' OR nullif(p.tenant_id,'') IS NULL
 OR auth.jwt()->'app_metadata'->>'role' IS DISTINCT FROM p.role OR auth.jwt()->'app_metadata'->>'tenant_id' IS DISTINCT FROM p.tenant_id THEN RAISE EXCEPTION 'Active trusted head-of-compliance profile required' USING ERRCODE='42501';END IF;
 RETURN p;
END $$;
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
CREATE FUNCTION public.coreaml_case_worklist_priority(p_kind text DEFAULT 'CASES',p_search text DEFAULT '',p_status text DEFAULT 'ALL',p_owner text DEFAULT 'ALL',p_from timestamptz DEFAULT NULL,p_until timestamptz DEFAULT NULL,p_offset integer DEFAULT 0,p_limit integer DEFAULT 25,p_sort text DEFAULT 'NEWEST',p_severity text DEFAULT 'ALL',p_min_hours integer DEFAULT 0,p_waiting_only boolean DEFAULT false)
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
 WHERE p_kind='EXECUTIVE' AND r.status='PENDING_APPROVAL' AND r.locked_at IS NULL AND r.report_data->'alert_ids'=to_jsonb(c.alert_ids) AND c.consistent AND c.status='ESCALATED' AND r.report_data->>'case_reference'=c.case_reference
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
CREATE FUNCTION public.coreaml_load_review(p_kind text,p_target_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN RETURN coreaml_private.review_context(p_kind,p_target_id,false);END $$;
GRANT EXECUTE ON FUNCTION public.coreaml_load_review(text,uuid) TO authenticated;
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
