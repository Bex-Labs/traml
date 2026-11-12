ALTER TABLE coreaml_private.corporate_customer_people
    ADD COLUMN subject_id uuid NOT NULL DEFAULT gen_random_uuid(),
    ADD CONSTRAINT corporate_customer_people_subject_id_key UNIQUE (subject_id);

CREATE TABLE coreaml_private.pep_review_events (
    id uuid PRIMARY KEY,
    customer_id uuid NOT NULL,
    tenant_id text NOT NULL,
    subject_id uuid NOT NULL,
    subject_name text NOT NULL,
    actor_id uuid NOT NULL,
    status text NOT NULL CHECK (status IN (
        'DECLARED_NO_EXPOSURE','POSSIBLE_EXPOSURE','INFORMATION_NEEDED',
        'FALSE_POSITIVE','CONFIRMED_EXPOSURE','EDD_REVIEWED'
    )),
    exposure text CHECK (exposure IN ('DOMESTIC','FOREIGN','INTERNATIONAL_ORGANISATION','FAMILY','CLOSE_ASSOCIATE','UNKNOWN')),
    evidence text NOT NULL CHECK (length(evidence) BETWEEN 10 AND 1000),
    prior_id uuid REFERENCES coreaml_private.pep_review_events(id),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX pep_review_event_subject ON coreaml_private.pep_review_events
    (tenant_id, customer_id, subject_id, created_at DESC, id DESC);
ALTER TABLE coreaml_private.pep_review_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_review_events FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION coreaml_private.pep_subjects(p_bank text,p_customer uuid)
RETURNS TABLE(subject_id uuid, full_name text, person_role text)
LANGUAGE sql STABLE SET search_path='' AS $$
    SELECT c.id, concat_ws(' ',c.first_name,c.middle_name,c.last_name), 'CUSTOMER'::text
    FROM public.customers c
    WHERE c.tenant_id=p_bank AND c.id=p_customer AND c.customer_type='RETAIL'
      AND nullif(btrim(concat_ws(' ',c.first_name,c.middle_name,c.last_name)),'') IS NOT NULL
    UNION ALL
    SELECT p.subject_id,p.full_name,p.person_role
    FROM coreaml_private.corporate_customer_people p
    JOIN public.customers c ON c.id=p.customer_id AND c.tenant_id=p.tenant_id
    WHERE c.tenant_id=p_bank AND c.id=p_customer AND c.customer_type='CORPORATE';
$$;
REVOKE ALL ON FUNCTION coreaml_private.pep_subjects(text,uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.coreaml_pep_subjects(p_customer uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.id=p_customer AND c.tenant_id=staff.tenant_id) THEN
        RAISE EXCEPTION 'Customer unavailable' USING ERRCODE='42501';
    END IF;
    RETURN jsonb_build_object('role',staff.role,'subjects',coalesce((
        SELECT jsonb_agg(to_jsonb(s) || jsonb_build_object('latest',to_jsonb(e))
                         ORDER BY s.full_name,s.person_role,s.subject_id)
        FROM coreaml_private.pep_subjects(staff.tenant_id,p_customer) s
        LEFT JOIN LATERAL (
            SELECT id,status,exposure,evidence,created_at
            FROM coreaml_private.pep_review_events e
            WHERE e.tenant_id=staff.tenant_id AND e.customer_id=p_customer AND e.subject_id=s.subject_id
            ORDER BY e.created_at DESC,e.id DESC LIMIT 1
        ) e ON true
    ),'[]'::jsonb));
END
$$;

CREATE FUNCTION public.coreaml_record_pep_review(
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

CREATE FUNCTION public.coreaml_pep_queue(p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF p_offset IS NULL OR p_offset < 0 THEN RAISE EXCEPTION 'Invalid offset' USING ERRCODE='22023'; END IF;
    RETURN coalesce((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC,q.id DESC)
        FROM (
            SELECT e.id,e.customer_id,e.subject_id,e.subject_name,e.status,e.exposure,e.evidence,e.created_at,
                   coalesce(c.entity_name,concat_ws(' ',c.first_name,c.last_name)) AS customer_name
            FROM coreaml_private.pep_review_events e
            JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
            WHERE e.tenant_id=staff.tenant_id
              AND e.status IN ('POSSIBLE_EXPOSURE','INFORMATION_NEEDED','CONFIRMED_EXPOSURE','EDD_REVIEWED')
              AND NOT EXISTS (SELECT 1 FROM coreaml_private.pep_review_events n WHERE n.prior_id=e.id)
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 26 OFFSET p_offset
        ) q
    ),'[]'::jsonb);
END
$$;
CREATE UNIQUE INDEX pep_review_event_next ON coreaml_private.pep_review_events (prior_id)
    WHERE prior_id IS NOT NULL;

REVOKE ALL ON FUNCTION public.coreaml_pep_subjects(uuid), public.coreaml_pep_queue(integer),
    public.coreaml_record_pep_review(uuid,uuid,uuid,uuid,text,text,text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_pep_subjects(uuid), public.coreaml_pep_queue(integer),
    public.coreaml_record_pep_review(uuid,uuid,uuid,uuid,text,text,text) TO authenticated;
NOTIFY pgrst,'reload schema';
