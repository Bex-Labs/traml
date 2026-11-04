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
CREATE FUNCTION public.coreaml_case_action(p_alert_id uuid,p_action text,p_expected_revision integer,p_request_id uuid,p_narrative text DEFAULT NULL,p_snapshot jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE ctx jsonb;d public.investigation_drafts%ROWTYPE;r public.coreaml_case_actions%ROWTYPE;payload jsonb;result jsonb;pins jsonb;ids uuid[];changed integer;
BEGIN
 IF p_action NOT IN ('SAVE','CLOSE') OR p_action IS NULL OR p_request_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision<0 THEN RAISE EXCEPTION 'Invalid case action' USING ERRCODE='22023';END IF;
 ctx:=coreaml_private.case_workflow_context(p_alert_id,true);
 IF p_action='SAVE' THEN
  IF p_narrative IS NULL OR length(p_narrative)>20000 OR p_snapshot IS NULL THEN RAISE EXCEPTION 'Invalid draft content' USING ERRCODE='22023';END IF;
  payload:=jsonb_build_object('revision',p_expected_revision,'narrative',p_narrative,'snapshot',p_snapshot);
 ELSE
  IF p_narrative IS NOT NULL OR p_snapshot IS NOT NULL THEN RAISE EXCEPTION 'Close uses the saved draft' USING ERRCODE='22023';END IF;
  payload:=jsonb_build_object('revision',p_expected_revision);
 END IF;
 SELECT * INTO r FROM public.coreaml_case_actions WHERE request_id=p_request_id;
 IF FOUND THEN
  IF r.actor_id IS DISTINCT FROM (ctx->>'actor_id')::uuid OR r.case_reference IS DISTINCT FROM ctx->>'case_reference' OR r.tenant_id IS DISTINCT FROM ctx->>'tenant_id' THEN RAISE EXCEPTION 'Request reference unavailable' USING ERRCODE='42501';END IF;
  IF r.action<>p_action OR r.payload IS DISTINCT FROM payload THEN RAISE EXCEPTION 'Request reference reused with different content' USING ERRCODE='22023';END IF;
  RETURN r.result||jsonb_build_object('replayed',true);
 END IF;
 IF ctx->>'case_status'<>'INVESTIGATING' THEN RAISE EXCEPTION 'Case is no longer open';END IF;
 SELECT * INTO d FROM public.investigation_drafts WHERE alert_id=(ctx->>'alert_id')::uuid AND investigator_id=(ctx->>'owner_id')::uuid FOR UPDATE;
 IF FOUND THEN
  IF d.case_reference IS DISTINCT FROM ctx->>'case_reference' OR d.tenant_id IS DISTINCT FROM ctx->>'tenant_id' OR d.status<>'IN_PROGRESS' THEN RAISE EXCEPTION 'Draft is unavailable for editing';END IF;
  IF d.revision<>p_expected_revision THEN RAISE EXCEPTION 'Draft revision conflict';END IF;
 ELSE
  IF p_expected_revision<>0 OR p_action='CLOSE' THEN RAISE EXCEPTION 'Draft revision conflict or missing draft';END IF;
 END IF;
 IF p_action='SAVE' THEN
  pins:=coreaml_private.case_workflow_pins(p_snapshot,ctx->>'tenant_id');
  IF d.id IS NULL THEN
   INSERT INTO public.investigation_drafts(id,tenant_id,alert_id,investigator_id,case_reference,revision,draft_narrative,evidence_snapshot,status,created_at,updated_at)
   VALUES(gen_random_uuid(),ctx->>'tenant_id',(ctx->>'alert_id')::uuid,(ctx->>'owner_id')::uuid,ctx->>'case_reference',1,p_narrative,pins,'IN_PROGRESS',clock_timestamp(),clock_timestamp()) RETURNING * INTO d;
  ELSE
   UPDATE public.investigation_drafts SET draft_narrative=p_narrative,evidence_snapshot=pins,revision=revision+1,updated_at=clock_timestamp() WHERE id=d.id RETURNING * INTO d;
  END IF;
 ELSE
  IF length(btrim(coalesce(d.draft_narrative,'')))<15 THEN RAISE EXCEPTION 'A saved case narrative of at least 15 characters is required';END IF;
  SELECT array_agg(value::uuid) INTO ids FROM jsonb_array_elements_text(ctx->'alert_ids');
  UPDATE public.alerts SET status='CLOSED' WHERE id=ANY(ids) AND status='INVESTIGATING' AND case_reference=ctx->>'case_reference' AND assigned_user_id=(ctx->>'owner_id')::uuid AND tenant_id=ctx->>'tenant_id';
  GET DIAGNOSTICS changed=ROW_COUNT;
  IF changed<>cardinality(ids) THEN RAISE EXCEPTION 'Incomplete closure; no case changes committed';END IF;
  UPDATE public.investigation_drafts SET status='CLOSED',revision=revision+1,closed_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=d.id RETURNING * INTO d;
 END IF;
 result:=jsonb_build_object('request_id',p_request_id,'id',d.id,'alert_id',d.alert_id,'case_reference',d.case_reference,'revision',d.revision,'status',d.status,'replayed',false);
 INSERT INTO public.coreaml_case_actions(request_id,case_reference,actor_id,tenant_id,action,payload,result)
 VALUES(p_request_id,ctx->>'case_reference',(ctx->>'actor_id')::uuid,ctx->>'tenant_id',p_action,payload,result);
 INSERT INTO public.system_events(event_type,severity,message,tenant_id,user_id,metadata)
 VALUES(CASE WHEN p_action='SAVE' THEN 'CASE_DRAFT_SAVED' ELSE 'CASE_CLOSED' END,'INFO',CASE WHEN p_action='SAVE' THEN 'Case draft saved' ELSE 'Claimed case closed' END,
 (ctx->>'tenant_id')::uuid,(ctx->>'actor_id')::uuid,jsonb_build_object('case_ref',ctx->>'case_reference','anchor_alert_id',ctx->>'alert_id','request_id',p_request_id,'revision',d.revision));
 RETURN result;
END $$;
