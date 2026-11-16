CREATE FUNCTION coreaml_private.active_pep_edd_preparer(p_exposure uuid, p_tenant text)
RETURNS uuid LANGUAGE sql STABLE SET search_path='' AS $$
    SELECT p.id
    FROM (
        SELECT e.actor_id FROM coreaml_private.pep_edd_events e
        WHERE e.exposure_id=p_exposure AND e.action IN ('DRAFT','SUBMITTED')
        ORDER BY e.created_at DESC,e.id DESC LIMIT 1
    ) latest
    JOIN public.user_profiles p ON p.id=latest.actor_id AND p.tenant_id=p_tenant
    WHERE p.role='compliance_officer' AND p.is_active;
$$;
REVOKE ALL ON FUNCTION coreaml_private.active_pep_edd_preparer(uuid,text)
    FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.coreaml_pep_edd_workspace(p_exposure uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; exposure coreaml_private.pep_review_events; customer public.customers;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    SELECT e.* INTO exposure FROM coreaml_private.pep_review_events e
    WHERE e.id=coalesce((
        SELECT completed.prior_id FROM coreaml_private.pep_review_events completed
        WHERE completed.id=p_exposure AND completed.tenant_id=staff.tenant_id AND completed.status='EDD_REVIEWED'
    ),p_exposure) AND e.tenant_id=staff.tenant_id AND e.status='CONFIRMED_EXPOSURE';
    IF NOT FOUND THEN RAISE EXCEPTION 'Confirmed exposure unavailable' USING ERRCODE='42501'; END IF;
    SELECT c.* INTO customer FROM public.customers c WHERE c.id=exposure.customer_id AND c.tenant_id=staff.tenant_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Customer unavailable' USING ERRCODE='42501'; END IF;
    RETURN jsonb_build_object(
        'staff_id',staff.id,'role',staff.role,'actor_id',exposure.actor_id,'id',exposure.id,
        'preparer',coreaml_private.active_pep_edd_preparer(exposure.id,staff.tenant_id),
        'subject',exposure.subject_name,'category',exposure.exposure,'finding',exposure.evidence,
        'customer',jsonb_build_object('name',coalesce(customer.entity_name,concat_ws(' ',customer.first_name,customer.last_name)),
            'kyc_status',customer.kyc_status,'identity_path',customer.id_url,'address_path',customer.utility_bill_url),
        'people',(SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.full_name,s.subject_id),'[]'::jsonb)
            FROM coreaml_private.pep_subjects(staff.tenant_id,customer.id) s),
        'superseded',EXISTS (SELECT 1 FROM coreaml_private.pep_review_events e WHERE e.prior_id=exposure.id),
        'events',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC,e.id DESC),'[]'::jsonb)
            FROM coreaml_private.pep_edd_events e WHERE e.exposure_id=exposure.id)
    );
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_record_pep_edd(
    p_request uuid,p_exposure uuid,p_prior uuid,p_action text,p_evidence jsonb,p_note text
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; exposure coreaml_private.pep_review_events;
        latest coreaml_private.pep_edd_events; existing coreaml_private.pep_edd_events;
        preparer uuid; snapshot jsonb; customer public.customers; key text;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    SELECT e.* INTO exposure FROM coreaml_private.pep_review_events e
    JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
    WHERE e.id=p_exposure AND e.tenant_id=staff.tenant_id AND e.status='CONFIRMED_EXPOSURE';
    IF NOT FOUND THEN RAISE EXCEPTION 'Confirmed exposure unavailable' USING ERRCODE='42501'; END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(exposure.customer_id::text||':'||exposure.subject_id::text,0));
    SELECT * INTO existing FROM coreaml_private.pep_edd_events WHERE id=p_request;
    IF FOUND THEN
        IF (existing.exposure_id,existing.prior_id,existing.actor_id,existing.action,existing.note)
            IS NOT DISTINCT FROM (p_exposure,p_prior,staff.id,p_action,btrim(p_note))
            AND (p_action IN ('RETURNED','APPROVED') OR existing.evidence->'checks'=p_evidence)
        THEN RETURN p_request; END IF;
        RAISE EXCEPTION 'EDD request reference already used' USING ERRCODE='22023';
    END IF;
    IF EXISTS (SELECT 1 FROM coreaml_private.pep_review_events e WHERE e.prior_id=p_exposure) THEN
        RAISE EXCEPTION 'This exposure has a later review. Reload the customer.' USING ERRCODE='40001';
    END IF;
    SELECT * INTO latest FROM coreaml_private.pep_edd_events
    WHERE exposure_id=p_exposure ORDER BY created_at DESC,id DESC LIMIT 1;
    IF latest.id IS DISTINCT FROM p_prior THEN
        RAISE EXCEPTION 'Another EDD update was saved. Reload the workspace.' USING ERRCODE='40001';
    END IF;
    IF p_request IS NULL OR p_action IS NULL OR p_action NOT IN ('DRAFT','SUBMITTED','RETURNED','APPROVED') THEN
        RAISE EXCEPTION 'Invalid EDD action' USING ERRCODE='22023';
    END IF;

    preparer := coreaml_private.active_pep_edd_preparer(p_exposure,staff.tenant_id);
    IF p_action IN ('DRAFT','SUBMITTED') THEN
        IF staff.role<>'compliance_officer' OR (preparer IS NOT NULL AND preparer<>staff.id)
           OR coalesce(latest.action,'DRAFT') NOT IN ('DRAFT','RETURNED') THEN
            RAISE EXCEPTION 'Only the compliance officer preparing this EDD can save or submit it' USING ERRCODE='42501';
        END IF;
        IF jsonb_typeof(p_evidence) IS DISTINCT FROM 'object'
           OR length(p_evidence::text)>16000 THEN
            RAISE EXCEPTION 'Invalid EDD evidence' USING ERRCODE='22023';
        END IF;
        FOREACH key IN ARRAY ARRAY['identity','connection','funds','wealth','expected_activity','references','open_items']
        LOOP
            IF jsonb_typeof(p_evidence->key) IS DISTINCT FROM 'string'
               OR length(p_evidence->>key)>2000
               OR (p_action='SUBMITTED' AND length(btrim(p_evidence->>key))<3) THEN
                RAISE EXCEPTION 'Complete the EDD evidence fields, including any outstanding items or why a check is inapplicable'
                    USING ERRCODE='22023';
            END IF;
        END LOOP;
        SELECT c.* INTO customer FROM public.customers c WHERE c.id=exposure.customer_id AND c.tenant_id=staff.tenant_id;
        snapshot := jsonb_build_object('checks',p_evidence,'kyc_status',customer.kyc_status,
            'identity_path',customer.id_url,'address_path',customer.utility_bill_url);
    ELSE
        IF staff.role<>'head_of_compliance' OR latest.action IS DISTINCT FROM 'SUBMITTED'
           OR (preparer IS NULL AND p_action='APPROVED')
           OR (preparer IS NOT NULL AND (staff.id=preparer OR staff.id=exposure.actor_id)) THEN
            RAISE EXCEPTION 'A different Head of Compliance must review EDD submitted by a compliance officer'
                USING ERRCODE='42501';
        END IF;
        IF length(coalesce(btrim(p_note),'')) NOT BETWEEN 10 AND 1000 THEN
            RAISE EXCEPTION 'Enter a review rationale or a specific request for more information'
                USING ERRCODE='22023';
        END IF;
        snapshot := latest.evidence;
    END IF;

    INSERT INTO coreaml_private.pep_edd_events(id,exposure_id,prior_id,actor_id,action,evidence,note)
    VALUES (p_request,p_exposure,p_prior,staff.id,p_action,snapshot,btrim(p_note));
    IF p_action='APPROVED' THEN
        PERFORM public.coreaml_record_pep_review(p_request,exposure.customer_id,exposure.subject_id,
            p_exposure,'EDD_REVIEWED',exposure.exposure,btrim(p_note));
    END IF;
    RETURN p_request;
END
$$;
NOTIFY pgrst,'reload schema';
