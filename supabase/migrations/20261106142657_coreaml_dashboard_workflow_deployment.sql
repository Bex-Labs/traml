-- source case-claim
-- Local claim foundation. Install as postgres in sentinel-aml only.
-- Existing alert evidence/details, risk triggers and financial data are untouched.
ALTER TABLE public.alerts ADD COLUMN IF NOT EXISTS case_reference text;

CREATE TABLE public.coreaml_case_claims (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    anchor_alert_id uuid NOT NULL REFERENCES public.alerts(id),
    tenant_id text NOT NULL,
    investigator_id uuid NOT NULL REFERENCES auth.users(id),
    case_reference text NOT NULL UNIQUE,
    alert_ids uuid[] NOT NULL CHECK (cardinality(alert_ids) > 0),
    claimed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.coreaml_case_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_case_claims FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.coreaml_case_claims TO authenticated;
CREATE POLICY case_claim_bank_read ON public.coreaml_case_claims
FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.user_profiles p
        WHERE p.id = auth.uid() AND p.is_active IS TRUE
        AND p.tenant_id = coreaml_case_claims.tenant_id
        AND p.role IN ('compliance_officer', 'head_of_compliance'))
);

-- The browser cannot take or transfer case ownership outside the RPC.
-- Other workflow transitions are intentionally unchanged in this claim-only slice.
CREATE FUNCTION coreaml_private.guard_case_ownership() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
    IF current_user IN ('authenticated', 'anon') THEN
        IF NEW.assigned_user_id IS DISTINCT FROM OLD.assigned_user_id
            OR NEW.case_reference IS DISTINCT FROM OLD.case_reference
            OR (NEW.status = 'INVESTIGATING' AND NEW.status IS DISTINCT FROM OLD.status) THEN
            RAISE EXCEPTION 'Case ownership must be changed through the authorized claim function' USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION coreaml_private.guard_case_ownership() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER coreaml_guard_case_ownership BEFORE UPDATE ON public.alerts
FOR EACH ROW EXECUTE FUNCTION coreaml_private.guard_case_ownership();

CREATE FUNCTION public.coreaml_claim_case(p_alert_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    actor uuid := auth.uid();
    staff public.user_profiles%ROWTYPE;
    anchor public.alerts%ROWTYPE;
    receipt public.coreaml_case_claims%ROWTYPE;
    ids uuid[];
    changed integer;
    ref text;
BEGIN
    IF actor IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501'; END IF;
    SELECT * INTO staff FROM public.user_profiles WHERE id = actor FOR SHARE;
    IF NOT FOUND OR staff.is_active IS NOT TRUE OR staff.role <> 'compliance_officer'
        OR staff.tenant_id IS NULL OR staff.tenant_id = ''
        OR (auth.jwt()->'app_metadata'->>'tenant_id') IS DISTINCT FROM staff.tenant_id
        OR (auth.jwt()->'app_metadata'->>'role') IS DISTINCT FROM staff.role THEN
        RAISE EXCEPTION 'Active compliance officer and matching trusted bank required' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO anchor FROM public.alerts WHERE id = p_alert_id AND tenant_id = staff.tenant_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Alert unavailable' USING ERRCODE = '42501'; END IF;
    -- Same-customer calls serialize before any row locks, including different anchors.
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
        staff.tenant_id || ':' || coalesce(anchor.customer_id::text, anchor.id::text), 0));
    -- Ordered locks prevent two officers splitting or stealing one unified claim.
    PERFORM a.id FROM public.alerts a WHERE a.tenant_id = staff.tenant_id
        AND (a.id = p_alert_id OR (anchor.customer_id IS NOT NULL AND a.customer_id = anchor.customer_id))
        ORDER BY a.id FOR UPDATE;
    SELECT * INTO anchor FROM public.alerts WHERE id = p_alert_id AND tenant_id = staff.tenant_id;
    IF anchor.status = 'INVESTIGATING' AND anchor.assigned_user_id = actor THEN
        SELECT * INTO receipt FROM public.coreaml_case_claims
            WHERE case_reference = anchor.case_reference AND investigator_id = actor AND tenant_id = staff.tenant_id;
        IF FOUND AND p_alert_id = ANY(receipt.alert_ids) THEN
            RETURN jsonb_build_object('case_reference',receipt.case_reference,'alert_ids',receipt.alert_ids,
                'investigator_id',actor,'replayed',true);
        END IF;
    END IF;
    IF anchor.status IS DISTINCT FROM 'UNASSIGNED' OR anchor.assigned_user_id IS NOT NULL
        OR anchor.case_reference IS NOT NULL THEN
        RAISE EXCEPTION 'Alert already claimed or unavailable for claiming' USING ERRCODE = 'P0001';
    END IF;
    IF anchor.customer_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.alerts a WHERE a.customer_id = anchor.customer_id AND a.tenant_id = staff.tenant_id
            AND a.status = 'INVESTIGATING'
    ) THEN
        RAISE EXCEPTION 'Customer already has an active investigation; refresh the queue' USING ERRCODE = 'P0001';
    END IF;
    SELECT array_agg(a.id ORDER BY a.id) INTO ids FROM public.alerts a
        WHERE a.tenant_id = staff.tenant_id AND a.status = 'UNASSIGNED'
        AND a.assigned_user_id IS NULL AND a.case_reference IS NULL
        AND (a.id = p_alert_id OR (anchor.customer_id IS NOT NULL AND a.customer_id = anchor.customer_id));
    IF ids IS NULL OR NOT (p_alert_id = ANY(ids)) THEN
        RAISE EXCEPTION 'No eligible alerts remain' USING ERRCODE = 'P0001';
    END IF;
    ref := 'CASE-' || gen_random_uuid()::text;
    UPDATE public.alerts SET status = 'INVESTIGATING', assigned_user_id = actor, case_reference = ref
        WHERE id = ANY(ids) AND tenant_id = staff.tenant_id AND status = 'UNASSIGNED'
            AND assigned_user_id IS NULL AND case_reference IS NULL;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed <> cardinality(ids) THEN RAISE EXCEPTION 'Incomplete claim; no alerts claimed'; END IF;
    INSERT INTO public.coreaml_case_claims(anchor_alert_id,tenant_id,investigator_id,case_reference,alert_ids)
        VALUES (p_alert_id,staff.tenant_id,actor,ref,ids);
    INSERT INTO public.system_events(event_type,severity,message,tenant_id,user_id,metadata)
        VALUES ('ENTITY_CASE_CLAIMED','INFO','Unified case claimed',staff.tenant_id::uuid,actor,
            jsonb_build_object('case_ref',ref,'alert_ids',ids,'anchor_alert_id',p_alert_id));
    RETURN jsonb_build_object('case_reference',ref,'alert_ids',ids,'investigator_id',actor,'replayed',false);
