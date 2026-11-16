CREATE TABLE coreaml_private.pep_edd_reassignments (
    id uuid PRIMARY KEY,
    exposure_id uuid NOT NULL REFERENCES coreaml_private.pep_review_events(id),
    edd_event_id uuid NOT NULL REFERENCES coreaml_private.pep_edd_events(id),
    prior_assignment uuid REFERENCES coreaml_private.pep_edd_reassignments(id),
    previous_officer uuid,
    officer_id uuid NOT NULL,
    actor_id uuid NOT NULL,
    reason text NOT NULL CHECK (length(reason) BETWEEN 10 AND 1000),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX pep_edd_reassignment_latest
    ON coreaml_private.pep_edd_reassignments(exposure_id,created_at DESC,id DESC);
ALTER TABLE coreaml_private.pep_edd_reassignments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_edd_reassignments FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION coreaml_private.active_pep_edd_preparer(p_exposure uuid,p_tenant text)
RETURNS uuid LANGUAGE sql STABLE SET search_path='' AS $$
    SELECT p.id
    FROM (
        SELECT candidate.officer_id
        FROM (
            SELECT e.actor_id AS officer_id,e.created_at,e.id
            FROM coreaml_private.pep_edd_events e
            WHERE e.exposure_id=p_exposure AND e.action IN ('DRAFT','SUBMITTED')
            UNION ALL
            SELECT a.officer_id,a.created_at,a.id
            FROM coreaml_private.pep_edd_reassignments a
            WHERE a.exposure_id=p_exposure
        ) candidate
        ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 1
    ) latest
    JOIN public.user_profiles p ON p.id=latest.officer_id AND p.tenant_id=p_tenant
    WHERE p.role='compliance_officer' AND p.is_active;
$$;

CREATE FUNCTION public.coreaml_reassign_pep_edd(
    p_request uuid,p_exposure uuid,p_edd_event uuid,p_prior_assignment uuid,p_officer uuid,p_reason text
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; exposure coreaml_private.pep_review_events;
        latest coreaml_private.pep_edd_events; stored coreaml_private.pep_edd_reassignments;
        current_assignment uuid; current_officer uuid;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    SELECT e.* INTO exposure FROM coreaml_private.pep_review_events e
    JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
    WHERE e.id=p_exposure AND e.tenant_id=staff.tenant_id AND e.status='CONFIRMED_EXPOSURE';
    IF NOT FOUND THEN RAISE EXCEPTION 'Confirmed exposure unavailable' USING ERRCODE='42501'; END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(exposure.customer_id::text||':'||exposure.subject_id::text,0));
    SELECT * INTO stored FROM coreaml_private.pep_edd_reassignments a WHERE a.id=p_request;
    IF FOUND THEN
        IF (stored.exposure_id,stored.edd_event_id,stored.prior_assignment,stored.actor_id,stored.officer_id,stored.reason)
            IS NOT DISTINCT FROM (p_exposure,p_edd_event,p_prior_assignment,staff.id,p_officer,btrim(p_reason))
        THEN RETURN p_request; END IF;
        RAISE EXCEPTION 'Reassignment reference already used' USING ERRCODE='22023';
    END IF;
    IF EXISTS (SELECT 1 FROM coreaml_private.pep_review_events e WHERE e.prior_id=p_exposure) THEN
        RAISE EXCEPTION 'This exposure has a later review. Reload the customer.' USING ERRCODE='40001';
    END IF;
    SELECT * INTO latest FROM coreaml_private.pep_edd_events
    WHERE exposure_id=p_exposure ORDER BY created_at DESC,id DESC LIMIT 1;
    SELECT a.id INTO current_assignment FROM coreaml_private.pep_edd_reassignments a
    WHERE a.exposure_id=p_exposure ORDER BY a.created_at DESC,a.id DESC LIMIT 1;
    IF latest.id IS DISTINCT FROM p_edd_event OR current_assignment IS DISTINCT FROM p_prior_assignment THEN
        RAISE EXCEPTION 'The EDD was updated. Reload before reassigning.' USING ERRCODE='40001';
    END IF;
    IF latest.action IS NULL OR latest.action NOT IN ('DRAFT','RETURNED') THEN
        RAISE EXCEPTION 'Only a draft or returned EDD can be reassigned' USING ERRCODE='22023';
    END IF;
    current_officer := coreaml_private.active_pep_edd_preparer(p_exposure,staff.tenant_id);
    IF p_request IS NULL OR length(coalesce(btrim(p_reason),'')) NOT BETWEEN 10 AND 1000
        OR p_officer IS NOT DISTINCT FROM current_officer OR NOT EXISTS (
            SELECT 1 FROM public.user_profiles p WHERE p.id=p_officer AND p.tenant_id=staff.tenant_id
                AND p.role='compliance_officer' AND p.is_active
        ) THEN
        RAISE EXCEPTION 'Choose a different active compliance officer in this bank and explain the reassignment'
            USING ERRCODE='22023';
    END IF;
    INSERT INTO coreaml_private.pep_edd_reassignments
        (id,exposure_id,edd_event_id,prior_assignment,previous_officer,officer_id,actor_id,reason)
    VALUES (p_request,p_exposure,p_edd_event,p_prior_assignment,current_officer,p_officer,staff.id,btrim(p_reason));
    RETURN p_request;
END
$$;
REVOKE ALL ON FUNCTION public.coreaml_reassign_pep_edd(uuid,uuid,uuid,uuid,uuid,text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_reassign_pep_edd(uuid,uuid,uuid,uuid,uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.coreaml_pep_edd_workspace(p_exposure uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; exposure coreaml_private.pep_review_events; customer public.customers; preparer uuid;
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
    preparer := coreaml_private.active_pep_edd_preparer(exposure.id,staff.tenant_id);
    RETURN jsonb_build_object(
        'staff_id',staff.id,'role',staff.role,'actor_id',exposure.actor_id,'id',exposure.id,
        'preparer',preparer,
        'preparer_label',(SELECT coalesce(u.email,u.id::text) FROM auth.users u WHERE u.id=preparer),
        'officers',CASE WHEN staff.role='head_of_compliance' THEN (
            SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'label',coalesce(u.email,p.id::text))
                ORDER BY u.email,p.id),'[]'::jsonb)
            FROM public.user_profiles p LEFT JOIN auth.users u ON u.id=p.id
            WHERE p.tenant_id=staff.tenant_id AND p.role='compliance_officer' AND p.is_active
                AND p.id IS DISTINCT FROM preparer
        ) ELSE '[]'::jsonb END,
        'reassignments',(SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id',a.id,'previous_officer',coalesce(old.email,a.previous_officer::text),
            'officer',coalesce(assigned.email,a.officer_id::text),'actor',coalesce(actor.email,a.actor_id::text),
            'reason',a.reason,'created_at',a.created_at) ORDER BY a.created_at DESC,a.id DESC),'[]'::jsonb)
            FROM coreaml_private.pep_edd_reassignments a
            LEFT JOIN auth.users old ON old.id=a.previous_officer
            LEFT JOIN auth.users assigned ON assigned.id=a.officer_id
            LEFT JOIN auth.users actor ON actor.id=a.actor_id
            WHERE a.exposure_id=exposure.id),
        'subject',exposure.subject_name,'category',exposure.exposure,'finding',exposure.evidence,
        'customer',jsonb_build_object('name',coalesce(customer.entity_name,concat_ws(' ',customer.first_name,customer.last_name)),
            'kyc_status',customer.kyc_status,'identity_path',customer.id_url,'address_path',customer.utility_bill_url),
        'people',(SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.full_name,s.subject_id),'[]'::jsonb)
            FROM coreaml_private.pep_subjects(staff.tenant_id,customer.id) s),
        'referrals',(SELECT coalesce(jsonb_agg(to_jsonb(r) ||
                    jsonb_build_object('created_at',ev.created_at,'category',ev.exposure,'reason',ev.evidence)
                    ORDER BY ev.created_at DESC,ev.id DESC),'[]'::jsonb)
            FROM coreaml_private.pep_review_events ev
            JOIN coreaml_private.pep_manual_referrals r ON r.event_id=ev.id
            WHERE ev.tenant_id=staff.tenant_id AND ev.customer_id=exposure.customer_id
                AND ev.subject_id=exposure.subject_id AND (ev.created_at,ev.id)<(exposure.created_at,exposure.id)),
        'superseded',EXISTS (SELECT 1 FROM coreaml_private.pep_review_events e WHERE e.prior_id=exposure.id),
        'events',(SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC,e.id DESC),'[]'::jsonb)
            FROM coreaml_private.pep_edd_events e WHERE e.exposure_id=exposure.id)
    );
END
$$;

NOTIFY pgrst,'reload schema';
