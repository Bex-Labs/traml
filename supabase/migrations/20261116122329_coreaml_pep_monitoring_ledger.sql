ALTER TABLE coreaml_private.pep_monitoring_reviews
    ADD COLUMN ledger_evidence jsonb;

CREATE FUNCTION coreaml_private.pep_monitoring_ledger_rows(
    p_edd uuid,p_staff public.user_profiles,p_from date,p_to date
)
RETURNS TABLE(id uuid,reference text,posted_at timestamptz,amount text,currency text,direction text)
LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE customer uuid;
BEGIN
    SELECT e.customer_id INTO customer
    FROM coreaml_private.pep_relationship_decisions d
    JOIN coreaml_private.pep_review_events e ON e.id=d.edd_id AND e.tenant_id=p_staff.tenant_id
    JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
    WHERE d.edd_id=p_edd AND d.owner_id IS NOT NULL
      AND (d.owner_id=p_staff.id OR p_staff.role='head_of_compliance');
    IF NOT FOUND THEN RAISE EXCEPTION 'Monitoring plan unavailable' USING ERRCODE='42501'; END IF;
    IF p_from IS NULL OR p_to IS NULL OR NOT isfinite(p_from) OR NOT isfinite(p_to)
       OR p_from>p_to OR p_to>(now() AT TIME ZONE 'Africa/Lagos')::date OR p_to-p_from>365 THEN
        RAISE EXCEPTION 'Choose a review period of up to 366 days ending today or earlier' USING ERRCODE='22023';
    END IF;
    RETURN QUERY
    SELECT t.id,t.transaction_reference,t.transaction_timestamp,t.amount::text,t.currency::text,t.transaction_type::text
    FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id
    WHERE a.customer_id=customer
      AND t.transaction_timestamp >= (p_from::timestamp AT TIME ZONE 'Africa/Lagos')
      AND t.transaction_timestamp < ((p_to+1)::timestamp AT TIME ZONE 'Africa/Lagos');
END
$$;
REVOKE ALL ON FUNCTION coreaml_private.pep_monitoring_ledger_rows(uuid,public.user_profiles,date,date)
    FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.coreaml_pep_monitoring_ledger(p_edd uuid,p_from date,p_to date,p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF p_offset IS NULL OR p_offset<0 THEN RAISE EXCEPTION 'Invalid page offset' USING ERRCODE='22023'; END IF;
    RETURN (
        SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.posted_at DESC,t.id DESC),'[]'::jsonb)
        FROM (
            SELECT * FROM coreaml_private.pep_monitoring_ledger_rows(p_edd,staff,p_from,p_to)
            ORDER BY posted_at DESC,id DESC LIMIT 26 OFFSET p_offset
        ) t
    );
END
$$;

CREATE FUNCTION public.coreaml_complete_pep_monitoring_with_evidence(
    p_request uuid,p_edd uuid,p_prior uuid,p_findings text,p_due date,p_from date,p_to date,p_transactions uuid[]
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; recorded jsonb; linked jsonb; ids jsonb; replay boolean;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF p_transactions IS NULL OR cardinality(p_transactions)>25 OR
       cardinality(p_transactions)<>(SELECT count(DISTINCT tx) FROM unnest(p_transactions) AS t(tx)) THEN
        RAISE EXCEPTION 'Select up to 25 distinct ledger transactions' USING ERRCODE='22023';
    END IF;
    SELECT coalesce(jsonb_agg(tx ORDER BY tx),'[]'::jsonb) INTO ids FROM unnest(p_transactions) AS t(tx);

    -- Take the existing plan lock before checking whether this is a replay.
    PERFORM 1 FROM coreaml_private.pep_relationship_decisions d
    JOIN coreaml_private.pep_review_events e ON e.id=d.edd_id AND e.tenant_id=staff.tenant_id
    WHERE d.edd_id=p_edd AND d.owner_id IS NOT NULL
      AND (d.owner_id=staff.id OR staff.role='head_of_compliance')
    FOR UPDATE OF d;
    SELECT ledger_evidence INTO recorded FROM coreaml_private.pep_monitoring_reviews
    WHERE id=p_request AND edd_id=p_edd;
    replay := FOUND;
    PERFORM public.coreaml_complete_pep_monitoring(p_request,p_edd,p_prior,p_findings,p_due);
    IF replay THEN
        IF recorded IS NOT NULL AND (recorded->'from',recorded->'to',recorded->'ids') IS NOT DISTINCT FROM
           (to_jsonb(p_from),to_jsonb(p_to),ids) THEN RETURN p_request; END IF;
        RAISE EXCEPTION 'Review reference already used with different ledger evidence' USING ERRCODE='22023';
    END IF;

    SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.posted_at DESC,t.id DESC),'[]'::jsonb) INTO linked
    FROM coreaml_private.pep_monitoring_ledger_rows(p_edd,staff,p_from,p_to) t
    WHERE t.id=ANY(p_transactions);
    IF jsonb_array_length(linked)<>cardinality(p_transactions) THEN
        RAISE EXCEPTION 'A selected transaction is outside this customer’s review period or unavailable' USING ERRCODE='42501';
    END IF;
    UPDATE coreaml_private.pep_monitoring_reviews SET ledger_evidence=
        jsonb_build_object('from',p_from,'to',p_to,'ids',ids,'transactions',linked)
    WHERE id=p_request;
    RETURN p_request;