END;
$$;
ALTER FUNCTION public.coreaml_claim_case(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.coreaml_claim_case(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_claim_case(uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';

-- source case-workflow
-- Local owner-managed draft and closure foundation. Existing evidence is immutable.
ALTER TABLE public.investigation_drafts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.investigation_drafts FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.investigation_drafts TO authenticated;
REVOKE TRUNCATE,TRIGGER,REFERENCES ON public.alerts FROM PUBLIC,anon,authenticated;
ALTER TABLE public.investigation_drafts ADD COLUMN case_reference text REFERENCES public.coreaml_case_claims(case_reference);
ALTER TABLE public.investigation_drafts ADD COLUMN revision integer NOT NULL DEFAULT 0 CHECK (revision>=0);
ALTER TABLE public.investigation_drafts ADD COLUMN closed_at timestamptz;
ALTER TABLE public.investigation_drafts DROP CONSTRAINT investigation_drafts_status_check;
ALTER TABLE public.investigation_drafts ADD CONSTRAINT investigation_drafts_status_check CHECK (status IN ('IN_PROGRESS','SUBMITTED','DISCARDED','CLOSED'));

CREATE TABLE public.coreaml_case_actions (
 request_id uuid PRIMARY KEY,
 case_reference text NOT NULL REFERENCES public.coreaml_case_claims(case_reference),
 actor_id uuid NOT NULL REFERENCES auth.users(id),
 tenant_id text NOT NULL,
 action text NOT NULL CHECK (action IN ('SAVE','CLOSE')),
 payload jsonb NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.coreaml_case_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_case_actions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.coreaml_case_actions TO authenticated;
CREATE POLICY case_action_read ON public.coreaml_case_actions FOR SELECT TO authenticated USING (
 EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.is_active IS TRUE AND p.tenant_id=coreaml_case_actions.tenant_id
 AND ((p.role='compliance_officer' AND p.id=coreaml_case_actions.actor_id) OR p.role='head_of_compliance'))
);
CREATE POLICY case_draft_boundary ON public.investigation_drafts AS RESTRICTIVE FOR ALL TO authenticated USING (
 case_reference IS NOT NULL AND EXISTS(SELECT 1 FROM public.user_profiles p JOIN public.coreaml_case_claims c ON c.case_reference=investigation_drafts.case_reference
 WHERE p.id=auth.uid() AND p.is_active IS TRUE AND p.tenant_id=investigation_drafts.tenant_id AND c.tenant_id=p.tenant_id
 AND c.anchor_alert_id=investigation_drafts.alert_id AND c.investigator_id=investigation_drafts.investigator_id
 AND ((p.role='compliance_officer' AND p.id=c.investigator_id) OR p.role='head_of_compliance'))
) WITH CHECK (false);

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
REVOKE ALL ON FUNCTION coreaml_private.case_workflow_staff(boolean) FROM PUBLIC,anon,authenticated;

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
REVOKE ALL ON FUNCTION coreaml_private.case_workflow_context(uuid,boolean) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION coreaml_private.case_workflow_pins(p_snapshot jsonb,p_tenant text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;value text;identifier uuid;seen uuid[]:='{}';refs text[]:='{}';entities jsonb:='[]';label text;
BEGIN
 IF jsonb_typeof(p_snapshot) IS DISTINCT FROM 'object' OR (p_snapshot-'entity_ids'-'transaction_refs')<>'{}'::jsonb
 OR jsonb_typeof(p_snapshot->'entity_ids') IS DISTINCT FROM 'array' OR jsonb_typeof(p_snapshot->'transaction_refs') IS DISTINCT FROM 'array'
 OR jsonb_array_length(p_snapshot->'entity_ids')>100 OR jsonb_array_length(p_snapshot->'transaction_refs')>200 OR pg_column_size(p_snapshot)>131072 THEN RAISE EXCEPTION 'Invalid or oversized evidence pins' USING ERRCODE='22023';END IF;
 FOR e IN SELECT * FROM jsonb_array_elements(p_snapshot->'entity_ids') LOOP
  IF jsonb_typeof(e)<>'string' THEN RAISE EXCEPTION 'Invalid entity pin' USING ERRCODE='22023';END IF;
  identifier:=(e#>>'{}')::uuid;
  IF identifier=ANY(seen) THEN RAISE EXCEPTION 'Duplicate entity pin' USING ERRCODE='22023';END IF;
  SELECT coalesce(nullif(entity_name,''),nullif(concat_ws(' ',first_name,last_name),''),'Unknown entity') INTO label FROM public.customers WHERE id=identifier AND tenant_id=p_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pinned entity unavailable' USING ERRCODE='42501';END IF;
  seen:=array_append(seen,identifier);entities:=entities||jsonb_build_array(jsonb_build_object('id',identifier,'name',label));
 END LOOP;
 FOR e IN SELECT * FROM jsonb_array_elements(p_snapshot->'transaction_refs') LOOP
  IF jsonb_typeof(e)<>'string' THEN RAISE EXCEPTION 'Invalid transaction pin' USING ERRCODE='22023';END IF;value:=e#>>'{}';
  IF length(value)<1 OR length(value)>512 OR value=ANY(refs) THEN RAISE EXCEPTION 'Invalid or duplicate transaction pin' USING ERRCODE='22023';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id JOIN public.customers c ON c.id=a.customer_id WHERE t.transaction_reference=value AND c.tenant_id=p_tenant) THEN RAISE EXCEPTION 'Pinned transaction unavailable' USING ERRCODE='42501';END IF;
  refs:=array_append(refs,value);
 END LOOP;
 RETURN jsonb_build_object('entities',entities,'txs',to_jsonb(refs));
END $$;
REVOKE ALL ON FUNCTION coreaml_private.case_workflow_pins(jsonb,text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.coreaml_load_case_draft(p_alert_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE ctx jsonb;d public.investigation_drafts%ROWTYPE;
BEGIN
 ctx:=coreaml_private.case_workflow_context(p_alert_id,false);
 SELECT * INTO d FROM public.investigation_drafts WHERE alert_id=(ctx->>'alert_id')::uuid AND investigator_id=(ctx->>'owner_id')::uuid;
 IF FOUND THEN
  IF d.case_reference IS DISTINCT FROM ctx->>'case_reference' OR d.tenant_id IS DISTINCT FROM ctx->>'tenant_id' THEN RAISE EXCEPTION 'Draft linkage unavailable';END IF;
  RETURN to_jsonb(d)||ctx||jsonb_build_object('exists',true);
 END IF;
 RETURN ctx||jsonb_build_object('exists',false,'id',null,'revision',0,'status','IN_PROGRESS','draft_narrative','','evidence_snapshot',jsonb_build_object('entities','[]'::jsonb,'txs','[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.coreaml_load_case_draft(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_load_case_draft(uuid) TO authenticated;

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
REVOKE ALL ON FUNCTION public.coreaml_case_action(uuid,text,integer,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_action(uuid,text,integer,uuid,text,jsonb) TO authenticated;

CREATE FUNCTION coreaml_private.guard_managed_draft() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF current_user IN ('authenticated','anon') THEN RAISE EXCEPTION 'Case drafts are server managed' USING ERRCODE='42501';END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.guard_managed_draft() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER coreaml_guard_managed_draft BEFORE INSERT OR UPDATE OR DELETE ON public.investigation_drafts FOR EACH ROW EXECUTE FUNCTION coreaml_private.guard_managed_draft();
CREATE OR REPLACE FUNCTION coreaml_private.guard_case_ownership() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF TG_OP='DELETE' THEN
  IF current_user IN ('authenticated','anon') AND OLD.case_reference IS NOT NULL THEN RAISE EXCEPTION 'Claimed alerts are server managed' USING ERRCODE='42501';END IF;
  RETURN OLD;
 END IF;
 IF current_user IN ('authenticated','anon') AND (
  (OLD.case_reference IS NOT NULL AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD))
  OR NEW.assigned_user_id IS DISTINCT FROM OLD.assigned_user_id OR NEW.case_reference IS DISTINCT FROM OLD.case_reference
  OR (NEW.status='INVESTIGATING' AND NEW.status IS DISTINCT FROM OLD.status)
 ) THEN RAISE EXCEPTION 'Claimed alerts are server managed' USING ERRCODE='42501';END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.guard_case_ownership() FROM PUBLIC,anon,authenticated;
DROP TRIGGER coreaml_guard_case_ownership ON public.alerts;
CREATE TRIGGER coreaml_guard_case_ownership BEFORE UPDATE OR DELETE ON public.alerts FOR EACH ROW EXECUTE FUNCTION coreaml_private.guard_case_ownership();
NOTIFY pgrst,'reload schema';

-- source review
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

-- source review-submission
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

-- source case-worklists
CREATE FUNCTION public.coreaml_case_worklist(p_kind text DEFAULT 'CASES',p_search text DEFAULT '',p_status text DEFAULT 'ALL',p_owner text DEFAULT 'ALL',p_from timestamptz DEFAULT NULL,p_until timestamptz DEFAULT NULL,p_offset integer DEFAULT 0,p_limit integer DEFAULT 25)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;result jsonb;pattern text;
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF p_kind IS NULL OR p_kind NOT IN ('CASES','QA','EXECUTIVE') OR p_search IS NULL OR length(p_search)>120 OR p_status IS NULL OR p_status NOT IN ('ALL','INVESTIGATING','PENDING_QA_REVIEW','ESCALATED','CLOSED','MIXED') OR p_owner IS NULL OR p_owner NOT IN ('ALL','MINE') OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 OR p_limit IS NULL OR p_limit<1 OR p_limit>50 OR (p_from IS NOT NULL AND p_until IS NOT NULL AND p_from>=p_until) THEN RAISE EXCEPTION 'Invalid worklist filters' USING ERRCODE='22023';END IF;
 IF p_kind<>'CASES' AND staff.role<>'head_of_compliance' THEN RAISE EXCEPTION 'Head-of-compliance review access required' USING ERRCODE='42501';END IF;
 pattern:='%'||replace(replace(replace(btrim(p_search),E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_')||'%';
 WITH managed AS (
 SELECT c.*,a.customer_id,a.rule_triggered,a.severity,coalesce(nullif(cu.entity_name,''),nullif(btrim(concat_ws(' ',cu.first_name,cu.last_name)),''),'Unlinked case') AS entity_name,
 left(coalesce(p.full_name,''),200) AS owner_name,g.member_count,g.status,g.consistent
 FROM public.coreaml_case_claims c JOIN public.alerts a ON a.id=c.anchor_alert_id AND a.tenant_id=c.tenant_id
 LEFT JOIN public.customers cu ON cu.id=a.customer_id AND cu.tenant_id=c.tenant_id
 LEFT JOIN public.user_profiles p ON p.id=c.investigator_id AND p.tenant_id=c.tenant_id
 CROSS JOIN LATERAL (SELECT count(*)::integer AS member_count,CASE WHEN count(DISTINCT x.status)=1 THEN min(x.status) ELSE 'MIXED' END AS status,
 count(*)=cardinality(c.alert_ids) AND count(DISTINCT x.status)=1 AS consistent
 FROM public.alerts x WHERE x.id=ANY(c.alert_ids) AND x.tenant_id=c.tenant_id AND x.assigned_user_id=c.investigator_id AND x.case_reference=c.case_reference AND x.customer_id IS NOT DISTINCT FROM a.customer_id) g
 WHERE c.tenant_id=staff.tenant_id AND cardinality(c.alert_ids) BETWEEN 1 AND 2000 AND c.anchor_alert_id=ANY(c.alert_ids)
 AND (p_kind='CASES' OR c.investigator_id<>staff.id) AND (staff.role='head_of_compliance' OR c.investigator_id=staff.id) AND (p_owner='ALL' OR c.investigator_id=staff.id)
 AND g.member_count=cardinality(c.alert_ids) AND (a.customer_id IS NULL OR cu.id IS NOT NULL)
 ), candidates AS (
 SELECT c.anchor_alert_id AS id,c.anchor_alert_id AS alert_id,c.case_reference,c.customer_id,c.entity_name,c.rule_triggered,c.severity,
 CASE WHEN c.consistent THEN c.status ELSE 'MIXED' END AS status,c.investigator_id AS owner_id,c.owner_name,c.member_count,c.consistent,
 CASE WHEN p_kind='QA' THEN s.created_at ELSE c.claimed_at END AS occurred_at
 FROM managed c LEFT JOIN LATERAL (SELECT max(created_at) AS created_at FROM public.coreaml_review_submissions WHERE case_reference=c.case_reference AND tenant_id=staff.tenant_id AND kind='QA') s ON true
 WHERE p_kind IN ('CASES','QA') AND (p_kind='CASES' OR (c.consistent AND c.status='PENDING_QA_REVIEW'))
 UNION ALL
 SELECT r.id,c.anchor_alert_id,c.case_reference,c.customer_id,c.entity_name,c.rule_triggered,c.severity,'PENDING_APPROVAL',c.investigator_id,c.owner_name,c.member_count,c.consistent,r.created_at
 FROM public.suspicious_transaction_reports r JOIN managed c ON r.alert_id=c.anchor_alert_id AND r.tenant_id=c.tenant_id AND r.generated_by=c.investigator_id
 WHERE p_kind='EXECUTIVE' AND r.status='PENDING_APPROVAL' AND r.locked_at IS NULL AND r.report_data->'alert_ids'=to_jsonb(c.alert_ids) AND c.consistent AND c.status='ESCALATED' AND r.report_data->>'case_reference'=c.case_reference
 ), filtered AS (
 SELECT * FROM candidates WHERE (p_status='ALL' OR status=p_status) AND (p_from IS NULL OR occurred_at>=p_from) AND (p_until IS NULL OR occurred_at<p_until)
 AND (case_reference ILIKE pattern ESCAPE E'\\' OR entity_name ILIKE pattern ESCAPE E'\\' OR rule_triggered ILIKE pattern ESCAPE E'\\')
 ), page AS (SELECT * FROM filtered ORDER BY occurred_at DESC NULLS LAST,id DESC OFFSET p_offset LIMIT p_limit)
 SELECT jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'kind',p_kind,'offset',p_offset,'limit',p_limit,'total',(SELECT count(*) FROM filtered),'rows',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY occurred_at DESC NULLS LAST,id DESC) FROM page x),'[]'::jsonb)) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_case_worklist(text,text,text,text,timestamptz,timestamptz,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_worklist(text,text,text,text,timestamptz,timestamptz,integer,integer) TO authenticated;
NOTIFY pgrst,'reload schema';

-- source review-ageing
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
REVOKE ALL ON FUNCTION public.coreaml_case_worklist_priority(text,text,text,text,timestamptz,timestamptz,integer,integer,text,text,integer,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_worklist_priority(text,text,text,text,timestamptz,timestamptz,integer,integer,text,text,integer,boolean) TO authenticated;
NOTIFY pgrst,'reload schema';

-- source case-timeline
-- Read-only canonical case history. No alert status or workflow record is changed.
CREATE FUNCTION public.coreaml_case_timeline(p_alert_id uuid,p_limit integer DEFAULT 25,p_before timestamptz DEFAULT NULL,p_before_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;c public.coreaml_case_claims%ROWTYPE;a public.alerts%ROWTYPE;events jsonb;more boolean;cursor jsonb;total integer;result jsonb;
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF p_alert_id IS NULL OR p_limit IS NULL OR p_limit<1 OR p_limit>50 OR (p_before IS NULL)<>(p_before_key IS NULL)
 OR (p_before_key IS NOT NULL AND p_before_key !~ '^(claim|action|submission|review):[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$') THEN RAISE EXCEPTION 'Invalid timeline page' USING ERRCODE='22023';END IF;
 SELECT * INTO c FROM public.coreaml_case_claims WHERE tenant_id=staff.tenant_id AND p_alert_id=ANY(alert_ids);
 IF NOT FOUND OR (staff.role<>'head_of_compliance' AND c.investigator_id<>staff.id) THEN RAISE EXCEPTION 'Case history unavailable' USING ERRCODE='42501';END IF;
 IF cardinality(c.alert_ids)<1 OR cardinality(c.alert_ids)>2000 OR NOT(c.anchor_alert_id=ANY(c.alert_ids))
 OR (SELECT count(DISTINCT id) FROM unnest(c.alert_ids) id)<>cardinality(c.alert_ids) THEN RAISE EXCEPTION 'Case membership unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO a FROM public.alerts WHERE id=c.anchor_alert_id AND tenant_id=staff.tenant_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Case anchor unavailable' USING ERRCODE='42501';END IF;
 IF a.customer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.customers WHERE id=a.customer_id AND tenant_id=staff.tenant_id) THEN RAISE EXCEPTION 'Case customer unavailable' USING ERRCODE='42501';END IF;
 SELECT count(*) INTO total FROM public.alerts x WHERE x.id=ANY(c.alert_ids) AND x.tenant_id=staff.tenant_id AND x.case_reference=c.case_reference AND x.assigned_user_id=c.investigator_id AND x.customer_id IS NOT DISTINCT FROM a.customer_id;
 IF total<>cardinality(c.alert_ids) THEN RAISE EXCEPTION 'Case membership changed' USING ERRCODE='42501';END IF;
 WITH history AS (
 SELECT 'claim:'||c.id::text AS event_key,c.claimed_at AS occurred_at,'CLAIMED'::text AS kind,c.investigator_id AS actor_id,NULL::uuid AS request_id,NULL::integer AS revision,NULL::text AS notes,'claim'::text AS source
 UNION ALL
 SELECT 'action:'||r.request_id::text,r.created_at,CASE WHEN r.action='SAVE' THEN 'DRAFT_SAVED' ELSE 'CASE_CLOSED' END,r.actor_id,r.request_id,(r.result->>'revision')::integer,NULL,'action_receipt'
 FROM public.coreaml_case_actions r WHERE r.case_reference=c.case_reference AND r.tenant_id=staff.tenant_id AND r.actor_id=c.investigator_id
 UNION ALL
 SELECT 'submission:'||s.request_id::text,s.created_at,CASE WHEN s.kind='QA' THEN 'QA_SUBMITTED' ELSE 'EXECUTIVE_SUBMITTED' END,s.actor_id,s.request_id,(s.result->>'revision')::integer,NULL,'submission_receipt'
 FROM public.coreaml_review_submissions s WHERE s.case_reference=c.case_reference AND s.tenant_id=staff.tenant_id AND s.actor_id=c.investigator_id
 UNION ALL
 SELECT 'review:'||r.request_id::text,r.created_at,r.kind||'_'||CASE WHEN r.decision='APPROVE' THEN 'APPROVED' ELSE 'RETURNED' END,r.actor_id,r.request_id,NULL,r.notes,'review_receipt'
 FROM public.coreaml_review_actions r WHERE r.case_reference=c.case_reference AND r.tenant_id=staff.tenant_id AND r.maker_id=c.investigator_id AND r.actor_id<>c.investigator_id
 ), page AS (
 SELECT h.*,left(nullif(btrim(p.full_name),''),200) AS actor_name FROM history h LEFT JOIN public.user_profiles p ON p.id=h.actor_id AND p.tenant_id=staff.tenant_id
 WHERE p_before IS NULL OR (h.occurred_at,h.event_key)<(p_before,p_before_key)
 ORDER BY h.occurred_at DESC,h.event_key DESC LIMIT p_limit+1
 ), ranked AS (SELECT *,row_number() OVER(ORDER BY occurred_at DESC,event_key DESC) AS rank FROM page)
 SELECT coalesce(jsonb_agg(to_jsonb(r)-'rank' ORDER BY occurred_at DESC,event_key DESC) FILTER(WHERE rank<=p_limit),'[]'::jsonb),coalesce(bool_or(rank>p_limit),false)
 INTO events,more FROM ranked r;
 IF more THEN cursor:=jsonb_build_object('at',events->(jsonb_array_length(events)-1)->>'occurred_at','key',events->(jsonb_array_length(events)-1)->>'event_key');ELSE cursor:=NULL;END IF;
 result:=jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'owner_id',c.investigator_id,'case_reference',c.case_reference,'alert_id',c.anchor_alert_id,'alert_ids',c.alert_ids,'entries',events,'has_more',more,'next_cursor',cursor);
 IF pg_column_size(result)>1048576 THEN RAISE EXCEPTION 'Timeline page exceeds display limit' USING ERRCODE='22023';END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_case_timeline(uuid,integer,timestamptz,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_timeline(uuid,integer,timestamptz,text) TO authenticated;
COMMENT ON FUNCTION public.coreaml_case_timeline(uuid,integer,timestamptz,text) IS 'Authorized read-only case history from claim and immutable workflow receipts; not a regulatory filing history.';
NOTIFY pgrst,'reload schema';

-- source case-summary
CREATE FUNCTION public.coreaml_case_summary(p_alert_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE scope jsonb;page jsonb;history jsonb:='[]';draft public.investigation_drafts%ROWTYPE;owner_name text;subject jsonb;alerts jsonb;packages jsonb;result jsonb;
BEGIN
 -- Reuse the reviewed timeline boundary: trusted active role/bank, owner or head,
 -- exact complete membership, canonical reference and customer linkage.
 scope:=public.coreaml_case_timeline(p_alert_id,50);page:=scope;
 LOOP
  history:=history||(page->'entries');
  IF jsonb_array_length(history)>500 OR (jsonb_array_length(history)=500 AND (page->>'has_more')::boolean) THEN RAISE EXCEPTION 'Summary exceeds the 500-entry workflow history limit; no partial summary produced' USING ERRCODE='22023';END IF;
  EXIT WHEN NOT(page->>'has_more')::boolean;
  page:=public.coreaml_case_timeline(p_alert_id,50,(page->'next_cursor'->>'at')::timestamptz,page->'next_cursor'->>'key');
 END LOOP;
 SELECT * INTO draft FROM public.investigation_drafts d WHERE d.alert_id=(scope->>'alert_id')::uuid AND d.case_reference=scope->>'case_reference' AND d.tenant_id=scope->>'tenant_id' AND d.investigator_id=(scope->>'owner_id')::uuid;
 IF FOUND AND (jsonb_typeof(draft.evidence_snapshot) IS DISTINCT FROM 'object' OR jsonb_typeof(draft.evidence_snapshot->'entities') IS DISTINCT FROM 'array' OR jsonb_typeof(draft.evidence_snapshot->'txs') IS DISTINCT FROM 'array') THEN RAISE EXCEPTION 'Saved evidence pins are unavailable in a confirmed format' USING ERRCODE='22023';END IF;
 SELECT p.full_name INTO owner_name FROM public.user_profiles p WHERE p.id=(scope->>'owner_id')::uuid AND p.tenant_id=scope->>'tenant_id';
 SELECT jsonb_build_object('id',c.id,'name',coalesce(nullif(c.entity_name,''),nullif(btrim(concat_ws(' ',c.first_name,c.last_name)),''),'Name not recorded')) INTO subject
 FROM public.customers c JOIN public.alerts a ON a.customer_id=c.id WHERE a.id=(scope->>'alert_id')::uuid AND c.tenant_id=scope->>'tenant_id';
 SELECT jsonb_agg(jsonb_build_object('id',a.id,'reference',a.alert_ref,'rule',a.rule_triggered,'severity',a.severity,'status',a.status,'transaction_id',a.transaction_id,'created_at',a.created_at,'recorded_evidence_available',a.evidence IS NOT NULL AND a.evidence<>'{}'::jsonb) ORDER BY a.id) INTO alerts
 FROM public.alerts a WHERE a.id=ANY(ARRAY(SELECT jsonb_array_elements_text(scope->'alert_ids'))::uuid[]) AND a.tenant_id=scope->>'tenant_id';
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',r.id,'status',r.status,'created_at',r.created_at,'reviewed_by',r.reviewed_by,'reviewed_at',r.locked_at,'justification',r.executive_justification) ORDER BY r.created_at,r.id),'[]') INTO packages
 FROM (SELECT * FROM public.suspicious_transaction_reports r WHERE r.alert_id=(scope->>'alert_id')::uuid AND r.tenant_id=scope->>'tenant_id' AND r.generated_by=(scope->>'owner_id')::uuid AND r.report_data->>'case_reference'=scope->>'case_reference' AND r.report_data->'alert_ids'=scope->'alert_ids' ORDER BY r.created_at,r.id LIMIT 51) r;
 IF jsonb_array_length(packages)>50 THEN RAISE EXCEPTION 'Summary exceeds the 50-package limit; no partial summary produced' USING ERRCODE='22023';END IF;
 result:=jsonb_build_object('document_type','INTERNAL_INVESTIGATION_SUMMARY','regulatory_submission',false,'as_of',transaction_timestamp(),'actor_id',scope->>'actor_id','tenant_id',scope->>'tenant_id','case_reference',scope->>'case_reference','alert_id',scope->>'alert_id','alert_ids',scope->'alert_ids','owner_id',scope->>'owner_id','owner_name',owner_name,'subject',subject,
 'draft',CASE WHEN draft.id IS NULL THEN NULL ELSE jsonb_build_object('id',draft.id,'revision',draft.revision,'status',draft.status,'narrative',draft.draft_narrative,'pins',draft.evidence_snapshot,'saved_at',draft.updated_at) END,'alerts',alerts,'history',history,'history_complete',true,'report_packages',packages);
 IF pg_column_size(result)>2097152 THEN RAISE EXCEPTION 'Summary exceeds the 2 MiB display limit; no partial summary produced' USING ERRCODE='22023';END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_case_summary(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_summary(uuid) TO authenticated;
NOTIFY pgrst,'reload schema';

-- source filing-workspace
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

-- source filing-review-v2
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

-- source filing-streamlined-v3
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

-- source rule-governance
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

-- source admin-manager
-- Dashboard and role boundaries; no existing bank, customer, report or account rows are rewritten.
CREATE TABLE public.coreaml_admin_requests (
 request_id uuid PRIMARY KEY, actor_id uuid NOT NULL, actor_role text NOT NULL, actor_tenant text,
 action text NOT NULL CHECK(action IN ('INVITE','DEACTIVATE','RESTORE','CREATE_BANK')),
 payload jsonb NOT NULL, target_id uuid, target_tenant text,
 state text NOT NULL CHECK(state IN ('RESERVED','AUTH_CREATED','COMPLETED','UNCONFIRMED')),
 result jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX coreaml_one_invite_request ON public.coreaml_admin_requests(lower(payload->>'email')) WHERE action='INVITE' AND state IN ('RESERVED','AUTH_CREATED','UNCONFIRMED');
ALTER TABLE public.coreaml_admin_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_admin_requests FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION coreaml_private.dashboard_staff(p_roles text[]) RETURNS public.user_profiles LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.user_id=auth.uid() AND s.id::text=auth.jwt()->>'session_id') THEN RAISE EXCEPTION 'Active authentication session required' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid();
 IF NOT FOUND OR p.is_active IS NOT TRUE OR NOT p.role=ANY(p_roles) OR p.role IS DISTINCT FROM auth.jwt()->'app_metadata'->>'role' OR p.tenant_id IS DISTINCT FROM nullif(auth.jwt()->'app_metadata'->>'tenant_id','') OR (p.role<>'it_admin' AND nullif(p.tenant_id,'') IS NULL) OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=p.id AND u.raw_app_meta_data->>'role'=p.role AND nullif(u.raw_app_meta_data->>'tenant_id','') IS NOT DISTINCT FROM p.tenant_id AND (u.banned_until IS NULL OR u.banned_until<=now())) THEN RAISE EXCEPTION 'Active matching trusted staff profile required' USING ERRCODE='42501';END IF;
 RETURN p;END $$;
CREATE OR REPLACE FUNCTION public.coreaml_dashboard_context() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN p:=coreaml_private.dashboard_staff(ARRAY['it_admin','head_of_compliance','compliance_officer','bank_manager','branch_manager','bankmanager','teller','sales_rep']);
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'role',p.role,'name',coalesce(p.full_name,'Staff member'),'server_time',now());END $$;
-- Restrictive fences supplement existing policies, even where legacy permissive policies remain.
CREATE FUNCTION coreaml_private.dashboard_business_access() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.user_id=auth.uid() AND s.id::text=auth.jwt()->>'session_id') THEN RETURN false;END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid();
 RETURN FOUND AND p.is_active IS TRUE AND nullif(p.tenant_id,'') IS NOT NULL AND EXISTS(SELECT 1 FROM auth.users u WHERE u.id=p.id AND u.raw_app_meta_data->>'role'=p.role AND nullif(u.raw_app_meta_data->>'tenant_id','') IS NOT DISTINCT FROM p.tenant_id AND (u.banned_until IS NULL OR u.banned_until<=now())) AND p.role IN ('head_of_compliance','compliance_officer','branch_manager','bankmanager','teller','sales_rep') AND p.role IS NOT DISTINCT FROM auth.jwt()->'app_metadata'->>'role' AND p.tenant_id IS NOT DISTINCT FROM auth.jwt()->'app_metadata'->>'tenant_id';END $$;
DO $$ DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY['customers','accounts','transactions','alerts','investigation_drafts','suspicious_transaction_reports','report_archives','risk_score_history','tills','vault_transfers','aml_rules','shadow_evaluations','coreaml_compatible_sets','coreaml_compatible_runs','coreaml_compatible_results','coreaml_review_submissions','coreaml_review_actions','coreaml_filing_drafts','coreaml_filing_events','coreaml_filing_exports','transaction_evaluation_outbox','coreaml_case_claims','coreaml_case_actions','customer_baselines','customer_risk_profiles','report_schedules'] LOOP
 IF to_regclass('public.'||t) IS NOT NULL THEN
 EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('CREATE POLICY coreaml_dashboard_plane_fence ON public.%I AS RESTRICTIVE FOR ALL TO PUBLIC USING (coreaml_private.dashboard_business_access()) WITH CHECK (coreaml_private.dashboard_business_access())',t);
 END IF;END LOOP;
END $$;
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.banks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.custom_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_events ENABLE ROW LEVEL SECURITY;
-- Profiles, banks and role definitions change through reviewed endpoints, not browser table writes.
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.user_profiles,public.profiles,public.banks,public.custom_roles FROM PUBLIC,anon,authenticated;
CREATE POLICY coreaml_dashboard_profile_read ON public.user_profiles AS RESTRICTIVE FOR SELECT TO authenticated USING (
 id=auth.uid() OR EXISTS(SELECT 1 FROM public.coreaml_dashboard_context() c WHERE c->>'role' IN ('it_admin','head_of_compliance','compliance_officer') AND (c->>'role'='it_admin' OR tenant_id=c->>'tenant_id'))
);
-- Keep manager/admin directory access behind projection RPCs. The own-profile row remains available.
CREATE POLICY coreaml_dashboard_banks_read ON public.banks AS RESTRICTIVE FOR SELECT TO authenticated USING (EXISTS(SELECT 1 FROM public.coreaml_dashboard_context() c WHERE c->>'role'='it_admin' OR id=c->>'tenant_id'));
CREATE POLICY coreaml_dashboard_roles_read ON public.custom_roles AS RESTRICTIVE FOR SELECT TO authenticated USING (coreaml_private.dashboard_business_access());
CREATE POLICY coreaml_dashboard_legacy_profiles ON public.profiles AS RESTRICTIVE FOR SELECT TO authenticated USING (
 id=auth.uid() OR (coreaml_private.dashboard_business_access() AND tenant_id=auth.jwt()->'app_metadata'->>'tenant_id')
);
CREATE POLICY coreaml_dashboard_audit_fence ON public.audit_logs AS RESTRICTIVE FOR ALL TO authenticated USING (
 coreaml_private.dashboard_business_access() AND tenant_id::text=auth.jwt()->'app_metadata'->>'tenant_id'
) WITH CHECK(false);
CREATE POLICY coreaml_dashboard_telemetry_fence ON public.system_events AS RESTRICTIVE FOR ALL TO authenticated USING (
 coreaml_private.dashboard_business_access() AND tenant_id::text=auth.jwt()->'app_metadata'->>'tenant_id'
) WITH CHECK(coreaml_private.dashboard_business_access() AND tenant_id::text=auth.jwt()->'app_metadata'->>'tenant_id');
CREATE FUNCTION public.coreaml_manager_dashboard(p_section text DEFAULT 'OVERVIEW',p_offset integer DEFAULT 0,p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;rows jsonb;total bigint;BEGIN
 p:=coreaml_private.dashboard_staff(ARRAY['bank_manager']);
 IF p_section IS NULL OR p_section NOT IN ('OVERVIEW','CASES','TRANSACTIONS','STAFF') OR p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 100000 OR p_search IS NULL OR length(p_search)>120 THEN RAISE EXCEPTION 'Invalid bounded oversight query' USING ERRCODE='22023';END IF;
 IF p_section='OVERVIEW' THEN RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'section',p_section,'server_time',now(),
 'bank_name',(SELECT name FROM public.banks WHERE id=p.tenant_id),
 'customers',(SELECT count(*) FROM public.customers WHERE tenant_id=p.tenant_id),
 'open_cases',(SELECT count(*) FROM public.coreaml_case_claims c WHERE c.tenant_id=p.tenant_id AND EXISTS(SELECT 1 FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND a.tenant_id=p.tenant_id AND a.status<>'CLOSED')),
 'unassigned_alerts',(SELECT count(*) FROM public.alerts WHERE tenant_id=p.tenant_id AND status='UNASSIGNED'),
 'severity',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT severity,count(*) AS count FROM public.alerts WHERE tenant_id=p.tenant_id AND status<>'CLOSED' GROUP BY severity ORDER BY severity) q),
 'risk_tiers',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT risk_tier::text AS risk_tier,count(*) AS count FROM public.customers WHERE tenant_id=p.tenant_id GROUP BY risk_tier ORDER BY risk_tier) q),
 'case_states',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT status,count(*) AS count FROM public.alerts WHERE tenant_id=p.tenant_id GROUP BY status ORDER BY status) q),
 'filing_counts',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT mode,state,count(*) AS count FROM public.coreaml_filing_drafts WHERE tenant_id=p.tenant_id GROUP BY mode,state ORDER BY mode,state) q),
 'governed_rules',(SELECT count(*) FROM public.coreaml_rule_deployments WHERE tenant_id=p.tenant_id AND status='ACTIVE'),
 'evaluation_errors',(SELECT count(*) FROM public.coreaml_rule_results WHERE tenant_id=p.tenant_id AND outcome='ERROR'));
 ELSIF p_section='CASES' THEN
 SELECT count(*) INTO total FROM public.coreaml_case_claims c WHERE c.tenant_id=p.tenant_id AND (p_search='' OR position(lower(p_search) in lower(c.case_reference))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT c.case_reference,cardinality(c.alert_ids) AS alert_members,coalesce(u.full_name,'Name unavailable') AS owner,
 CASE WHEN (SELECT count(DISTINCT a.status) FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND a.tenant_id=p.tenant_id)=1 THEN (SELECT min(a.status) FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND a.tenant_id=p.tenant_id) ELSE 'MIXED' END AS state,
 (SELECT min(a.created_at) FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND a.tenant_id=p.tenant_id) AS detected_at
 FROM public.coreaml_case_claims c LEFT JOIN public.user_profiles u ON u.id=c.investigator_id AND u.tenant_id=c.tenant_id WHERE c.tenant_id=p.tenant_id AND (p_search='' OR position(lower(p_search) in lower(c.case_reference))>0) ORDER BY c.case_reference,c.id OFFSET p_offset LIMIT 25) q;
 ELSIF p_section='TRANSACTIONS' THEN
 SELECT count(*) INTO total FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id JOIN public.customers c ON c.id=a.customer_id WHERE c.tenant_id=p.tenant_id AND (p_search='' OR position(lower(p_search) in lower(t.transaction_reference))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT t.transaction_reference,t.transaction_timestamp,t.amount::text AS amount,t.currency::text AS currency,t.transaction_type::text AS direction,t.channel::text AS channel FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id JOIN public.customers c ON c.id=a.customer_id WHERE c.tenant_id=p.tenant_id AND (p_search='' OR position(lower(p_search) in lower(t.transaction_reference))>0) ORDER BY t.transaction_timestamp DESC,t.id DESC OFFSET p_offset LIMIT 25) q;
 ELSE
 SELECT count(*) INTO total FROM public.user_profiles WHERE tenant_id=p.tenant_id AND role IN ('compliance_officer','head_of_compliance') AND (p_search='' OR position(lower(p_search) in lower(coalesce(full_name,'')||' '||role))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT coalesce(full_name,'Name unavailable') AS name,role,is_active FROM public.user_profiles WHERE tenant_id=p.tenant_id AND role IN ('compliance_officer','head_of_compliance') AND (p_search='' OR position(lower(p_search) in lower(coalesce(full_name,'')||' '||role))>0) ORDER BY role,id OFFSET p_offset LIMIT 25) q;
 END IF;
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'section',p_section,'offset',p_offset,'total',total,'rows',rows,'server_time',now());END $$;
CREATE FUNCTION public.coreaml_admin_directory(p_section text DEFAULT 'USERS',p_offset integer DEFAULT 0,p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;rows jsonb;total bigint;BEGIN p:=coreaml_private.dashboard_staff(ARRAY['it_admin','head_of_compliance']);
 IF p_section IS NULL OR p_section NOT IN ('USERS','BANKS','ROLES','AUDIT','REQUESTS') OR p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 100000 OR p_search IS NULL OR length(p_search)>120 THEN RAISE EXCEPTION 'Invalid directory query' USING ERRCODE='22023';END IF;
 IF p_section='USERS' THEN
 SELECT count(*) INTO total FROM public.user_profiles u WHERE (p.role='it_admin' OR u.tenant_id=p.tenant_id AND u.role IN ('compliance_officer','head_of_compliance')) AND (p_search='' OR position(lower(p_search) in lower(coalesce(u.full_name,'')||' '||u.role||' '||coalesce(u.tenant_id,'')))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT u.id,u.full_name,u.role,u.tenant_id,u.is_active,u.created_at,b.name AS bank_name,(u.id<>p.id AND (p.role='it_admin' OR u.role='compliance_officer')) AS can_manage FROM public.user_profiles u LEFT JOIN public.banks b ON b.id=u.tenant_id WHERE (p.role='it_admin' OR u.tenant_id=p.tenant_id AND u.role IN ('compliance_officer','head_of_compliance')) AND (p_search='' OR position(lower(p_search) in lower(coalesce(u.full_name,'')||' '||u.role||' '||coalesce(u.tenant_id,'')))>0) ORDER BY u.created_at DESC,u.id OFFSET p_offset LIMIT 25) q;
 ELSIF p_section='BANKS' THEN
 SELECT count(*) INTO total FROM public.banks WHERE (p.role='it_admin' OR id=p.tenant_id) AND (p_search='' OR position(lower(p_search) in lower(name||' '||id))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT id,name,created_at FROM public.banks WHERE (p.role='it_admin' OR id=p.tenant_id) AND (p_search='' OR position(lower(p_search) in lower(name||' '||id))>0) ORDER BY name,id OFFSET p_offset LIMIT 25) q;
 ELSIF p_section='ROLES' THEN
 IF p.role<>'it_admin' THEN RAISE EXCEPTION 'Platform role inventory required' USING ERRCODE='42501';END IF;
 SELECT count(*) INTO total FROM public.custom_roles WHERE p_search='' OR position(lower(p_search) in lower(role_name||' '||coalesce(description,'')))>0;
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT id,role_name,description,tenant_id,created_at FROM public.custom_roles WHERE p_search='' OR position(lower(p_search) in lower(role_name||' '||coalesce(description,'')))>0 ORDER BY created_at DESC,id OFFSET p_offset LIMIT 25) q;
 ELSIF p_section='AUDIT' THEN
 SELECT count(*) INTO total FROM public.audit_logs WHERE (p.role='it_admin' OR tenant_id::text=p.tenant_id) AND (p_search='' OR position(lower(p_search) in lower(event_type))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT id,created_at,event_type,actor_id,target_id,tenant_id FROM public.audit_logs WHERE (p.role='it_admin' OR tenant_id::text=p.tenant_id) AND (p_search='' OR position(lower(p_search) in lower(event_type))>0) ORDER BY created_at DESC,id DESC OFFSET p_offset LIMIT 25) q;
 ELSE
 SELECT count(*) INTO total FROM public.coreaml_admin_requests WHERE (p.role='it_admin' OR actor_id=p.id) AND (p_search='' OR position(lower(p_search) in lower(request_id::text||' '||action||' '||state||' '||coalesce(payload->>'email','')))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT request_id,action,state,target_id,target_tenant,payload->>'email' AS invited_email,payload->>'role' AS requested_role,created_at,updated_at,result FROM public.coreaml_admin_requests WHERE (p.role='it_admin' OR actor_id=p.id) AND (p_search='' OR position(lower(p_search) in lower(request_id::text||' '||action||' '||state||' '||coalesce(payload->>'email','')))>0) ORDER BY created_at DESC,request_id DESC OFFSET p_offset LIMIT 25) q;
 END IF;
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'role',p.role,'section',p_section,'offset',p_offset,'total',total,'rows',rows,'server_time',now());END $$;
CREATE FUNCTION public.coreaml_admin_reserve(p_action text,p_payload jsonb,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;t public.user_profiles%ROWTYPE;r public.coreaml_admin_requests%ROWTYPE;bank text;v_role text;BEGIN
 p:=coreaml_private.dashboard_staff(ARRAY['it_admin','head_of_compliance']);
 PERFORM 1 FROM public.user_profiles WHERE id=p.id FOR SHARE;
 IF p_request_id IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR p_action IS NULL OR p_action NOT IN ('INVITE','DEACTIVATE','RESTORE') THEN RAISE EXCEPTION 'Invalid administration request' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('admin-request:'||p_request_id::text,0));
 SELECT * INTO r FROM public.coreaml_admin_requests WHERE request_id=p_request_id FOR UPDATE;
 IF FOUND THEN
 IF r.actor_id<>p.id OR r.actor_role<>p.role OR r.actor_tenant IS DISTINCT FROM p.tenant_id THEN RAISE EXCEPTION 'Request unavailable' USING ERRCODE='42501';END IF;
 IF (r.action,r.payload) IS DISTINCT FROM (p_action,p_payload) THEN RAISE EXCEPTION 'Request reference reused with different content' USING ERRCODE='22023';END IF;
 RETURN to_jsonb(r)||jsonb_build_object('replayed',true,'dispatch',r.state<>'COMPLETED' AND (r.action<>'INVITE' OR r.state='AUTH_CREATED'));END IF;
 IF p_action='INVITE' THEN
 bank:=nullif(p_payload->>'tenant_id','');v_role:=p_payload->>'role';
 IF coalesce(p_payload->>'email','') !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' OR length(p_payload->>'email')>254 OR v_role IS NULL OR v_role NOT IN ('it_admin','head_of_compliance','compliance_officer','bank_manager','branch_manager','bankmanager','teller','sales_rep') THEN RAISE EXCEPTION 'Supported built-in role and valid email required' USING ERRCODE='22023';END IF;
 IF (v_role='it_admin' AND (p.role<>'it_admin' OR bank IS NOT NULL)) OR (v_role<>'it_admin' AND (bank IS NULL OR NOT EXISTS(SELECT 1 FROM public.banks WHERE id=bank))) OR (p.role='head_of_compliance' AND (v_role<>'compliance_officer' OR bank IS DISTINCT FROM p.tenant_id)) THEN RAISE EXCEPTION 'Invitation exceeds your bank or role authority' USING ERRCODE='42501';END IF;
 -- Do not use inviteUserByEmail as an implicit role-change tool for existing identities.
 IF EXISTS(SELECT 1 FROM auth.users WHERE lower(email)=lower(p_payload->>'email')) THEN RAISE EXCEPTION 'An identity already exists for this email; invitation cannot change its role' USING ERRCODE='22023';END IF;
 ELSE
 SELECT * INTO t FROM public.user_profiles WHERE id=(p_payload->>'target_id')::uuid FOR UPDATE;
 IF NOT FOUND OR t.id=p.id OR (p.role='head_of_compliance' AND (t.tenant_id IS DISTINCT FROM p.tenant_id OR t.role<>'compliance_officer')) THEN RAISE EXCEPTION 'Target is outside your authority or is your own account' USING ERRCODE='42501';END IF;
 bank:=t.tenant_id;
 IF p_action='DEACTIVATE' THEN UPDATE public.user_profiles SET is_active=false WHERE id=t.id;END IF;
 END IF;
 INSERT INTO public.coreaml_admin_requests(request_id,actor_id,actor_role,actor_tenant,action,payload,target_id,target_tenant,state,result)
 VALUES(p_request_id,p.id,p.role,p.tenant_id,p_action,p_payload,t.id,bank,'RESERVED',jsonb_build_object('target_role',coalesce(t.role,v_role))) RETURNING * INTO r;
 RETURN to_jsonb(r)||jsonb_build_object('replayed',false,'dispatch',true);
