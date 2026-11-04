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
