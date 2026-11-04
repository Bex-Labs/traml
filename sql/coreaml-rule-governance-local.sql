-- Local upgrade. Existing alerts, rules, review receipts and legacy triggers are preserved.
CREATE TABLE public.coreaml_rule_catalogue (
 code text NOT NULL, version integer NOT NULL CHECK(version>0), title text NOT NULL,
 algorithm text NOT NULL CHECK(algorithm IN ('AMOUNT_ABOVE','VELOCITY_COUNT','STRUCTURING_PATTERN','DORMANT_ACCOUNT_ACTIVITY')),
 description text NOT NULL, PRIMARY KEY(code,version)
);
INSERT INTO public.coreaml_rule_catalogue VALUES
 ('LARGE_TRANSFER',1,'Large individual transaction','AMOUNT_ABOVE','Transaction amount strictly greater than the bank-approved threshold in one currency; not a statutory cash-reporting rule.'),
 ('CREDIT_VELOCITY',1,'Frequent credits','VELOCITY_COUNT','Credit count at least the threshold in the inclusive event-time window, including the current transaction.'),
 ('CREDIT_STRUCTURING',1,'Multiple smaller credits','STRUCTURING_PATTERN','At least two credits individually below the threshold, with their sum at least the threshold, in one currency and time window.'),
 ('DORMANT_REACTIVATION',1,'Activity after dormancy','DORMANT_ACCOUNT_ACTIVITY','Elapsed days since the prior account transaction; first transactions have insufficient history.');
CREATE TABLE public.coreaml_rule_deployments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id text NOT NULL, source text NOT NULL CHECK(source IN ('BASELINE','CUSTOM')),
 catalogue_code text NOT NULL, catalogue_version integer NOT NULL, name text NOT NULL CHECK(length(btrim(name)) BETWEEN 3 AND 120),
 parameters jsonb NOT NULL, status text NOT NULL DEFAULT 'PROPOSED' CHECK(status IN ('PROPOSED','SHADOW','ACTIVE','PAUSED','REJECTED')),
 replaces_id uuid REFERENCES public.coreaml_rule_deployments(id), proposed_by uuid NOT NULL REFERENCES public.user_profiles(id),
 approved_by uuid REFERENCES public.user_profiles(id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), revision integer NOT NULL DEFAULT 1,
 FOREIGN KEY(catalogue_code,catalogue_version) REFERENCES public.coreaml_rule_catalogue(code,version)
);
CREATE UNIQUE INDEX coreaml_one_running_baseline ON public.coreaml_rule_deployments(tenant_id,catalogue_code,(parameters->>'currency'),(parameters->>'direction'),(coalesce(parameters->>'customer_type','ALL'))) WHERE source='BASELINE' AND status='ACTIVE';
CREATE TABLE public.coreaml_rule_events (
 request_id uuid PRIMARY KEY,tenant_id text NOT NULL,actor_id uuid NOT NULL,action text NOT NULL,payload jsonb NOT NULL,result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.coreaml_rule_results (
 transaction_id uuid NOT NULL REFERENCES public.transactions(id),deployment_id uuid NOT NULL REFERENCES public.coreaml_rule_deployments(id),tenant_id text NOT NULL,
 mode text NOT NULL CHECK(mode IN ('SHADOW','ACTIVE')),outcome text NOT NULL CHECK(outcome IN ('NO_MATCH','MATCH','FILTERED','INSUFFICIENT_HISTORY','ERROR')),
 evidence jsonb NOT NULL,alert_id uuid REFERENCES public.alerts(id),created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(transaction_id,deployment_id)
);
CREATE INDEX coreaml_rule_results_bank_date ON public.coreaml_rule_results(tenant_id,created_at);
CREATE TABLE public.coreaml_dismissal_reasons (
 request_id uuid PRIMARY KEY REFERENCES public.coreaml_review_submissions(request_id) DEFERRABLE INITIALLY DEFERRED,
 tenant_id text NOT NULL,actor_id uuid NOT NULL,alert_id uuid NOT NULL,expected_revision integer NOT NULL,
 reason_code text NOT NULL CHECK(reason_code IN ('LEGITIMATE_ACTIVITY','DUPLICATE_DETECTION','SOURCE_DATA_ERROR','RULE_CALIBRATION','DETECTION_DEFECT','OTHER')),
 reason_notes text NOT NULL CHECK(length(btrim(reason_notes)) BETWEEN 15 AND 4000),result jsonb,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE FUNCTION coreaml_private.governance_staff(p_write boolean DEFAULT false) RETURNS public.user_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid() FOR SHARE;
 IF NOT FOUND OR p.is_active IS NOT TRUE OR p.role NOT IN ('compliance_officer','head_of_compliance') OR nullif(p.tenant_id,'') IS NULL
 OR auth.jwt()->'app_metadata'->>'tenant_id' IS DISTINCT FROM p.tenant_id OR auth.jwt()->'app_metadata'->>'role' IS DISTINCT FROM p.role THEN RAISE EXCEPTION 'Active trusted compliance profile required' USING ERRCODE='42501';END IF;
 RETURN p;END $$;
CREATE FUNCTION coreaml_private.governance_parameters(p jsonb) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF jsonb_typeof(p) IS DISTINCT FROM 'object' OR NOT (p ?& ARRAY['currency','direction','threshold','window_hours'])
 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p) k WHERE k NOT IN ('currency','direction','threshold','window_hours','customer_type'))
 OR coalesce(p->>'currency','') !~ '^[A-Z]{3}$' OR coalesce(p->>'direction','') NOT IN ('CREDIT','DEBIT','BOTH')
 OR coalesce(p->>'threshold','') !~ '^[0-9]+([.][0-9]{1,2})?$' OR (p->>'threshold')::numeric<=0 OR (p->>'threshold')::numeric>100000000000000
 OR coalesce(p->>'window_hours','') !~ '^[0-9]+$' OR (p->>'window_hours')::numeric NOT BETWEEN 1 AND 8760 THEN RAISE EXCEPTION 'Currency, direction, positive threshold and bounded whole-hour window required' USING ERRCODE='22023';END IF;
