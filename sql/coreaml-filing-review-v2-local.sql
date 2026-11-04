-- Upgrade the reporting layer only. Do not change investigator ownership or approved investigation records.
ALTER TABLE public.coreaml_filing_drafts DROP CONSTRAINT coreaml_filing_drafts_state_check;
ALTER TABLE public.coreaml_filing_drafts ADD CONSTRAINT coreaml_filing_drafts_state_check CHECK(state IN ('PREPARED','EXPORTED','SUBMISSION_RECORDED','ACKNOWLEDGEMENT_RECORDED','REJECTION_RECORDED','PENDING_FINAL_REVIEW','RETURNED_FOR_PREPARATION','FINAL_APPROVED','OUTCOME_PENDING_CONFIRMATION','REPORTING_COMPLETED'));
ALTER TABLE public.coreaml_filing_events DROP CONSTRAINT coreaml_filing_events_action_check;
ALTER TABLE public.coreaml_filing_events ADD CONSTRAINT coreaml_filing_events_action_check CHECK(action IN ('SAVE','EXPORT','SUBMISSION','ACKNOWLEDGEMENT','REJECTION','SUBMIT_REPORT','APPROVE_REPORT','RETURN_REPORT','CONFIRM_OUTCOME'));
ALTER TABLE public.coreaml_filing_drafts ADD COLUMN prepared_by uuid REFERENCES auth.users(id),ADD COLUMN submitted_request_id uuid REFERENCES public.coreaml_filing_events(request_id) DEFERRABLE INITIALLY DEFERRED,ADD COLUMN final_review_request_id uuid REFERENCES public.coreaml_filing_events(request_id) DEFERRABLE INITIALLY DEFERRED,ADD COLUMN pending_outcome_id uuid REFERENCES public.coreaml_filing_events(request_id) DEFERRABLE INITIALLY DEFERRED;
ALTER FUNCTION public.coreaml_filing_commit(uuid,uuid,uuid,text,integer,text,jsonb) SET SCHEMA coreaml_private;
ALTER FUNCTION coreaml_private.coreaml_filing_commit(uuid,uuid,uuid,text,integer,text,jsonb) RENAME TO filing_commit_v1;
REVOKE ALL ON FUNCTION coreaml_private.filing_commit_v1(uuid,uuid,uuid,text,integer,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION coreaml_private.filing_context(p_actor uuid,p_report uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;r public.suspicious_transaction_reports%ROWTYPE;c public.coreaml_case_claims%ROWTYPE;s public.coreaml_review_submissions%ROWTYPE;receipt public.coreaml_review_actions%ROWTYPE;source jsonb;txs jsonb;refs text[];linked integer;
BEGIN
 SELECT * INTO staff FROM public.user_profiles WHERE id=p_actor AND is_active IS TRUE AND role IN ('head_of_compliance','compliance_officer');
 IF NOT FOUND OR nullif(staff.tenant_id,'') IS NULL THEN RAISE EXCEPTION 'Active reporting staff required' USING ERRCODE='42501';END IF;
 SELECT * INTO r FROM public.suspicious_transaction_reports WHERE id=p_report AND tenant_id=staff.tenant_id AND status='APPROVED' AND locked_at IS NOT NULL AND reviewed_by IS NOT NULL;
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
 SELECT * INTO receipt FROM public.coreaml_review_actions WHERE target_id=r.id AND tenant_id=r.tenant_id AND kind='EXECUTIVE' AND decision='APPROVE' AND actor_id=r.reviewed_by ORDER BY created_at DESC LIMIT 1;
 IF NOT FOUND OR receipt.case_reference<>c.case_reference OR receipt.maker_id<>c.investigator_id OR receipt.notes IS DISTINCT FROM r.executive_justification THEN RAISE EXCEPTION 'Approval receipt unavailable' USING ERRCODE='40001';END IF;
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
 RETURN jsonb_build_object('source',source,'source_hash',encode(sha256(convert_to(source::text,'UTF8')),'hex'));
END $$;
REVOKE ALL ON FUNCTION coreaml_private.filing_context(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.coreaml_filing_read_v2(p_report_id uuid DEFAULT NULL,p_offset integer DEFAULT 0,p_case_reference text DEFAULT NULL,p_queue text DEFAULT 'ALL') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;ctx jsonb;rows jsonb;total integer;events jsonb;draft public.coreaml_filing_drafts%ROWTYPE;
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF staff.role NOT IN ('compliance_officer','head_of_compliance') THEN RAISE EXCEPTION 'Authorized reporting role required' USING ERRCODE='42501';END IF;
 IF p_offset IS NULL OR p_offset<0 OR p_offset>1000000 OR p_queue IS NULL OR p_queue NOT IN ('ALL','PREPARATION','FINAL_REVIEW','FILING','OUTCOMES','COMPLETED') THEN RAISE EXCEPTION 'Invalid reporting page' USING ERRCODE='22023';END IF;
 IF p_case_reference IS NOT NULL THEN
  IF p_report_id IS NOT NULL OR length(p_case_reference)>200 OR p_case_reference NOT LIKE 'CASE-%' THEN RAISE EXCEPTION 'Invalid case reference' USING ERRCODE='22023';END IF;
  SELECT id INTO p_report_id FROM public.suspicious_transaction_reports WHERE tenant_id=staff.tenant_id AND status='APPROVED' AND (staff.role='head_of_compliance' OR generated_by=staff.id) AND report_data->>'case_reference'=p_case_reference ORDER BY locked_at DESC,id LIMIT 1;
  IF p_report_id IS NULL THEN RAISE EXCEPTION 'Approved case unavailable' USING ERRCODE='42501';END IF;
 END IF;
 IF p_report_id IS NULL THEN
  WITH scoped AS (SELECT r.*,f.state,f.mode,f.revision,coalesce(cu.entity_name,nullif(concat_ws(' ',cu.first_name,cu.last_name),''),'Name not recorded') AS entity_name FROM public.suspicious_transaction_reports r LEFT JOIN public.coreaml_filing_drafts f ON f.report_id=r.id AND f.tenant_id=r.tenant_id LEFT JOIN public.alerts a ON a.id=r.alert_id AND a.tenant_id=r.tenant_id LEFT JOIN public.customers cu ON cu.id=a.customer_id AND cu.tenant_id=r.tenant_id WHERE r.tenant_id=staff.tenant_id AND r.status='APPROVED' AND (staff.role='head_of_compliance' OR r.generated_by=staff.id)),
  filtered AS (SELECT * FROM scoped WHERE p_queue='ALL' OR (p_queue='PREPARATION' AND (state IS NULL OR state IN ('PREPARED','RETURNED_FOR_PREPARATION','REJECTION_RECORDED'))) OR (p_queue='FINAL_REVIEW' AND state='PENDING_FINAL_REVIEW') OR (p_queue='FILING' AND state IN ('FINAL_APPROVED','EXPORTED','SUBMISSION_RECORDED')) OR (p_queue='OUTCOMES' AND state IN ('SUBMISSION_RECORDED','OUTCOME_PENDING_CONFIRMATION','ACKNOWLEDGEMENT_RECORDED')) OR (p_queue='COMPLETED' AND state='REPORTING_COMPLETED')),
  page AS (SELECT id,report_data->>'case_reference' AS case_reference,locked_at AS approved_at,entity_name,state,mode,revision FROM filtered ORDER BY locked_at DESC,id LIMIT 25 OFFSET p_offset)
  SELECT (SELECT count(*) FROM filtered),coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY approved_at DESC,id) FROM page),'[]') INTO total,rows;
  RETURN jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'role',staff.role,'rows',rows,'total',total,'offset',p_offset,'limit',25,'queue',p_queue,'as_of',transaction_timestamp());
 END IF;
 ctx:=coreaml_private.filing_context(staff.id,p_report_id);
 SELECT * INTO draft FROM public.coreaml_filing_drafts WHERE report_id=p_report_id AND tenant_id=staff.tenant_id;
 SELECT coalesce(jsonb_agg(jsonb_build_object('request_id',e.request_id,'actor_id',e.actor_id,'actor_name',(SELECT full_name FROM public.user_profiles p WHERE p.id=e.actor_id AND p.tenant_id=e.tenant_id),'action',e.action,'revision',e.revision,'at',e.created_at,'evidence',e.evidence) ORDER BY e.created_at DESC),'[]') INTO events FROM (SELECT * FROM public.coreaml_filing_events WHERE report_id=p_report_id AND tenant_id=staff.tenant_id ORDER BY created_at DESC LIMIT 101) e;
 IF jsonb_array_length(events)>100 THEN RAISE EXCEPTION 'Reporting history exceeds the 100-entry display limit' USING ERRCODE='22023';END IF;
 RETURN ctx||jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'role',staff.role,'owner_name',(SELECT full_name FROM public.user_profiles p WHERE p.id=(ctx->'source'->>'owner_id')::uuid AND p.tenant_id=staff.tenant_id),'preparer_name',(SELECT full_name FROM public.user_profiles p WHERE p.id=draft.prepared_by AND p.tenant_id=staff.tenant_id),'draft',CASE WHEN draft.report_id IS NULL THEN NULL ELSE to_jsonb(draft)-'source_snapshot' END,'events',events,'as_of',transaction_timestamp());