END
$$;

REVOKE ALL ON FUNCTION public.coreaml_pep_monitoring_ledger(uuid,date,date,integer),
    public.coreaml_complete_pep_monitoring_with_evidence(uuid,uuid,uuid,text,date,date,date,uuid[])
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_pep_monitoring_ledger(uuid,date,date,integer),
    public.coreaml_complete_pep_monitoring_with_evidence(uuid,uuid,uuid,text,date,date,date,uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.coreaml_pep_monitoring(p_edd uuid DEFAULT NULL, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'Invalid page offset' USING ERRCODE='22023';
    END IF;
    RETURN jsonb_build_object(
        'staff_id', staff.id, 'role', staff.role, 'today', (now() AT TIME ZONE 'Africa/Lagos')::date,
        'owners', CASE WHEN p_edd IS NOT NULL AND staff.role='head_of_compliance' THEN (
            SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'label', coalesce(nullif(u.email,''),p.id::text))
                        ORDER BY u.email,p.id),'[]'::jsonb)
            FROM public.user_profiles p JOIN auth.users u ON u.id=p.id
            WHERE p.tenant_id=staff.tenant_id AND p.is_active
              AND p.role IN ('compliance_officer','head_of_compliance')
        ) ELSE '[]'::jsonb END,
        'items', coalesce((
            SELECT jsonb_agg(to_jsonb(q) ORDER BY q.due,q.edd_id)
            FROM (
                SELECT d.edd_id,e.customer_id,e.subject_id,e.subject_name,
                    d.approved,d.rationale,d.checks,d.owner_id,owner.email AS owner_name,
                    CASE WHEN p_edd IS NOT NULL THEN edd.evidence#>>'{checks,expected_activity}' END AS expected_activity,
                    coalesce(last.next_due,d.next_due) AS due,last.id AS last_review,
                    CASE WHEN p_edd IS NOT NULL THEN (
                        SELECT jsonb_agg(jsonb_build_object('findings',h.findings,'next_due',h.next_due,
                            'ledger_evidence',h.ledger_evidence, 'reviewed_at',h.created_at,'reviewer',coalesce(reviewer.email,h.reviewer_id::text))
                            ORDER BY h.created_at DESC,h.id DESC)
                        FROM coreaml_private.pep_monitoring_reviews h
                        LEFT JOIN auth.users reviewer ON reviewer.id=h.reviewer_id
                        WHERE h.edd_id=d.edd_id
                    ) END AS history
                FROM coreaml_private.pep_relationship_decisions d
                JOIN coreaml_private.pep_review_events e ON e.id=d.edd_id AND e.tenant_id=staff.tenant_id
                JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
                LEFT JOIN coreaml_private.pep_edd_events edd ON edd.id=d.edd_id AND p_edd IS NOT NULL
                LEFT JOIN auth.users owner ON owner.id=d.owner_id
                LEFT JOIN LATERAL (
                    SELECT h.id,h.next_due FROM coreaml_private.pep_monitoring_reviews h
                    WHERE h.edd_id=d.edd_id ORDER BY h.created_at DESC,h.id DESC LIMIT 1
                ) last ON true
                WHERE (p_edd IS NULL AND d.owner_id IS NOT NULL) OR d.edd_id=p_edd
                ORDER BY due,d.edd_id LIMIT 26 OFFSET p_offset
            ) q
        ),'[]'::jsonb));
END
$$;

CREATE FUNCTION public.coreaml_pep_queue(p_offset integer,p_status text)
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
                   CASE WHEN rs.event_id IS NOT NULL THEN 'ROSTER_RESCREEN' ELSE t.reason END AS reason,coalesce(rs.assigned_to,t.assigned_to) IS NOT NULL AS assigned,
                   coalesce(coalesce(rs.assigned_to,t.assigned_to)=staff.id,false) AS assigned_to_me,
                   coalesce(c.entity_name,concat_ws(' ',c.first_name,c.last_name)) AS customer_name
            FROM coreaml_private.pep_review_events e
            JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
            LEFT JOIN coreaml_private.pep_onboarding_tasks t
              ON t.tenant_id=e.tenant_id AND t.customer_id=e.customer_id AND t.subject_id=e.subject_id
            LEFT JOIN coreaml_private.pep_rescreen_evidence rs ON rs.event_id=e.id
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

REVOKE ALL ON FUNCTION public.coreaml_pep_queue(integer,text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_pep_queue(integer,text) TO authenticated;
NOTIFY pgrst,'reload schema';
