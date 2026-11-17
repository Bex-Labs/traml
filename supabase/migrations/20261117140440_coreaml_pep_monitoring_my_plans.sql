CREATE FUNCTION public.coreaml_pep_monitoring(p_edd uuid,p_offset integer,p_due_filter text,p_mine boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; today date := (now() AT TIME ZONE 'Africa/Lagos')::date;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF p_offset IS NULL OR p_offset < 0 THEN
        RAISE EXCEPTION 'Invalid page offset' USING ERRCODE='22023';
    END IF;
    IF p_mine IS NULL OR p_due_filter IS NULL OR p_due_filter NOT IN ('ALL','OVERDUE','DUE_TODAY','UPCOMING')
       OR (p_edd IS NOT NULL AND (p_due_filter<>'ALL' OR p_mine)) THEN
        RAISE EXCEPTION 'Invalid monitoring due-date filter' USING ERRCODE='22023';
    END IF;
    RETURN jsonb_build_object(
        'staff_id', staff.id, 'role', staff.role, 'today', today,
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
                    schedule.due,last.id AS last_review,
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
                CROSS JOIN LATERAL (SELECT coalesce(last.next_due,d.next_due) AS due) schedule
                WHERE d.edd_id=p_edd OR (p_edd IS NULL AND d.owner_id IS NOT NULL
                    AND (NOT p_mine OR d.owner_id=staff.id) AND (
                    p_due_filter='ALL'
                    OR (p_due_filter='OVERDUE' AND schedule.due<today)
                    OR (p_due_filter='DUE_TODAY' AND schedule.due=today)
                    OR (p_due_filter='UPCOMING' AND schedule.due>today)
                ))
                ORDER BY due,d.edd_id LIMIT 26 OFFSET p_offset
            ) q
        ),'[]'::jsonb));
END
$$;



REVOKE ALL ON FUNCTION public.coreaml_pep_monitoring(uuid,integer,text,boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_pep_monitoring(uuid,integer,text,boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.coreaml_pep_monitoring(p_edd uuid,p_offset integer,p_due_filter text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$
    SELECT public.coreaml_pep_monitoring(p_edd,p_offset,p_due_filter,false);
$$;
NOTIFY pgrst,'reload schema';
