CREATE OR REPLACE FUNCTION public.coreaml_record_pep_review(
    p_request uuid,p_customer uuid,p_subject uuid,p_prior uuid,
    p_status text,p_exposure text,p_evidence text
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles; subject record; prior coreaml_private.pep_review_events;
        existing coreaml_private.pep_review_events;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    SELECT * INTO subject FROM coreaml_private.pep_subjects(staff.tenant_id,p_customer) s
    WHERE s.subject_id=p_subject;
    IF NOT FOUND THEN RAISE EXCEPTION 'PEP subject unavailable' USING ERRCODE='42501'; END IF;
    IF p_request IS NULL OR length(btrim(coalesce(p_evidence,''))) NOT BETWEEN 10 AND 1000
       OR coalesce(p_status,'') NOT IN ('DECLARED_NO_EXPOSURE','POSSIBLE_EXPOSURE','INFORMATION_NEEDED',
                                     'FALSE_POSITIVE','CONFIRMED_EXPOSURE','EDD_REVIEWED')
       OR (p_status IN ('POSSIBLE_EXPOSURE','CONFIRMED_EXPOSURE','EDD_REVIEWED') AND p_exposure IS NULL)
       OR (p_status IN ('CONFIRMED_EXPOSURE','EDD_REVIEWED') AND p_exposure='UNKNOWN')
       OR (p_exposure IS NOT NULL AND p_exposure NOT IN
           ('DOMESTIC','FOREIGN','INTERNATIONAL_ORGANISATION','FAMILY','CLOSE_ASSOCIATE','UNKNOWN')) THEN
        RAISE EXCEPTION 'Provide a valid outcome, exposure category and evidence' USING ERRCODE='22023';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(p_customer::text||':'||p_subject::text,0));
    SELECT * INTO existing FROM coreaml_private.pep_review_events e WHERE e.id=p_request;
    IF FOUND THEN
        IF existing.tenant_id=staff.tenant_id AND existing.actor_id=staff.id
           AND existing.customer_id=p_customer AND existing.subject_id=p_subject
           AND existing.prior_id IS NOT DISTINCT FROM p_prior AND existing.status=p_status
           AND existing.exposure IS NOT DISTINCT FROM p_exposure AND existing.evidence=btrim(p_evidence) THEN
            RETURN p_request;
        END IF;
        RAISE EXCEPTION 'Review reference already used' USING ERRCODE='22023';
    END IF;
    SELECT * INTO prior FROM coreaml_private.pep_review_events e
    WHERE e.tenant_id=staff.tenant_id AND e.customer_id=p_customer AND e.subject_id=p_subject
    ORDER BY e.created_at DESC,e.id DESC LIMIT 1;
    IF prior.id IS DISTINCT FROM p_prior THEN
        RAISE EXCEPTION 'Another review was saved. Reload this subject before continuing.' USING ERRCODE='40001';
    END IF;
    IF p_status='POSSIBLE_EXPOSURE' AND prior.status='POSSIBLE_EXPOSURE' THEN
        RAISE EXCEPTION 'Possible exposure is already open. Record a follow-up decision on the existing review.'
            USING ERRCODE='40001';
    END IF;
    IF (p_status='EDD_REVIEWED' AND (
        staff.role <> 'head_of_compliance' OR prior.status IS DISTINCT FROM 'CONFIRMED_EXPOSURE'
        OR prior.actor_id=staff.id OR prior.exposure IS DISTINCT FROM p_exposure
    )) OR (prior.status IN ('CONFIRMED_EXPOSURE','EDD_REVIEWED') AND p_status NOT IN ('EDD_REVIEWED','CONFIRMED_EXPOSURE'))
    OR (prior.status IN ('CONFIRMED_EXPOSURE','EDD_REVIEWED') AND staff.role <> 'head_of_compliance') THEN
        RAISE EXCEPTION 'Confirmed exposure requires Head of Compliance review' USING ERRCODE='42501';
    END IF;
    INSERT INTO coreaml_private.pep_review_events
        (id,customer_id,tenant_id,subject_id,subject_name,actor_id,status,exposure,evidence,prior_id)
    VALUES (p_request,p_customer,staff.tenant_id,p_subject,subject.full_name,staff.id,
            p_status,p_exposure,btrim(p_evidence),p_prior);
    RETURN p_request;
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

NOTIFY pgrst,'reload schema';