END $$;
CREATE FUNCTION public.coreaml_rule_change(p_action text,p_payload jsonb,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;d public.coreaml_rule_deployments%ROWTYPE;c public.coreaml_rule_catalogue%ROWTYPE;e public.coreaml_rule_events%ROWTYPE;r jsonb;v_id uuid;v_status text;v_replace public.coreaml_rule_deployments%ROWTYPE;
BEGIN
 p:=coreaml_private.governance_staff(true);
 IF p_request_id IS NULL OR p_action IS NULL OR p_action NOT IN ('PROPOSE','APPROVE_SHADOW','ACTIVATE','PAUSE','REJECT') OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid rule request' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('rule-request:'||p_request_id::text,0));
 SELECT * INTO e FROM public.coreaml_rule_events WHERE request_id=p_request_id;
 IF FOUND THEN
 IF (e.tenant_id,e.actor_id) IS DISTINCT FROM (p.tenant_id,p.id) THEN RAISE EXCEPTION 'Request unavailable' USING ERRCODE='42501';END IF;
 IF (e.action,e.payload) IS DISTINCT FROM (p_action,p_payload) THEN RAISE EXCEPTION 'Request reused with different content' USING ERRCODE='22023';END IF;
 RETURN e.result||jsonb_build_object('replayed',true);END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('rule-bank:'||p.tenant_id,0));
 IF p_action='PROPOSE' THEN
 SELECT * INTO c FROM public.coreaml_rule_catalogue WHERE code=p_payload->>'catalogue_code' AND version=(p_payload->>'catalogue_version')::integer;
 IF NOT FOUND OR coalesce(p_payload->>'source','') NOT IN ('BASELINE','CUSTOM') THEN RAISE EXCEPTION 'Known catalogue version and origin required' USING ERRCODE='22023';END IF;
 PERFORM coreaml_private.governance_parameters(p_payload->'parameters');
 IF coalesce(p_payload#>>'{parameters,customer_type}','ALL')<>'ALL' AND NOT EXISTS(SELECT 1 FROM public.customers WHERE tenant_id=p.tenant_id AND customer_type::text=p_payload#>>'{parameters,customer_type}') THEN RAISE EXCEPTION 'Known customer type required for this bank' USING ERRCODE='22023';END IF;
 IF c.algorithm IN ('VELOCITY_COUNT','DORMANT_ACCOUNT_ACTIVITY') AND (p_payload#>>'{parameters,threshold}')::numeric<>trunc((p_payload#>>'{parameters,threshold}')::numeric) THEN RAISE EXCEPTION 'Whole count or days required' USING ERRCODE='22023';END IF;
 IF c.algorithm IN ('VELOCITY_COUNT','STRUCTURING_PATTERN') AND p_payload#>>'{parameters,direction}'<>'CREDIT' THEN RAISE EXCEPTION 'Credit-only scenario requires CREDIT direction' USING ERRCODE='22023';END IF;
 IF nullif(p_payload->>'replaces_id','') IS NOT NULL THEN
 SELECT * INTO v_replace FROM public.coreaml_rule_deployments WHERE id=(p_payload->>'replaces_id')::uuid AND tenant_id=p.tenant_id AND status='ACTIVE';
 IF NOT FOUND THEN RAISE EXCEPTION 'Active same-bank replacement target required' USING ERRCODE='42501';END IF;END IF;
 INSERT INTO public.coreaml_rule_deployments(tenant_id,source,catalogue_code,catalogue_version,name,parameters,proposed_by,replaces_id)
 VALUES(p.tenant_id,p_payload->>'source',c.code,c.version,p_payload->>'name',p_payload->'parameters',p.id,v_replace.id) RETURNING * INTO d;
 ELSE
 IF p.role<>'head_of_compliance' THEN RAISE EXCEPTION 'Head approval required' USING ERRCODE='42501';END IF;
 SELECT * INTO d FROM public.coreaml_rule_deployments WHERE id=(p_payload->>'deployment_id')::uuid AND tenant_id=p.tenant_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Deployment unavailable' USING ERRCODE='42501';END IF;
 IF d.revision IS DISTINCT FROM (p_payload->>'revision')::integer THEN RAISE EXCEPTION 'Deployment changed; refresh' USING ERRCODE='40001';END IF;
 IF length(btrim(coalesce(p_payload->>'notes','')))<15 OR length(p_payload->>'notes')>4000 THEN RAISE EXCEPTION 'Decision rationale of 15 to 4000 characters required' USING ERRCODE='22023';END IF;
 IF p_action='APPROVE_SHADOW' THEN
 IF d.status<>'PROPOSED' OR d.proposed_by=p.id THEN RAISE EXCEPTION 'Independent approval of a proposed version required' USING ERRCODE='42501';END IF;
 v_status:='SHADOW';
 ELSIF p_action='ACTIVATE' THEN
 IF d.status<>'SHADOW' OR d.approved_by IS NULL OR d.proposed_by=p.id OR NOT EXISTS(SELECT 1 FROM public.coreaml_rule_results WHERE deployment_id=d.id AND outcome IN ('MATCH','NO_MATCH')) OR EXISTS(SELECT 1 FROM public.coreaml_rule_results WHERE deployment_id=d.id AND outcome='ERROR') THEN RAISE EXCEPTION 'Independent approval, usable shadow evaluations and no recorded errors required' USING ERRCODE='42501';END IF;
 IF d.replaces_id IS NOT NULL THEN
 SELECT * INTO v_replace FROM public.coreaml_rule_deployments WHERE id=d.replaces_id AND tenant_id=p.tenant_id FOR UPDATE;
 IF NOT FOUND OR v_replace.status<>'ACTIVE' THEN RAISE EXCEPTION 'Replacement target changed' USING ERRCODE='40001';END IF;
 UPDATE public.coreaml_rule_deployments SET status='PAUSED',revision=revision+1,updated_at=now() WHERE id=v_replace.id;
 END IF;
 v_status:='ACTIVE';
 ELSIF p_action='PAUSE' THEN IF d.status NOT IN ('ACTIVE','SHADOW') THEN RAISE EXCEPTION 'Only running versions can be paused';END IF;v_status:='PAUSED';
 ELSE IF d.status<>'PROPOSED' THEN RAISE EXCEPTION 'Only proposals can be rejected';END IF;v_status:='REJECTED';END IF;
 UPDATE public.coreaml_rule_deployments SET status=v_status,approved_by=CASE WHEN p_action='APPROVE_SHADOW' THEN p.id ELSE approved_by END,revision=revision+1,updated_at=now() WHERE id=d.id RETURNING * INTO d;
 END IF;
 r:=jsonb_build_object('request_id',p_request_id,'actor_id',p.id,'tenant_id',p.tenant_id,'action',p_action,'deployment_id',d.id,'status',d.status,'revision',d.revision,'replayed',false);
 INSERT INTO public.coreaml_rule_events VALUES(p_request_id,p.tenant_id,p.id,p_action,p_payload,r,now());RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.coreaml_submit_case_review(p_alert_id uuid, p_kind text, p_expected_revision integer, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 IF p_kind='QA' AND NOT EXISTS(SELECT 1 FROM public.coreaml_dismissal_reasons r WHERE r.request_id=p_request_id AND r.tenant_id=p.tenant_id AND r.actor_id=p.id AND r.alert_id=p_alert_id AND r.expected_revision=p_expected_revision AND r.result IS NULL) THEN RAISE EXCEPTION 'Choose a structured dismissal reason before submitting' USING ERRCODE='22023';END IF;
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
END $function$
;
CREATE FUNCTION public.coreaml_submit_dismissal(p_alert_id uuid,p_expected_revision integer,p_reason_code text,p_reason_notes text,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;s public.coreaml_dismissal_reasons%ROWTYPE;r jsonb;BEGIN
 p:=coreaml_private.governance_staff(true);IF p.role<>'compliance_officer' THEN RAISE EXCEPTION 'Owning officer required' USING ERRCODE='42501';END IF;
 IF p_request_id IS NULL OR p_reason_code IS NULL OR p_reason_code NOT IN ('LEGITIMATE_ACTIVITY','DUPLICATE_DETECTION','SOURCE_DATA_ERROR','RULE_CALIBRATION','DETECTION_DEFECT','OTHER') OR length(btrim(coalesce(p_reason_notes,''))) NOT BETWEEN 15 AND 4000 THEN RAISE EXCEPTION 'Choose a reason and supporting explanation of 15 to 4000 characters' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('dismissal:'||p_request_id::text,0));
 SELECT * INTO s FROM public.coreaml_dismissal_reasons WHERE request_id=p_request_id;
 IF FOUND THEN
 IF (s.tenant_id,s.actor_id) IS DISTINCT FROM (p.tenant_id,p.id) THEN RAISE EXCEPTION 'Request unavailable' USING ERRCODE='42501';END IF;
 IF (s.alert_id,s.expected_revision,s.reason_code,s.reason_notes) IS DISTINCT FROM (p_alert_id,p_expected_revision,p_reason_code,p_reason_notes) THEN RAISE EXCEPTION 'Request reused with different content' USING ERRCODE='22023';END IF;
 RETURN s.result||jsonb_build_object('replayed',true);END IF;
 IF EXISTS(SELECT 1 FROM public.coreaml_review_submissions WHERE request_id=p_request_id) THEN RAISE EXCEPTION 'Existing submissions cannot be retrospectively classified' USING ERRCODE='22023';END IF;
 INSERT INTO public.coreaml_dismissal_reasons(request_id,tenant_id,actor_id,alert_id,expected_revision,reason_code,reason_notes) VALUES(p_request_id,p.tenant_id,p.id,p_alert_id,p_expected_revision,p_reason_code,p_reason_notes);
 r:=public.coreaml_submit_case_review(p_alert_id,'QA',p_expected_revision,p_request_id);
 UPDATE public.coreaml_dismissal_reasons SET result=r WHERE request_id=p_request_id;RETURN r;
END $$;
-- Enrich the authorized QA snapshot; original membership, maker/checker and token checks remain authoritative.
ALTER FUNCTION public.coreaml_load_review(text,uuid) RENAME TO coreaml_load_review_before_governance;
REVOKE ALL ON FUNCTION public.coreaml_load_review_before_governance(text,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.coreaml_load_review(p_kind text,p_target_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r jsonb;v_reason jsonb;BEGIN
 r:=public.coreaml_load_review_before_governance(p_kind,p_target_id);
 IF p_kind='QA' THEN
 SELECT jsonb_build_object('code',d.reason_code,'notes',d.reason_notes,'request_id',d.request_id) INTO v_reason
 FROM public.coreaml_dismissal_reasons d JOIN public.coreaml_review_submissions s ON s.request_id=d.request_id
 WHERE d.tenant_id=r->>'tenant_id' AND d.actor_id=(r->>'maker_id')::uuid AND d.result->>'case_reference'=r->>'case_reference'
 AND s.result->>'revision'=r->>'revision' ORDER BY d.created_at DESC LIMIT 1;
 r:=r||jsonb_build_object('dismissal_reason',v_reason);END IF;RETURN r;
END $$;
CREATE FUNCTION coreaml_private.governance_lock_account() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN PERFORM 1 FROM public.accounts WHERE id=NEW.account_id FOR UPDATE;RETURN NEW;END $$;
CREATE TRIGGER aa_governance_lock BEFORE INSERT ON public.transactions FOR EACH ROW EXECUTE FUNCTION coreaml_private.governance_lock_account();
CREATE FUNCTION coreaml_private.governance_evaluate() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE bank text;customer uuid;v_customer_type text;d record;v_count integer;v_total numeric;v_previous timestamptz;v_match boolean;v_outcome text;v_evidence jsonb;v_alert uuid;v_threshold numeric;v_window timestamptz;v_ids jsonb;v_error text;
BEGIN
 SELECT c.tenant_id,c.id,c.customer_type::text INTO bank,customer,v_customer_type FROM public.accounts a JOIN public.customers c ON c.id=a.customer_id WHERE a.id=NEW.account_id;
 FOR d IN SELECT x.*,c.algorithm FROM public.coreaml_rule_deployments x JOIN public.coreaml_rule_catalogue c ON (c.code,c.version)=(x.catalogue_code,x.catalogue_version) WHERE x.tenant_id=bank AND x.status IN ('SHADOW','ACTIVE') ORDER BY x.id LOOP
 BEGIN
 v_alert:=NULL;v_match:=false;v_count:=0;v_total:=0;v_previous:=NULL;v_ids:='[]';v_outcome:='NO_MATCH';v_threshold:=(d.parameters->>'threshold')::numeric;
 v_window:=NEW.transaction_timestamp-make_interval(hours=>(d.parameters->>'window_hours')::integer);
 v_evidence:=jsonb_build_object('engine','coreaml-governance-1','origin',d.source,'deployment_id',d.id,'catalogue_code',d.catalogue_code,'catalogue_version',d.catalogue_version,'parameters',d.parameters,'mode',d.status,'transaction_amount',NEW.amount,'currency',NEW.currency,'transaction_reference',NEW.transaction_reference,'transaction_id',NEW.id,'account_id',NEW.account_id,'transaction_snapshot',jsonb_build_object('id',NEW.id,'amount',NEW.amount,'currency',NEW.currency,'account_id',NEW.account_id,'transaction_type',NEW.transaction_type,'transaction_timestamp',NEW.transaction_timestamp,'transaction_reference',NEW.transaction_reference),'window_start',v_window,'window_end',NEW.transaction_timestamp,'comparison',CASE d.algorithm WHEN 'AMOUNT_ABOVE' THEN 'amount > threshold' WHEN 'VELOCITY_COUNT' THEN 'credit count >= threshold' WHEN 'STRUCTURING_PATTERN' THEN 'each credit < threshold; sum >= threshold; count >= 2' ELSE 'elapsed days >= threshold' END);
 IF (coalesce(d.parameters->>'customer_type','ALL')<>'ALL' AND v_customer_type IS DISTINCT FROM d.parameters->>'customer_type') OR NEW.currency::text IS DISTINCT FROM d.parameters->>'currency' OR (d.parameters->>'direction'<>'BOTH' AND NEW.transaction_type::text IS DISTINCT FROM d.parameters->>'direction') THEN v_outcome:='FILTERED';
 ELSIF d.algorithm='AMOUNT_ABOVE' THEN v_match:=NEW.amount>v_threshold;
 ELSIF d.algorithm IN ('VELOCITY_COUNT','STRUCTURING_PATTERN') THEN
 SELECT count(*),coalesce(sum(t.amount),0),coalesce(jsonb_agg(t.id ORDER BY t.transaction_timestamp,t.id),'[]') INTO v_count,v_total,v_ids FROM (SELECT t.* FROM public.transactions t
 WHERE t.account_id=NEW.account_id AND t.currency=NEW.currency AND t.transaction_type::text='CREDIT' AND t.transaction_timestamp BETWEEN v_window AND NEW.transaction_timestamp

 AND (d.algorithm<>'STRUCTURING_PATTERN' OR t.amount<v_threshold) ORDER BY t.transaction_timestamp,t.id LIMIT 10001) t;
 IF v_count>10000 THEN RAISE EXCEPTION 'Bounded history exceeded';END IF;
 v_match:=CASE WHEN d.algorithm='VELOCITY_COUNT' THEN v_count>=v_threshold ELSE NEW.amount<v_threshold AND v_count>=2 AND v_total>=v_threshold END;
 ELSIF d.algorithm='DORMANT_ACCOUNT_ACTIVITY' THEN
 SELECT max(t.transaction_timestamp) INTO v_previous FROM public.transactions t WHERE t.account_id=NEW.account_id AND t.transaction_timestamp<=NEW.transaction_timestamp AND t.id<>NEW.id;
 IF v_previous IS NULL THEN v_outcome:='INSUFFICIENT_HISTORY';ELSE v_match:=extract(epoch FROM (NEW.transaction_timestamp-v_previous))/86400>=v_threshold;END IF;
 END IF;
 IF v_match THEN v_outcome:='MATCH';END IF;
 v_evidence:=v_evidence||jsonb_build_object('matched',v_match,'transaction_count',v_count,'total_amount',v_total,'transaction_ids',v_ids,'previous_transaction_at',v_previous,'evaluated_at',clock_timestamp());
 IF v_match AND d.status='ACTIVE' THEN
 INSERT INTO public.alerts(alert_ref,customer_id,transaction_id,tenant_id,rule_triggered,severity,status,details,evidence,idempotency_key)
 VALUES('ALT-'||upper(substr(gen_random_uuid()::text,1,8)),customer,NEW.id,bank,d.name,CASE WHEN d.algorithm='VELOCITY_COUNT' THEN 'MEDIUM' ELSE 'HIGH' END,'UNASSIGNED',
 d.name||': '||NEW.currency::text||' '||NEW.amount::text||'; '||(v_evidence->>'comparison')||'; threshold='||v_threshold::text||'; count='||v_count::text||'; sum='||v_total::text,
 v_evidence,'GOV:'||d.id::text||':'||NEW.id::text) RETURNING id INTO v_alert;
 END IF;
 INSERT INTO public.coreaml_rule_results(transaction_id,deployment_id,tenant_id,mode,outcome,evidence,alert_id) VALUES(NEW.id,d.id,bank,d.status,v_outcome,v_evidence,v_alert);
 EXCEPTION WHEN OTHERS THEN
 GET STACKED DIAGNOSTICS v_error=RETURNED_SQLSTATE;
 INSERT INTO public.coreaml_rule_results(transaction_id,deployment_id,tenant_id,mode,outcome,evidence) VALUES(NEW.id,d.id,bank,d.status,'ERROR',jsonb_build_object('error_code',v_error,'engine','coreaml-governance-1'));
 END;
 END LOOP;RETURN NEW;
END $$;
CREATE TRIGGER governance_evaluate AFTER INSERT ON public.transactions FOR EACH ROW EXECUTE FUNCTION coreaml_private.governance_evaluate();
CREATE FUNCTION public.coreaml_rule_workspace() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;r jsonb;BEGIN p:=coreaml_private.governance_staff(false);
 SELECT jsonb_build_object('tenant_id',p.tenant_id,'actor_id',p.id,'role',p.role,'server_time',now(),
 'segments',(SELECT coalesce(jsonb_agg(t),'[]') FROM (SELECT DISTINCT customer_type::text AS customer_type FROM public.customers WHERE tenant_id=p.tenant_id AND customer_type IS NOT NULL) t),
 'catalogue',(SELECT jsonb_agg(to_jsonb(c) ORDER BY code,version) FROM public.coreaml_rule_catalogue c),
 'deployments',(SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC),'[]') FROM (SELECT d.*,c.algorithm,(SELECT count(*) FROM public.coreaml_rule_results x WHERE x.deployment_id=d.id) AS evaluations,(SELECT count(*) FROM public.coreaml_rule_results x WHERE x.deployment_id=d.id AND outcome='MATCH') AS matches,(SELECT count(*) FROM public.coreaml_rule_results x WHERE x.deployment_id=d.id AND outcome='ERROR') AS errors,(SELECT count(DISTINCT x.alert_id) FROM public.coreaml_rule_results x JOIN public.coreaml_review_actions a ON a.tenant_id=x.tenant_id AND a.kind='QA' AND a.decision='APPROVE' AND a.result->'alert_ids' ? x.alert_id::text WHERE x.deployment_id=d.id) AS dismissed_alerts FROM public.coreaml_rule_deployments d JOIN public.coreaml_rule_catalogue c ON (c.code,c.version)=(d.catalogue_code,d.catalogue_version) WHERE d.tenant_id=p.tenant_id ORDER BY d.created_at DESC LIMIT 200) q),
 'events',(SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC),'[]') FROM (SELECT request_id,actor_id,action,payload,result,created_at FROM public.coreaml_rule_events WHERE tenant_id=p.tenant_id ORDER BY created_at DESC LIMIT 200) q),
 'legacy_rules',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT id,rule_name,condition_type,threshold_value,time_window_hours,status FROM public.aml_rules WHERE tenant_id=p.tenant_id ORDER BY created_at DESC LIMIT 200) q),
 'legacy_detectors',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',t.tgname,'enabled',t.tgenabled='O')),'[]') FROM pg_trigger t WHERE t.tgrelid='public.transactions'::regclass AND t.tgname IN ('trigger_aml_engine','trigger_behavioral_anomaly','trigger_mule_ring_eval','trigger_sanctions_screening')),
 'health',jsonb_build_object('trigger_enabled',EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.transactions'::regclass AND tgname='governance_evaluate' AND tgenabled='O'),'active_deployments',(SELECT count(*) FROM public.coreaml_rule_deployments WHERE tenant_id=p.tenant_id AND status='ACTIVE'),'latest_evaluation',(SELECT max(created_at) FROM public.coreaml_rule_results WHERE tenant_id=p.tenant_id),'evaluation_errors',(SELECT count(*) FROM public.coreaml_rule_results WHERE tenant_id=p.tenant_id AND outcome='ERROR')),
 'dismissal_feedback',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT d.reason_code,count(*) AS submissions,count(*) FILTER(WHERE a.decision='APPROVE') AS approved,count(*) FILTER(WHERE a.decision='REJECT') AS returned FROM public.coreaml_dismissal_reasons d LEFT JOIN public.coreaml_review_actions a ON a.kind='QA' AND a.tenant_id=d.tenant_id AND a.expected_token IS NOT NULL AND a.target_id=d.alert_id AND a.result->>'case_reference'=d.result->>'case_reference' AND a.created_at>=d.created_at AND NOT EXISTS(SELECT 1 FROM public.coreaml_review_submissions next WHERE next.tenant_id=d.tenant_id AND next.case_reference=d.result->>'case_reference' AND next.kind='QA' AND next.created_at>d.created_at AND next.created_at<=a.created_at) WHERE d.tenant_id=p.tenant_id AND (p.role='head_of_compliance' OR d.actor_id=p.id) GROUP BY d.reason_code) q)
 ) INTO r;RETURN r;END $$;