END $$;
CREATE FUNCTION public.coreaml_admin_auth_checkpoint(p_actor uuid,p_request_id uuid,p_target uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.coreaml_admin_requests%ROWTYPE;BEGIN
 SELECT * INTO r FROM public.coreaml_admin_requests WHERE request_id=p_request_id FOR UPDATE;
 IF NOT FOUND OR r.actor_id<>p_actor OR r.action<>'INVITE' OR r.state NOT IN ('RESERVED','AUTH_CREATED') OR p_target IS NULL OR (r.target_id IS NOT NULL AND r.target_id<>p_target) THEN RAISE EXCEPTION 'Invalid authentication checkpoint' USING ERRCODE='42501';END IF;
 UPDATE public.coreaml_admin_requests SET target_id=p_target,state='AUTH_CREATED',updated_at=now() WHERE request_id=p_request_id RETURNING * INTO r;RETURN to_jsonb(r);
END $$;
CREATE FUNCTION public.coreaml_admin_finish(p_actor uuid,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.coreaml_admin_requests%ROWTYPE;p public.user_profiles%ROWTYPE;t public.user_profiles%ROWTYPE;u auth.users%ROWTYPE;answer jsonb;BEGIN
 SELECT * INTO r FROM public.coreaml_admin_requests WHERE request_id=p_request_id FOR UPDATE;
 IF NOT FOUND OR r.actor_id<>p_actor THEN RAISE EXCEPTION 'Request unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=p_actor FOR SHARE;
 IF NOT FOUND OR p.is_active IS NOT TRUE OR (p.role,p.tenant_id) IS DISTINCT FROM (r.actor_role,r.actor_tenant) OR NOT EXISTS(SELECT 1 FROM auth.users actor WHERE actor.id=p.id AND actor.raw_app_meta_data->>'role'=p.role AND nullif(actor.raw_app_meta_data->>'tenant_id','') IS NOT DISTINCT FROM p.tenant_id AND (actor.banned_until IS NULL OR actor.banned_until<=now())) THEN RAISE EXCEPTION 'Actor authority changed' USING ERRCODE='42501';END IF;
 IF r.state='COMPLETED' THEN RETURN r.result||jsonb_build_object('replayed',true);END IF;
 SELECT * INTO t FROM public.user_profiles WHERE id=r.target_id FOR UPDATE;
 IF NOT FOUND OR (t.role,t.tenant_id) IS DISTINCT FROM (r.result->>'target_role',r.target_tenant) THEN RAISE EXCEPTION 'Target role or bank changed' USING ERRCODE='42501';END IF;
 SELECT * INTO u FROM auth.users WHERE id=r.target_id;
 IF NOT FOUND OR u.raw_app_meta_data->>'role' IS DISTINCT FROM t.role OR nullif(u.raw_app_meta_data->>'tenant_id','') IS DISTINCT FROM t.tenant_id THEN RAISE EXCEPTION 'Auth and trusted profile mismatch' USING ERRCODE='42501';END IF;
 IF r.action='DEACTIVATE' AND (u.banned_until IS NULL OR u.banned_until<=now()) THEN RAISE EXCEPTION 'Auth ban has not been confirmed';END IF;
 IF r.action IN ('RESTORE','INVITE') AND u.banned_until>now() THEN RAISE EXCEPTION 'Auth identity remains banned';END IF;
 IF r.action='INVITE' AND r.state<>'AUTH_CREATED' THEN RAISE EXCEPTION 'Invitation has no recorded Auth identity';END IF;
 UPDATE public.user_profiles SET is_active=(r.action<>'DEACTIVATE') WHERE id=t.id;
 answer:=jsonb_build_object('success',true,'request_id',r.request_id,'actor_id',p_actor,'target_id',t.id,'action',r.action,'state','COMPLETED','tenant_id',r.target_tenant,'replayed',false);
 INSERT INTO public.audit_logs(event_type,actor_id,target_id,tenant_id,details) VALUES('ADMIN_'||r.action,p_actor,t.id,CASE WHEN r.target_tenant ~* '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' THEN r.target_tenant::uuid ELSE NULL END,jsonb_build_object('request_id',r.request_id,'actor_role',r.actor_role,'target_role',t.role));
 UPDATE public.coreaml_admin_requests SET state='COMPLETED',result=answer,updated_at=now() WHERE request_id=p_request_id;RETURN answer;
END $$;
CREATE FUNCTION public.coreaml_create_bank(p_name text,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;r public.coreaml_admin_requests%ROWTYPE;v_id text;answer jsonb;BEGIN
 p:=coreaml_private.dashboard_staff(ARRAY['it_admin']);IF p_request_id IS NULL OR length(btrim(coalesce(p_name,''))) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'A bank name of 3–120 characters is required' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('admin-request:'||p_request_id::text,0));SELECT * INTO r FROM public.coreaml_admin_requests WHERE request_id=p_request_id;
 IF FOUND THEN IF r.actor_id<>p.id OR r.action<>'CREATE_BANK' OR r.payload IS DISTINCT FROM jsonb_build_object('name',p_name) THEN RAISE EXCEPTION 'Request reused with different content' USING ERRCODE='22023';END IF;RETURN r.result||jsonb_build_object('replayed',true);END IF;
 v_id:=gen_random_uuid()::text;INSERT INTO public.banks(id,name) VALUES(v_id,btrim(p_name));answer:=jsonb_build_object('request_id',p_request_id,'actor_id',p.id,'action','CREATE_BANK','tenant_id',v_id,'state','COMPLETED','success',true,'replayed',false);
 INSERT INTO public.coreaml_admin_requests(request_id,actor_id,actor_role,actor_tenant,action,payload,target_tenant,state,result) VALUES(p_request_id,p.id,p.role,p.tenant_id,'CREATE_BANK',jsonb_build_object('name',p_name),v_id,'COMPLETED',answer);
 INSERT INTO public.audit_logs(event_type,actor_id,tenant_id,details) VALUES('ADMIN_CREATE_BANK',p.id,v_id::uuid,jsonb_build_object('request_id',p_request_id));RETURN answer;END $$;
REVOKE ALL ON FUNCTION coreaml_private.dashboard_staff(text[]),coreaml_private.dashboard_business_access() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION coreaml_private.dashboard_business_access() TO anon,authenticated;
REVOKE ALL ON FUNCTION public.coreaml_dashboard_context(),public.coreaml_manager_dashboard(text,integer,text),public.coreaml_admin_directory(text,integer,text),public.coreaml_admin_reserve(text,jsonb,uuid),public.coreaml_create_bank(text,uuid),public.coreaml_admin_auth_checkpoint(uuid,uuid,uuid),public.coreaml_admin_finish(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_dashboard_context(),public.coreaml_manager_dashboard(text,integer,text),public.coreaml_admin_directory(text,integer,text),public.coreaml_admin_reserve(text,jsonb,uuid),public.coreaml_create_bank(text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_admin_auth_checkpoint(uuid,uuid,uuid),public.coreaml_admin_finish(uuid,uuid) TO service_role;
DO $$ DECLARE f text;BEGIN
 FOREACH f IN ARRAY ARRAY['public.update_risk_tier(uuid,integer,text)','public.calculate_dynamic_baselines()'] LOOP
 IF to_regprocedure(f) IS NOT NULL THEN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f);END IF;END LOOP;
END $$;
NOTIFY pgrst,'reload schema';

DO $$ BEGIN IF to_regclass('storage.objects') IS NOT NULL THEN
 CREATE POLICY coreaml_dashboard_storage_fence ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated USING (coreaml_private.dashboard_business_access()) WITH CHECK(coreaml_private.dashboard_business_access());
END IF;END $$;

DO $install$ BEGIN IF to_regprocedure('public.get_rolling_tx_stats(uuid,integer,text)') IS NOT NULL THEN
 ALTER FUNCTION public.get_rolling_tx_stats(uuid,integer,text) RENAME TO get_rolling_tx_stats_before_dashboard;
 REVOKE ALL ON FUNCTION public.get_rolling_tx_stats_before_dashboard(uuid,integer,text) FROM PUBLIC,anon,authenticated;
 EXECUTE $definition$CREATE FUNCTION public.get_rolling_tx_stats(p_account_id uuid,p_hours integer,p_tx_type text DEFAULT 'CREDIT') RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $body$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF current_setting('role',true)='service_role' OR (session_user='postgres' AND coalesce(current_setting('role',true),'none') IN ('none','postgres')) THEN RETURN public.get_rolling_tx_stats_before_dashboard(p_account_id,p_hours,p_tx_type);END IF;
 p:=coreaml_private.dashboard_staff(ARRAY['head_of_compliance','compliance_officer','branch_manager','bankmanager','teller','sales_rep']);
 IF NOT EXISTS(SELECT 1 FROM public.accounts a JOIN public.customers c ON c.id=a.customer_id WHERE a.id=p_account_id AND c.tenant_id=p.tenant_id) THEN RAISE EXCEPTION 'Account is outside your bank' USING ERRCODE='42501';END IF;
 RETURN public.get_rolling_tx_stats_before_dashboard(p_account_id,p_hours,p_tx_type);END $body$;$definition$;
 REVOKE ALL ON FUNCTION public.get_rolling_tx_stats(uuid,integer,text) FROM PUBLIC,anon,authenticated;
 GRANT EXECUTE ON FUNCTION public.get_rolling_tx_stats(uuid,integer,text) TO authenticated,service_role;
END IF;END $install$;

DO $install$ BEGIN IF to_regprocedure('public.get_rolling_tx_volume(uuid,integer,text)') IS NOT NULL THEN
 ALTER FUNCTION public.get_rolling_tx_volume(uuid,integer,text) RENAME TO get_rolling_tx_volume_before_dashboard;
 REVOKE ALL ON FUNCTION public.get_rolling_tx_volume_before_dashboard(uuid,integer,text) FROM PUBLIC,anon,authenticated;
 EXECUTE $definition$CREATE FUNCTION public.get_rolling_tx_volume(p_account_id uuid,p_hours integer,p_tx_type text DEFAULT 'CREDIT') RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $body$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF current_setting('role',true)='service_role' OR (session_user='postgres' AND coalesce(current_setting('role',true),'none') IN ('none','postgres')) THEN RETURN public.get_rolling_tx_volume_before_dashboard(p_account_id,p_hours,p_tx_type);END IF;
 p:=coreaml_private.dashboard_staff(ARRAY['head_of_compliance','compliance_officer','branch_manager','bankmanager','teller','sales_rep']);
 IF NOT EXISTS(SELECT 1 FROM public.accounts a JOIN public.customers c ON c.id=a.customer_id WHERE a.id=p_account_id AND c.tenant_id=p.tenant_id) THEN RAISE EXCEPTION 'Account is outside your bank' USING ERRCODE='42501';END IF;
 RETURN public.get_rolling_tx_volume_before_dashboard(p_account_id,p_hours,p_tx_type);END $body$;$definition$;
 REVOKE ALL ON FUNCTION public.get_rolling_tx_volume(uuid,integer,text) FROM PUBLIC,anon,authenticated;
 GRANT EXECUTE ON FUNCTION public.get_rolling_tx_volume(uuid,integer,text) TO authenticated,service_role;
END IF;END $install$;

NOTIFY pgrst,'reload schema';

-- source dashboard-visuals
-- Read-only chart projection; reuse the installed role, bank and session boundary.
CREATE FUNCTION public.coreaml_manager_visual_snapshot() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;r jsonb;industries jsonb;recorded bigint;high_count bigint;BEGIN
 p:=coreaml_private.dashboard_staff(ARRAY['bank_manager']);
 r:=public.coreaml_manager_dashboard('OVERVIEW',0,'');
 SELECT count(*) FILTER(WHERE risk_tier::text IN ('LOW','MEDIUM','HIGH','VERY_HIGH','CRITICAL')),count(*) FILTER(WHERE risk_tier::text IN ('HIGH','VERY_HIGH','CRITICAL')) INTO recorded,high_count FROM public.customers WHERE tenant_id=p.tenant_id;
 WITH grouped AS (
  SELECT coalesce(nullif(btrim(industry),''),'Not recorded') AS industry,count(*) AS customers,
  count(*) FILTER(WHERE risk_tier::text IN ('HIGH','VERY_HIGH','CRITICAL')) AS high,
  count(*) FILTER(WHERE risk_tier::text IN ('LOW','MEDIUM')) AS other,
  count(*) FILTER(WHERE risk_tier IS NULL OR risk_tier::text NOT IN ('LOW','MEDIUM','HIGH','VERY_HIGH','CRITICAL')) AS unknown
  FROM public.customers WHERE tenant_id=p.tenant_id GROUP BY coalesce(nullif(btrim(industry),''),'Not recorded')
 ),ranked AS (SELECT *,row_number() OVER(ORDER BY customers DESC,industry) AS rank FROM grouped),bounded AS (
 SELECT CASE WHEN rank<=12 THEN industry ELSE 'Other industries' END AS industry,sum(customers)::bigint AS customers,sum(high)::bigint AS high,sum(other)::bigint AS other,sum(unknown)::bigint AS unknown FROM ranked GROUP BY CASE WHEN rank<=12 THEN industry ELSE 'Other industries' END
 ) SELECT coalesce(jsonb_agg(to_jsonb(bounded) ORDER BY customers DESC,industry),'[]') INTO industries FROM bounded;
 RETURN r||jsonb_build_object('risk_recorded_count',recorded,'high_risk_count',high_count,'industry_risks',industries);
END $$;
REVOKE ALL ON FUNCTION public.coreaml_manager_visual_snapshot() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_manager_visual_snapshot() TO authenticated;
NOTIFY pgrst,'reload schema';

GRANT USAGE ON SCHEMA coreaml_private TO anon,authenticated;