END $$;
REVOKE ALL ON FUNCTION public.coreaml_filing_read_v2(uuid,integer,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_filing_read_v2(uuid,integer,text,text) TO authenticated;
CREATE FUNCTION public.coreaml_filing_commit(p_actor uuid,p_report_id uuid,p_request_id uuid,p_action text,p_revision integer,p_source_hash text,p_payload jsonb) RETURNS jsonb
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
 IF p_action IN ('SAVE','SUBMIT_REPORT','ACKNOWLEDGEMENT','REJECTION') THEN
  IF staff.role<>'compliance_officer' OR p_actor::text<>ctx->'source'->>'owner_id' THEN RAISE EXCEPTION 'Only the assigned compliance officer may prepare or record external responses' USING ERRCODE='42501';END IF;
 ELSE
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
  new_state:='FINAL_APPROVED';ev:=submitted.evidence||jsonb_build_object('notes',notes,'reviewed_by',p_actor,'prepared_by',d.prepared_by,'submission_request_id',submitted.request_id);
  UPDATE public.coreaml_filing_drafts SET final_review_request_id=p_request_id WHERE report_id=p_report_id;
 ELSIF p_action='RETURN_REPORT' THEN
  IF d.state NOT IN ('PENDING_FINAL_REVIEW','FINAL_APPROVED','EXPORTED') THEN RAISE EXCEPTION 'This version is not available for an internal return' USING ERRCODE='40001';END IF;
  notes:=btrim(coalesce(p_payload->>'notes',''));IF length(notes)<3 OR length(notes)>10000 THEN RAISE EXCEPTION 'Enter feedback for the preparing officer' USING ERRCODE='22023';END IF;
  new_state:='RETURNED_FOR_PREPARATION';ev:=jsonb_build_object('notes',notes,'mode',d.mode,'xml_hash',xml_hash,'prepared_by',d.prepared_by,'external_rejection',false);
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
  new_state:='OUTCOME_PENDING_CONFIRMATION';result:=result||jsonb_build_object('state',new_state);
  UPDATE public.coreaml_filing_drafts SET state=new_state,pending_outcome_id=p_request_id WHERE report_id=p_report_id;
  UPDATE public.coreaml_filing_events e SET result=e.result||jsonb_build_object('state',new_state),evidence=e.evidence||jsonb_build_object('entry_source','OFFICER_MANUAL_ENTRY','externally_verified',false,'external_response',true) WHERE request_id=p_request_id;
  RETURN result;
 ELSE
  IF d.state<>'OUTCOME_PENDING_CONFIRMATION' THEN RAISE EXCEPTION 'An officer-recorded external response is required' USING ERRCODE='40001';END IF;
  SELECT * INTO outcome FROM public.coreaml_filing_events WHERE request_id=d.pending_outcome_id AND report_id=p_report_id AND tenant_id=d.tenant_id AND revision=d.revision AND action IN ('ACKNOWLEDGEMENT','REJECTION') AND actor_id<>p_actor;
  IF NOT FOUND OR outcome.actor_id::text<>ctx->'source'->>'owner_id' OR p_payload->>'outcome_id' IS DISTINCT FROM outcome.request_id::text THEN RAISE EXCEPTION 'Confirm the exact officer-recorded response' USING ERRCODE='42501';END IF;
  notes:=btrim(coalesce(p_payload->>'notes',''));IF length(notes)<3 OR length(notes)>10000 THEN RAISE EXCEPTION 'Enter an outcome confirmation note' USING ERRCODE='22023';END IF;
  new_state:=CASE WHEN outcome.action='REJECTION' THEN 'REJECTION_RECORDED' ELSE 'REPORTING_COMPLETED' END;
  ev:=jsonb_build_object('mode',d.mode,'notes',notes,'outcome_id',outcome.request_id,'response_kind',outcome.action,'confirmed_by',p_actor,'recorded_by',outcome.actor_id,'entry_source','HEAD_CONFIRMED_MANUAL_RECORD','externally_verified',false,'case_closure_required',new_state='REPORTING_COMPLETED');
  UPDATE public.coreaml_filing_drafts SET pending_outcome_id=NULL,final_review_request_id=CASE WHEN outcome.action='REJECTION' THEN NULL ELSE final_review_request_id END WHERE report_id=p_report_id;
 END IF;
 UPDATE public.coreaml_filing_drafts SET state=new_state,updated_by=p_actor,updated_at=clock_timestamp() WHERE report_id=p_report_id;
 result:=jsonb_build_object('request_id',p_request_id,'report_id',p_report_id,'actor_id',p_actor,'tenant_id',d.tenant_id,'revision',d.revision,'state',new_state,'action',p_action,'replayed',false,'externally_verified',false);
 ev:=ev||jsonb_build_object('client_request_hash',p_payload->>'client_request_hash');
 INSERT INTO public.coreaml_filing_events(request_id,report_id,tenant_id,actor_id,action,revision,input_hash,result,evidence) VALUES(p_request_id,p_report_id,d.tenant_id,p_actor,p_action,d.revision,fingerprint,result,ev);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_filing_commit(uuid,uuid,uuid,text,integer,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_filing_commit(uuid,uuid,uuid,text,integer,text,jsonb) TO service_role;
CREATE FUNCTION public.coreaml_filing_export_read_v2(p_export_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;x public.coreaml_filing_exports%ROWTYPE;
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF staff.role NOT IN ('head_of_compliance','compliance_officer') THEN RAISE EXCEPTION 'Reporting access required' USING ERRCODE='42501';END IF;
 SELECT e.* INTO x FROM public.coreaml_filing_exports e JOIN public.suspicious_transaction_reports r ON r.id=e.report_id AND r.tenant_id=e.tenant_id WHERE e.id=p_export_id AND e.tenant_id=staff.tenant_id AND (staff.role='head_of_compliance' OR r.generated_by=staff.id);
 IF NOT FOUND THEN RAISE EXCEPTION 'Export unavailable' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'export_id',x.id,'report_id',x.report_id,'revision',x.revision,'mode',x.mode,'xml',x.xml_content,'xml_hash',x.xml_hash,'schema_label',x.schema_label,'schema_hash',x.schema_hash);
END $$;
REVOKE ALL ON FUNCTION public.coreaml_filing_export_read_v2(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_filing_export_read_v2(uuid) TO authenticated;
CREATE FUNCTION public.coreaml_filing_progress(p_case_references text[]) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;rows jsonb;
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF staff.role NOT IN ('head_of_compliance','compliance_officer') THEN RAISE EXCEPTION 'Reporting access required' USING ERRCODE='42501';END IF;
 IF p_case_references IS NULL OR cardinality(p_case_references)>50 OR EXISTS(SELECT 1 FROM unnest(p_case_references) x WHERE x IS NULL OR length(x)>200 OR x NOT LIKE 'CASE-%') THEN RAISE EXCEPTION 'Invalid case progress request' USING ERRCODE='22023';END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.case_reference),'[]') INTO rows FROM (SELECT DISTINCT ON (r.report_data->>'case_reference') r.report_data->>'case_reference' AS case_reference,f.state,f.mode,f.revision FROM public.suspicious_transaction_reports r LEFT JOIN public.coreaml_filing_drafts f ON f.report_id=r.id AND f.tenant_id=r.tenant_id WHERE r.tenant_id=staff.tenant_id AND r.status='APPROVED' AND (staff.role='head_of_compliance' OR r.generated_by=staff.id) AND r.report_data->>'case_reference'=ANY(p_case_references) ORDER BY r.report_data->>'case_reference',r.locked_at DESC,r.id) x;
 RETURN jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'rows',rows);
END $$;
REVOKE ALL ON FUNCTION public.coreaml_filing_progress(text[]) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_filing_progress(text[]) TO authenticated;
CREATE INDEX coreaml_filing_approved_case_idx ON public.suspicious_transaction_reports(tenant_id,(report_data->>'case_reference'),locked_at DESC,id) WHERE status='APPROVED';
NOTIFY pgrst,'reload schema';
