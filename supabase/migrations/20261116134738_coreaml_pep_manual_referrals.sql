CREATE TABLE coreaml_private.pep_manual_referrals (
    event_id uuid PRIMARY KEY REFERENCES coreaml_private.pep_review_events(id),
    source text NOT NULL CHECK (source IN ('CUSTOMER_DECLARATION','OFFICER_RESEARCH')),
    pep_name text NOT NULL,
    public_role text NOT NULL,
    relationship text NOT NULL,
    evidence_reference text NOT NULL
);
ALTER TABLE coreaml_private.pep_manual_referrals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_manual_referrals FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.coreaml_refer_pep(
    p_request uuid,p_customer uuid,p_subject uuid,p_prior uuid,p_category text,
    p_source text,p_pep_name text,p_public_role text,p_relationship text,p_reference text,p_reason text
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; prior_referral coreaml_private.pep_manual_referrals;
        submitted coreaml_private.pep_manual_referrals;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer']);
    IF p_request IS NULL OR p_source IS NULL OR p_source NOT IN ('CUSTOMER_DECLARATION','OFFICER_RESEARCH')
       OR p_category IS NULL OR p_category NOT IN ('DOMESTIC','FOREIGN','INTERNATIONAL_ORGANISATION','FAMILY','CLOSE_ASSOCIATE','UNKNOWN')
       OR length(coalesce(btrim(p_pep_name),'')) NOT BETWEEN 2 AND 200
       OR length(coalesce(btrim(p_public_role),'')) NOT BETWEEN 3 AND 250
       OR length(coalesce(btrim(p_relationship),'')) NOT BETWEEN 3 AND 500
       OR length(coalesce(btrim(p_reference),'')) NOT BETWEEN 3 AND 500
       OR length(coalesce(btrim(p_reason),'')) NOT BETWEEN 10 AND 1000 THEN
        RAISE EXCEPTION 'Provide the source, PEP name, role, connection, evidence reference and reason' USING ERRCODE='22023';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(p_customer::text||':'||p_subject::text,0));
    SELECT * INTO prior_referral FROM coreaml_private.pep_manual_referrals WHERE event_id=p_request;
    IF NOT FOUND AND EXISTS (SELECT 1 FROM coreaml_private.pep_review_events WHERE id=p_request) THEN
        RAISE EXCEPTION 'Review reference already used' USING ERRCODE='22023';
    END IF;

    -- This validates the customer and subject against the staff bank, checks
    -- the previous decision, and prevents reopening confirmed exposure.
    PERFORM public.coreaml_record_pep_review(p_request,p_customer,p_subject,p_prior,
        'POSSIBLE_EXPOSURE',p_category,btrim(p_reason));

    submitted := ROW(p_request,p_source,btrim(p_pep_name),btrim(p_public_role),
        btrim(p_relationship),btrim(p_reference))::coreaml_private.pep_manual_referrals;
    IF prior_referral.event_id IS NOT NULL THEN
        IF prior_referral IS DISTINCT FROM submitted THEN
            RAISE EXCEPTION 'Review reference already used with different referral details' USING ERRCODE='22023';
        END IF;
        RETURN p_request;
    END IF;
    INSERT INTO coreaml_private.pep_manual_referrals VALUES (submitted.*);
    RETURN p_request;
