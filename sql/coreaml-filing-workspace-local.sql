-- New reporting records only. Approved packages, ledger, risk and case ownership are untouched.
CREATE TABLE public.coreaml_filing_drafts (
 report_id uuid PRIMARY KEY REFERENCES public.suspicious_transaction_reports(id),tenant_id text NOT NULL,
 revision integer NOT NULL CHECK(revision>0),state text NOT NULL CHECK(state IN ('PREPARED','EXPORTED','SUBMISSION_RECORDED','ACKNOWLEDGEMENT_RECORDED','REJECTION_RECORDED')),
 mode text NOT NULL CHECK(mode IN ('TEST','LIVE')),report_type text NOT NULL CHECK(report_type IN ('STR','SAR')),
 reference text NOT NULL CHECK(length(reference) BETWEEN 1 AND 100),xml_content text NOT NULL CHECK(octet_length(xml_content)<=1048576),
 source_hash text NOT NULL CHECK(source_hash ~ '^[a-f0-9]{64}$'),source_snapshot jsonb NOT NULL,
 created_by uuid NOT NULL REFERENCES auth.users(id),updated_by uuid NOT NULL REFERENCES auth.users(id),updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.coreaml_filing_events (
 request_id uuid PRIMARY KEY,report_id uuid NOT NULL REFERENCES public.suspicious_transaction_reports(id),tenant_id text NOT NULL,
 actor_id uuid NOT NULL REFERENCES auth.users(id),action text NOT NULL CHECK(action IN ('SAVE','EXPORT','SUBMISSION','ACKNOWLEDGEMENT','REJECTION')),
 revision integer NOT NULL,input_hash text NOT NULL,result jsonb NOT NULL,evidence jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.coreaml_filing_exports (
 id uuid PRIMARY KEY REFERENCES public.coreaml_filing_events(request_id) DEFERRABLE INITIALLY DEFERRED,report_id uuid NOT NULL REFERENCES public.coreaml_filing_drafts(report_id),tenant_id text NOT NULL,
 revision integer NOT NULL,mode text NOT NULL CHECK(mode IN ('TEST','LIVE')),xml_content text NOT NULL,xml_hash text NOT NULL,schema_hash text NOT NULL,
 schema_label text NOT NULL,created_by uuid NOT NULL REFERENCES auth.users(id),created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX coreaml_filing_events_report_idx ON public.coreaml_filing_events(tenant_id,report_id,created_at);
ALTER TABLE public.coreaml_filing_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coreaml_filing_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coreaml_filing_exports ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_filing_drafts,public.coreaml_filing_events,public.coreaml_filing_exports FROM PUBLIC,anon,authenticated,service_role;
-- Existing trusted staff identity is reused; new roles or JWT claims are not introduced.
CREATE FUNCTION coreaml_private.filing_context(p_actor uuid,p_report uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;r public.suspicious_transaction_reports%ROWTYPE;c public.coreaml_case_claims%ROWTYPE;s public.coreaml_review_submissions%ROWTYPE;receipt public.coreaml_review_actions%ROWTYPE;source jsonb;txs jsonb;refs text[];linked integer;
BEGIN
 SELECT * INTO staff FROM public.user_profiles WHERE id=p_actor AND is_active IS TRUE AND role='head_of_compliance';
 IF NOT FOUND OR nullif(staff.tenant_id,'') IS NULL THEN RAISE EXCEPTION 'Active Head of Compliance required' USING ERRCODE='42501';END IF;
 SELECT * INTO r FROM public.suspicious_transaction_reports WHERE id=p_report AND tenant_id=staff.tenant_id AND status='APPROVED' AND locked_at IS NOT NULL AND reviewed_by IS NOT NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'Approved report unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO c FROM public.coreaml_case_claims WHERE anchor_alert_id=r.alert_id AND tenant_id=r.tenant_id AND investigator_id=r.generated_by AND case_reference=r.report_data->>'case_reference';
 IF NOT FOUND THEN RAISE EXCEPTION 'Approved case linkage unavailable' USING ERRCODE='42501';END IF;
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
CREATE FUNCTION public.coreaml_filing_read(p_report_id uuid DEFAULT NULL,p_offset integer DEFAULT 0,p_case_reference text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;ctx jsonb;rows jsonb;total integer;events jsonb;
BEGIN
 staff:=coreaml_private.review_staff();
 IF p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION 'Invalid reporting page' USING ERRCODE='22023';END IF;
 IF p_case_reference IS NOT NULL THEN
  IF p_report_id IS NOT NULL OR length(p_case_reference)>200 OR p_case_reference NOT LIKE 'CASE-%' THEN RAISE EXCEPTION 'Invalid approved case reference' USING ERRCODE='22023';END IF;
  SELECT id INTO p_report_id FROM public.suspicious_transaction_reports WHERE tenant_id=staff.tenant_id AND status='APPROVED' AND report_data->>'case_reference'=p_case_reference ORDER BY locked_at DESC,id LIMIT 1;
  IF p_report_id IS NULL THEN RAISE EXCEPTION 'Approved case unavailable' USING ERRCODE='42501';END IF;
 END IF;
 IF p_report_id IS NULL THEN
  SELECT count(*) INTO total FROM public.suspicious_transaction_reports WHERE tenant_id=staff.tenant_id AND status='APPROVED';
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.approved_at DESC,x.id),'[]') INTO rows FROM (SELECT r.id,r.report_data->>'case_reference' AS case_reference,r.locked_at AS approved_at,coalesce(cu.entity_name,nullif(concat_ws(' ',cu.first_name,cu.last_name),''),'Name not recorded') AS entity_name,f.state,f.mode,f.revision FROM public.suspicious_transaction_reports r LEFT JOIN public.alerts a ON a.id=r.alert_id AND a.tenant_id=r.tenant_id LEFT JOIN public.customers cu ON cu.id=a.customer_id AND cu.tenant_id=r.tenant_id LEFT JOIN public.coreaml_filing_drafts f ON f.report_id=r.id AND f.tenant_id=r.tenant_id WHERE r.tenant_id=staff.tenant_id AND r.status='APPROVED' ORDER BY r.locked_at DESC,r.id LIMIT 25 OFFSET p_offset) x;
  RETURN jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'rows',rows,'total',total,'offset',p_offset,'limit',25,'as_of',transaction_timestamp());
 END IF;
 ctx:=coreaml_private.filing_context(staff.id,p_report_id);
 SELECT coalesce(jsonb_agg(jsonb_build_object('request_id',e.request_id,'actor_id',e.actor_id,'action',e.action,'revision',e.revision,'at',e.created_at,'evidence',e.evidence) ORDER BY e.created_at DESC),'[]') INTO events FROM (SELECT * FROM public.coreaml_filing_events WHERE report_id=p_report_id AND tenant_id=staff.tenant_id ORDER BY created_at DESC LIMIT 101) e;
 IF jsonb_array_length(events)>100 THEN RAISE EXCEPTION 'Reporting history exceeds 100-entry display limit; contact administrator' USING ERRCODE='22023';END IF;
 RETURN ctx||jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'draft',(SELECT to_jsonb(f)-'source_snapshot' FROM public.coreaml_filing_drafts f WHERE report_id=p_report_id AND tenant_id=staff.tenant_id),'events',events,'as_of',transaction_timestamp());
END $$;
REVOKE ALL ON FUNCTION public.coreaml_filing_read(uuid,integer,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_filing_read(uuid,integer,text) TO authenticated;
-- Only the authenticated Edge Function's server client may commit. Browser claims cannot certify XML validation.
CREATE FUNCTION public.coreaml_filing_commit(p_actor uuid,p_report_id uuid,p_request_id uuid,p_action text,p_revision integer,p_source_hash text,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE ctx jsonb;d public.coreaml_filing_drafts%ROWTYPE;old public.coreaml_filing_events%ROWTYPE;fingerprint text;result jsonb;ev jsonb;new_state text;new_revision integer;export_row public.coreaml_filing_exports%ROWTYPE;
BEGIN
 IF p_actor IS NULL OR p_report_id IS NULL OR p_request_id IS NULL OR p_action IS NULL OR p_action NOT IN ('SAVE','EXPORT','SUBMISSION','ACKNOWLEDGEMENT','REJECTION') OR p_revision IS NULL OR p_revision<0 OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR pg_column_size(p_payload)>2097152 THEN RAISE EXCEPTION 'Invalid filing operation' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('filing-request:'||p_request_id::text,0));
 fingerprint:=encode(sha256(convert_to(jsonb_build_object('actor',p_actor,'report',p_report_id,'action',p_action,'revision',p_revision,'source_hash',p_source_hash,'payload',p_payload)::text,'UTF8')),'hex');
 ctx:=coreaml_private.filing_context(p_actor,p_report_id);
 SELECT * INTO old FROM public.coreaml_filing_events WHERE request_id=p_request_id;
 IF FOUND THEN IF old.actor_id<>p_actor OR old.report_id<>p_report_id OR old.input_hash<>fingerprint THEN RAISE EXCEPTION 'Request ID reused for different content' USING ERRCODE='22023';END IF;RETURN old.result||jsonb_build_object('replayed',true);END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('filing-report:'||p_report_id::text,0));
 ctx:=coreaml_private.filing_context(p_actor,p_report_id);
 IF p_source_hash IS DISTINCT FROM ctx->>'source_hash' THEN RAISE EXCEPTION 'Approved source changed; reload before preparing' USING ERRCODE='40001';END IF;
 SELECT * INTO d FROM public.coreaml_filing_drafts WHERE report_id=p_report_id FOR UPDATE;
 IF coalesce(d.revision,0)<>p_revision THEN RAISE EXCEPTION 'Reporting revision conflict; reload before retrying' USING ERRCODE='40001';END IF;
 new_revision:=p_revision;ev:='{}';
 IF p_action='SAVE' THEN
  IF d.state IN ('SUBMISSION_RECORDED','ACKNOWLEDGEMENT_RECORDED') THEN RAISE EXCEPTION 'Submitted report is frozen; record rejection before preparing a correction' USING ERRCODE='40001';END IF;
  IF p_payload->>'mode' IS NULL OR p_payload->>'mode' NOT IN ('TEST','LIVE') OR p_payload->>'report_type' IS NULL OR p_payload->>'report_type' NOT IN ('STR','SAR') OR length(btrim(coalesce(p_payload->>'reference','')))=0 OR length(p_payload->>'reference')>100 OR length(coalesce(p_payload->>'xml',''))=0 OR octet_length(p_payload->>'xml')>1048576 THEN RAISE EXCEPTION 'Complete report details and XML are required' USING ERRCODE='22023';END IF;
  IF p_payload->>'mode'='LIVE' AND (ctx->'source'->>'synthetic')::boolean THEN RAISE EXCEPTION 'Synthetic source cannot become a live report' USING ERRCODE='42501';END IF;
  new_revision:=p_revision+1;new_state:='PREPARED';
  INSERT INTO public.coreaml_filing_drafts(report_id,tenant_id,revision,state,mode,report_type,reference,xml_content,source_hash,source_snapshot,created_by,updated_by) VALUES(p_report_id,ctx->'source'->>'tenant_id',new_revision,new_state,p_payload->>'mode',p_payload->>'report_type',p_payload->>'reference',p_payload->>'xml',p_source_hash,ctx->'source',p_actor,p_actor)
  ON CONFLICT(report_id) DO UPDATE SET revision=EXCLUDED.revision,state=EXCLUDED.state,mode=EXCLUDED.mode,report_type=EXCLUDED.report_type,reference=EXCLUDED.reference,xml_content=EXCLUDED.xml_content,source_hash=EXCLUDED.source_hash,source_snapshot=EXCLUDED.source_snapshot,updated_by=p_actor,updated_at=clock_timestamp();
  ev:=jsonb_build_object('mode',p_payload->>'mode','report_type',p_payload->>'report_type','xml_hash',encode(sha256(convert_to(p_payload->>'xml','UTF8')),'hex'));
 ELSIF p_action='EXPORT' THEN
  IF d.report_id IS NULL OR d.state NOT IN ('PREPARED','EXPORTED') OR d.source_hash<>p_source_hash OR p_payload->>'schema_hash' IS NULL OR p_payload->>'schema_hash' !~ '^[a-f0-9]{64}$' OR length(coalesce(p_payload->>'schema_label','')) NOT BETWEEN 1 AND 200 OR p_payload->>'xml_hash' IS DISTINCT FROM encode(sha256(convert_to(d.xml_content,'UTF8')),'hex') THEN RAISE EXCEPTION 'Saved XML validation does not match this version' USING ERRCODE='40001';END IF;
  new_state:='EXPORTED';
  INSERT INTO public.coreaml_filing_exports(id,report_id,tenant_id,revision,mode,xml_content,xml_hash,schema_hash,schema_label,created_by) VALUES(p_request_id,p_report_id,d.tenant_id,d.revision,d.mode,d.xml_content,p_payload->>'xml_hash',p_payload->>'schema_hash',p_payload->>'schema_label',p_actor);
  ev:=jsonb_build_object('export_id',p_request_id,'mode',d.mode,'xml_hash',p_payload->>'xml_hash','schema_hash',p_payload->>'schema_hash','schema_label',p_payload->>'schema_label');
 ELSE
  IF d.report_id IS NULL THEN RAISE EXCEPTION 'Prepare and export a report first' USING ERRCODE='40001';END IF;
  IF length(btrim(coalesce(p_payload->>'reference','')))<3 OR length(p_payload->>'reference')>200 OR length(btrim(coalesce(p_payload->>'evidence_reference','')))<3 OR length(p_payload->>'evidence_reference')>500 OR length(coalesce(p_payload->>'notes',''))>10000 OR (p_payload->>'occurred_at') IS NULL THEN RAISE EXCEPTION 'Submission/response reference, evidence reference and date are required' USING ERRCODE='22023';END IF;
  IF (p_payload->>'occurred_at')::timestamptz>clock_timestamp()+interval '5 minutes' THEN RAISE EXCEPTION 'Outcome date cannot be in the future' USING ERRCODE='22023';END IF;
  IF p_action='SUBMISSION' THEN
   IF d.state<>'EXPORTED' THEN RAISE EXCEPTION 'Export the current version before recording submission' USING ERRCODE='40001';END IF;
   SELECT * INTO export_row FROM public.coreaml_filing_exports WHERE id::text=p_payload->>'export_id' AND report_id=p_report_id AND tenant_id=d.tenant_id AND revision=d.revision AND xml_hash=encode(sha256(convert_to(d.xml_content,'UTF8')),'hex');
   IF NOT FOUND THEN RAISE EXCEPTION 'Submission must reference the current export' USING ERRCODE='40001';END IF;
   IF (p_payload->>'occurred_at')::timestamptz<export_row.created_at-interval '5 minutes' THEN RAISE EXCEPTION 'Submission date precedes its export' USING ERRCODE='22023';END IF;new_state:='SUBMISSION_RECORDED';
  ELSE
   IF d.state<>'SUBMISSION_RECORDED' THEN RAISE EXCEPTION 'Record a submission before its outcome' USING ERRCODE='40001';END IF;
   IF NOT EXISTS(SELECT 1 FROM public.coreaml_filing_events e WHERE e.report_id=p_report_id AND e.tenant_id=d.tenant_id AND e.revision=d.revision AND e.action='SUBMISSION' AND e.request_id::text=p_payload->>'submission_id') THEN RAISE EXCEPTION 'Outcome must reference this version submission' USING ERRCODE='40001';END IF;
   IF (p_payload->>'occurred_at')::timestamptz<(SELECT (e.evidence->>'occurred_at')::timestamptz FROM public.coreaml_filing_events e WHERE e.request_id::text=p_payload->>'submission_id') THEN RAISE EXCEPTION 'Response date precedes its submission' USING ERRCODE='22023';END IF;
   new_state:=CASE WHEN p_action='ACKNOWLEDGEMENT' THEN 'ACKNOWLEDGEMENT_RECORDED' ELSE 'REJECTION_RECORDED' END;
  END IF;
  ev:=p_payload||jsonb_build_object('entry_source','HEAD_MANUAL_ENTRY','externally_verified',false,'mode',d.mode);
 END IF;
 IF p_action<>'SAVE' THEN UPDATE public.coreaml_filing_drafts SET state=new_state,updated_by=p_actor,updated_at=clock_timestamp() WHERE report_id=p_report_id;END IF;
 ev:=ev||jsonb_build_object('client_request_hash',p_payload->>'client_request_hash');
 result:=jsonb_build_object('request_id',p_request_id,'report_id',p_report_id,'actor_id',p_actor,'tenant_id',ctx->'source'->>'tenant_id','revision',new_revision,'state',new_state,'action',p_action,'replayed',false,'externally_verified',false);
 INSERT INTO public.coreaml_filing_events(request_id,report_id,tenant_id,actor_id,action,revision,input_hash,result,evidence) VALUES(p_request_id,p_report_id,ctx->'source'->>'tenant_id',p_actor,p_action,new_revision,fingerprint,result,ev);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_filing_commit(uuid,uuid,uuid,text,integer,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_filing_commit(uuid,uuid,uuid,text,integer,text,jsonb) TO service_role;
NOTIFY pgrst,'reload schema';
CREATE FUNCTION public.coreaml_filing_receipt(p_actor uuid,p_report_id uuid,p_request_id uuid,p_client_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e public.coreaml_filing_events%ROWTYPE;
BEGIN
 PERFORM coreaml_private.filing_context(p_actor,p_report_id);
 SELECT * INTO e FROM public.coreaml_filing_events WHERE request_id=p_request_id;
 IF NOT FOUND THEN RETURN NULL;END IF;
 IF e.actor_id<>p_actor OR e.report_id<>p_report_id OR e.evidence->>'client_request_hash' IS DISTINCT FROM p_client_hash THEN RAISE EXCEPTION 'Request ID reused for different content' USING ERRCODE='22023';END IF;
 RETURN e.result||jsonb_build_object('replayed',true)||CASE WHEN e.action='EXPORT' THEN (SELECT jsonb_build_object('xml',x.xml_content,'xml_hash',x.xml_hash) FROM public.coreaml_filing_exports x WHERE x.id=e.request_id) ELSE '{}'::jsonb END;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_filing_receipt(uuid,uuid,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_filing_receipt(uuid,uuid,uuid,text) TO service_role;
CREATE FUNCTION public.coreaml_filing_export_read(p_export_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;x public.coreaml_filing_exports%ROWTYPE;
BEGIN
 staff:=coreaml_private.review_staff();SELECT * INTO x FROM public.coreaml_filing_exports WHERE id=p_export_id AND tenant_id=staff.tenant_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Export unavailable' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'export_id',x.id,'report_id',x.report_id,'revision',x.revision,'mode',x.mode,'xml',x.xml_content,'xml_hash',x.xml_hash,'schema_label',x.schema_label,'schema_hash',x.schema_hash);
END $$;
REVOKE ALL ON FUNCTION public.coreaml_filing_export_read(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_filing_export_read(uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