-- New tables are readable through the scoped RPCs only. No browser can write catalogue, receipts or results directly.
ALTER TABLE public.coreaml_rule_catalogue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coreaml_rule_deployments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coreaml_rule_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coreaml_rule_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.coreaml_dismissal_reasons ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_rule_catalogue,public.coreaml_rule_deployments,public.coreaml_rule_events,public.coreaml_rule_results,public.coreaml_dismissal_reasons FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION coreaml_private.governance_staff(boolean),coreaml_private.governance_parameters(jsonb),coreaml_private.governance_lock_account(),coreaml_private.governance_evaluate() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.coreaml_rule_change(text,jsonb,uuid),public.coreaml_rule_workspace(),public.coreaml_submit_dismissal(uuid,integer,text,text,uuid),public.coreaml_load_review(text,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_rule_change(text,jsonb,uuid),public.coreaml_rule_workspace(),public.coreaml_submit_dismissal(uuid,integer,text,text,uuid),public.coreaml_load_review(text,uuid) TO authenticated;

-- Retire browser-side writes through the legacy builder; old rules continue executing unchanged.
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.aml_rules FROM PUBLIC,anon,authenticated;
-- Preserve the old implementation for saved-draft operations and exact legacy closure replay.
ALTER FUNCTION public.coreaml_case_action(uuid,text,integer,uuid,text,jsonb) RENAME TO coreaml_case_action_before_governance;
REVOKE ALL ON FUNCTION public.coreaml_case_action_before_governance(uuid,text,integer,uuid,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.coreaml_case_action(p_alert_id uuid,p_action text,p_expected_revision integer,p_request_id uuid,p_narrative text DEFAULT NULL,p_snapshot jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 p:=coreaml_private.case_workflow_staff(true);
 IF p_action='CLOSE' AND NOT EXISTS(SELECT 1 FROM public.coreaml_case_actions WHERE request_id=p_request_id AND actor_id=p.id AND tenant_id=p.tenant_id AND action='CLOSE') THEN RAISE EXCEPTION 'Submit a structured dismissal for independent review; direct closure is unavailable' USING ERRCODE='42501';END IF;
 RETURN public.coreaml_case_action_before_governance(p_alert_id,p_action,p_expected_revision,p_request_id,p_narrative,p_snapshot);
END $$;
REVOKE ALL ON FUNCTION public.coreaml_case_action(uuid,text,integer,uuid,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_case_action(uuid,text,integer,uuid,text,jsonb) TO authenticated;

NOTIFY pgrst,'reload schema';