END
$$;
REVOKE ALL ON FUNCTION public.coreaml_refer_pep(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_refer_pep(uuid,uuid,uuid,uuid,text,text,text,text,text,text,text)
    TO authenticated;

CREATE OR REPLACE FUNCTION public.coreaml_pep_subjects(p_customer uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.id=p_customer AND c.tenant_id=staff.tenant_id) THEN
        RAISE EXCEPTION 'Customer unavailable' USING ERRCODE='42501';
    END IF;
    RETURN jsonb_build_object('role',staff.role,'subjects',coalesce((
        SELECT jsonb_agg(to_jsonb(s) || jsonb_build_object('latest',to_jsonb(e),'onboarding',to_jsonb(t),'rescreening',rs.source_evidence,'referrals',mr.items)
                         ORDER BY s.full_name,s.person_role,s.subject_id)
        FROM coreaml_private.pep_subjects(staff.tenant_id,p_customer) s
        LEFT JOIN LATERAL (
            SELECT reason,source_evidence,created_at,assigned_to IS NOT NULL AS assigned,
                   coalesce(assigned_to=staff.id,false) AS assigned_to_me
            FROM coreaml_private.pep_onboarding_tasks t
            WHERE t.tenant_id=staff.tenant_id AND t.customer_id=p_customer AND t.subject_id=s.subject_id
        ) t ON true
        LEFT JOIN LATERAL (
            SELECT id,status,exposure,evidence,created_at
            FROM coreaml_private.pep_review_events e
            WHERE e.tenant_id=staff.tenant_id AND e.customer_id=p_customer AND e.subject_id=s.subject_id
            ORDER BY e.created_at DESC,e.id DESC LIMIT 1
        ) e ON true
        LEFT JOIN LATERAL (
            SELECT jsonb_agg(item ORDER BY r.created_at DESC,r.id DESC,item->>'source_reference') AS source_evidence
            FROM coreaml_private.pep_review_events r
            JOIN coreaml_private.pep_rescreen_evidence ev ON ev.event_id=r.id
            CROSS JOIN LATERAL jsonb_array_elements(ev.source_evidence) AS evidence(item)
            WHERE r.tenant_id=staff.tenant_id AND r.customer_id=p_customer AND r.subject_id=s.subject_id
        ) rs ON true
        LEFT JOIN LATERAL (
            SELECT jsonb_agg(to_jsonb(r) || jsonb_build_object('created_at',ev.created_at,'category',ev.exposure,'reason',ev.evidence)
                ORDER BY ev.created_at DESC,ev.id DESC) AS items
            FROM coreaml_private.pep_review_events ev
            JOIN coreaml_private.pep_manual_referrals r ON r.event_id=ev.id
            WHERE ev.tenant_id=staff.tenant_id AND ev.customer_id=p_customer AND ev.subject_id=s.subject_id
        ) mr ON true
    ),'[]'::jsonb));
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_pep_queue(p_offset integer,p_status text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF p_offset IS NULL OR p_offset < 0 THEN RAISE EXCEPTION 'Invalid offset' USING ERRCODE='22023'; END IF;
    IF p_status IS NULL OR p_status NOT IN ('ALL','POSSIBLE_EXPOSURE','CONFIRMED_EXPOSURE','EDD_REVIEWED') THEN
        RAISE EXCEPTION 'Invalid PEP queue status' USING ERRCODE='22023';
    END IF;
    RETURN coalesce((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC,q.id DESC)
        FROM (
            SELECT e.id,e.customer_id,e.subject_id,e.subject_name,e.status,e.exposure,e.evidence,e.created_at,
                   CASE WHEN mr.event_id IS NOT NULL THEN mr.source WHEN rs.event_id IS NOT NULL THEN 'ROSTER_RESCREEN' ELSE t.reason END AS reason,coalesce(rs.assigned_to,t.assigned_to) IS NOT NULL AS assigned,
                   coalesce(coalesce(rs.assigned_to,t.assigned_to)=staff.id,false) AS assigned_to_me,
                   coalesce(c.entity_name,concat_ws(' ',c.first_name,c.last_name)) AS customer_name
            FROM coreaml_private.pep_review_events e
            JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
            LEFT JOIN coreaml_private.pep_onboarding_tasks t
              ON t.tenant_id=e.tenant_id AND t.customer_id=e.customer_id AND t.subject_id=e.subject_id
            LEFT JOIN coreaml_private.pep_rescreen_evidence rs ON rs.event_id=e.id
            LEFT JOIN coreaml_private.pep_manual_referrals mr ON mr.event_id=e.id
            WHERE e.tenant_id=staff.tenant_id
              AND e.status IN ('POSSIBLE_EXPOSURE','INFORMATION_NEEDED','CONFIRMED_EXPOSURE','EDD_REVIEWED')
              AND (p_status='ALL' OR e.status=p_status)
              AND NOT EXISTS (SELECT 1 FROM coreaml_private.pep_review_events n WHERE n.prior_id=e.id)
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 26 OFFSET p_offset
        ) q
    ),'[]'::jsonb);
END
$$;

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
