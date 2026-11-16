CREATE OR REPLACE FUNCTION public.coreaml_pep_queue(p_offset integer,p_status text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF p_offset IS NULL OR p_offset < 0 THEN RAISE EXCEPTION 'Invalid offset' USING ERRCODE='22023'; END IF;
    IF p_status IS NULL OR p_status NOT IN ('ALL','POSSIBLE_EXPOSURE','CONFIRMED_EXPOSURE','EDD_REVIEWED','NEEDS_MY_ACTION') THEN
        RAISE EXCEPTION 'Invalid PEP queue status' USING ERRCODE='22023';
    END IF;
    RETURN coalesce((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC,q.id DESC)
        FROM (
            SELECT e.id,e.customer_id,e.subject_id,e.subject_name,e.status,e.exposure,e.evidence,e.created_at,
                   CASE WHEN mr.event_id IS NOT NULL THEN mr.source WHEN rs.event_id IS NOT NULL THEN 'ROSTER_RESCREEN' ELSE t.reason END AS reason,coalesce(rs.assigned_to,t.assigned_to) IS NOT NULL AS assigned,
                   coalesce(coalesce(rs.assigned_to,t.assigned_to)=staff.id,false) AS assigned_to_me,
                   CASE WHEN e.status='CONFIRMED_EXPOSURE' THEN coalesce(edd.action,'NOT_STARTED') END AS edd_stage,
                   coalesce(c.entity_name,concat_ws(' ',c.first_name,c.last_name)) AS customer_name
            FROM coreaml_private.pep_review_events e
            JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
            LEFT JOIN coreaml_private.pep_onboarding_tasks t
              ON t.tenant_id=e.tenant_id AND t.customer_id=e.customer_id AND t.subject_id=e.subject_id
            LEFT JOIN coreaml_private.pep_rescreen_evidence rs ON rs.event_id=e.id
            LEFT JOIN coreaml_private.pep_manual_referrals mr ON mr.event_id=e.id
            LEFT JOIN LATERAL (
                SELECT ed.action
                FROM coreaml_private.pep_edd_events ed
                WHERE e.status='CONFIRMED_EXPOSURE' AND ed.exposure_id=e.id
                ORDER BY ed.created_at DESC,ed.id DESC LIMIT 1
            ) edd ON true
            LEFT JOIN LATERAL (
                SELECT CASE WHEN p_status='NEEDS_MY_ACTION' AND e.status='CONFIRMED_EXPOSURE'
                    THEN coreaml_private.active_pep_edd_preparer(e.id,staff.tenant_id)
                END AS id
            ) preparer ON true
            WHERE e.tenant_id=staff.tenant_id
              AND e.status IN ('POSSIBLE_EXPOSURE','INFORMATION_NEEDED','CONFIRMED_EXPOSURE','EDD_REVIEWED')
              AND (
                  p_status='ALL' OR e.status=p_status OR (
                      p_status='NEEDS_MY_ACTION' AND e.status='CONFIRMED_EXPOSURE' AND (
                          (staff.role='compliance_officer'
                              AND coalesce(edd.action,'NOT_STARTED') IN ('NOT_STARTED','DRAFT','RETURNED')
                              AND (preparer.id IS NULL OR preparer.id=staff.id))
                          OR (staff.role='head_of_compliance' AND edd.action='SUBMITTED'
                              AND (preparer.id IS NULL OR (
                                  preparer.id<>staff.id AND staff.id IS DISTINCT FROM e.actor_id
                              )))
                      )
                  )
              )
              AND NOT EXISTS (SELECT 1 FROM coreaml_private.pep_review_events n WHERE n.prior_id=e.id)
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 26 OFFSET p_offset
        ) q
    ),'[]'::jsonb);
END
$$;

NOTIFY pgrst,'reload schema';
