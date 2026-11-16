CREATE TABLE coreaml_private.pep_relationship_decisions (
    edd_id uuid PRIMARY KEY REFERENCES coreaml_private.pep_review_events(id),
    reviewer_id uuid NOT NULL,
    approved boolean NOT NULL,
    rationale text NOT NULL,
    owner_id uuid,
    checks text,
    next_due date,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (num_nonnulls(owner_id, checks, next_due) IN (0,3)),
    CHECK (approved OR owner_id IS NULL)
);

CREATE TABLE coreaml_private.pep_monitoring_reviews (
    id uuid PRIMARY KEY,
    edd_id uuid NOT NULL REFERENCES coreaml_private.pep_relationship_decisions(edd_id),
    reviewer_id uuid NOT NULL,
    findings text NOT NULL,
    next_due date NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX pep_monitoring_review_latest
    ON coreaml_private.pep_monitoring_reviews (edd_id, created_at DESC, id DESC);
ALTER TABLE coreaml_private.pep_relationship_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE coreaml_private.pep_monitoring_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_relationship_decisions, coreaml_private.pep_monitoring_reviews
    FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.coreaml_pep_monitoring(p_edd uuid DEFAULT NULL, p_offset integer DEFAULT 0)
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
                    coalesce(last.next_due,d.next_due) AS due,last.id AS last_review,
                    CASE WHEN p_edd IS NOT NULL THEN (
                        SELECT jsonb_agg(jsonb_build_object('findings',h.findings,'next_due',h.next_due,
                            'reviewed_at',h.created_at,'reviewer',coalesce(reviewer.email,h.reviewer_id::text))
                            ORDER BY h.created_at DESC,h.id DESC)
                        FROM coreaml_private.pep_monitoring_reviews h
                        LEFT JOIN auth.users reviewer ON reviewer.id=h.reviewer_id
                        WHERE h.edd_id=d.edd_id
                    ) END AS history
                FROM coreaml_private.pep_relationship_decisions d
                JOIN coreaml_private.pep_review_events e ON e.id=d.edd_id AND e.tenant_id=staff.tenant_id
                JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
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

CREATE FUNCTION public.coreaml_decide_pep_relationship(
    p_edd uuid,p_approved boolean,p_rationale text,p_owner uuid,p_checks text,p_due date
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; edd coreaml_private.pep_review_events;
        existing coreaml_private.pep_relationship_decisions;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    SELECT e.* INTO edd FROM coreaml_private.pep_review_events e
    JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
    WHERE e.id=p_edd AND e.tenant_id=staff.tenant_id AND e.status='EDD_REVIEWED';
    IF NOT FOUND THEN RAISE EXCEPTION 'Completed EDD unavailable' USING ERRCODE='42501'; END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(edd.customer_id::text||':'||edd.subject_id::text,0));
    SELECT * INTO existing FROM coreaml_private.pep_relationship_decisions WHERE edd_id=p_edd;
    IF FOUND THEN
        IF (existing.reviewer_id,existing.approved,existing.rationale,existing.owner_id,existing.checks,existing.next_due)
            IS NOT DISTINCT FROM (staff.id,p_approved,btrim(p_rationale),p_owner,btrim(p_checks),p_due)
        THEN RETURN p_edd; END IF;
        RAISE EXCEPTION 'A decision was already saved for this EDD review' USING ERRCODE='40001';
    END IF;
    IF EXISTS (SELECT 1 FROM coreaml_private.pep_review_events e WHERE e.prior_id=p_edd) THEN
        RAISE EXCEPTION 'Reload the latest PEP review' USING ERRCODE='40001';
    END IF;
    IF p_approved IS NULL OR length(coalesce(btrim(p_rationale),'')) NOT BETWEEN 10 AND 1000
        OR num_nonnulls(p_owner,p_checks,p_due) NOT IN (0,3)
        OR (NOT p_approved AND p_owner IS NOT NULL)
        OR (p_approved AND edd.exposure='FOREIGN' AND p_owner IS NULL)
        OR (p_owner IS NOT NULL AND (
            length(btrim(p_checks)) NOT BETWEEN 10 AND 1000
            OR p_due < (now() AT TIME ZONE 'Africa/Lagos')::date
            OR NOT EXISTS (
                SELECT 1 FROM public.user_profiles p WHERE p.id=p_owner AND p.tenant_id=staff.tenant_id
                  AND p.is_active AND p.role IN ('compliance_officer','head_of_compliance')
            )
        )) THEN
        RAISE EXCEPTION 'Provide a decision and rationale, and a valid owner, checks and due date where monitoring is required'
            USING ERRCODE='22023';
    END IF;
    INSERT INTO coreaml_private.pep_relationship_decisions
        (edd_id,reviewer_id,approved,rationale,owner_id,checks,next_due)
    VALUES (p_edd,staff.id,p_approved,btrim(p_rationale),p_owner,btrim(p_checks),p_due);
    RETURN p_edd;
END
$$;

CREATE FUNCTION public.coreaml_complete_pep_monitoring(
    p_request uuid,p_edd uuid,p_prior uuid,p_findings text,p_due date
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; plan coreaml_private.pep_relationship_decisions;
        previous uuid; existing coreaml_private.pep_monitoring_reviews;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    SELECT d.* INTO plan FROM coreaml_private.pep_relationship_decisions d
    JOIN coreaml_private.pep_review_events e ON e.id=d.edd_id AND e.tenant_id=staff.tenant_id
    JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
    WHERE d.edd_id=p_edd AND d.owner_id IS NOT NULL
      AND (d.owner_id=staff.id OR staff.role='head_of_compliance')
    FOR UPDATE OF d;
    IF NOT FOUND THEN RAISE EXCEPTION 'Monitoring plan unavailable' USING ERRCODE='42501'; END IF;

    SELECT * INTO existing FROM coreaml_private.pep_monitoring_reviews WHERE id=p_request;
    IF FOUND THEN
        IF (existing.edd_id,existing.reviewer_id,existing.findings,existing.next_due)
             IS NOT DISTINCT FROM (p_edd,staff.id,btrim(p_findings),p_due)
        THEN RETURN p_request; END IF;
        RAISE EXCEPTION 'Review reference already used' USING ERRCODE='22023';
    END IF;
    SELECT id INTO previous FROM coreaml_private.pep_monitoring_reviews
    WHERE edd_id=p_edd ORDER BY created_at DESC,id DESC LIMIT 1;
    IF previous IS DISTINCT FROM p_prior THEN
        RAISE EXCEPTION 'Another monitoring review was saved. Reload the plan.' USING ERRCODE='40001';
    END IF;
    IF p_request IS NULL OR length(coalesce(btrim(p_findings),'')) NOT BETWEEN 10 AND 1000
        OR p_due IS NULL OR p_due <= (now() AT TIME ZONE 'Africa/Lagos')::date THEN
        RAISE EXCEPTION 'Provide findings and a future review date' USING ERRCODE='22023';
    END IF;
    INSERT INTO coreaml_private.pep_monitoring_reviews (id,edd_id,reviewer_id,findings,next_due)
    VALUES (p_request,p_edd,staff.id,btrim(p_findings),p_due);
    RETURN p_request;
END
$$;

REVOKE ALL ON FUNCTION public.coreaml_pep_monitoring(uuid,integer),
    public.coreaml_decide_pep_relationship(uuid,boolean,text,uuid,text,date),
    public.coreaml_complete_pep_monitoring(uuid,uuid,uuid,text,date)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_pep_monitoring(uuid,integer),
    public.coreaml_decide_pep_relationship(uuid,boolean,text,uuid,text,date),
    public.coreaml_complete_pep_monitoring(uuid,uuid,uuid,text,date) TO authenticated;
NOTIFY pgrst,'reload schema';
