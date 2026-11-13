-- Scheduled roster publishers have no signed-in reviewer.
ALTER TABLE coreaml_private.pep_review_events ALTER COLUMN actor_id DROP NOT NULL;

CREATE TABLE coreaml_private.pep_rescreen_evidence (
    event_id uuid PRIMARY KEY REFERENCES coreaml_private.pep_review_events(id),
    source_evidence jsonb NOT NULL,
    assigned_to uuid
);
ALTER TABLE coreaml_private.pep_rescreen_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_rescreen_evidence FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION coreaml_private.queue_pep_roster_changes()
RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE
    candidates jsonb;
    matched record;
    prior coreaml_private.pep_review_events;
    evidence jsonb;
    event_id uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_agg(to_jsonb(r)) INTO candidates
        FROM roster_new r JOIN roster_old o USING (source_reference)
        WHERE r.checked_at <= clock_timestamp() AND r.valid_until > clock_timestamp()
          AND (r.full_name,r.public_role,r.jurisdiction,r.source_name)
              IS DISTINCT FROM (o.full_name,o.public_role,o.jurisdiction,o.source_name);
    ELSE
        SELECT jsonb_agg(to_jsonb(r)) INTO candidates FROM roster_new r
        WHERE r.checked_at <= clock_timestamp() AND r.valid_until > clock_timestamp();
    END IF;
    IF candidates IS NULL THEN RETURN NULL; END IF;

    FOR matched IN
        WITH subjects AS (
            SELECT c.id AS customer_id,c.tenant_id,c.id AS subject_id,
                   concat_ws(' ',c.first_name,c.middle_name,c.last_name) AS full_name
            FROM public.customers c WHERE c.kyc_status='COMPLETED' AND c.customer_type='RETAIL'
            UNION ALL
            SELECT c.id,c.tenant_id,p.subject_id,p.full_name
            FROM public.customers c
            JOIN coreaml_private.corporate_customer_people p ON p.customer_id=c.id AND p.tenant_id=c.tenant_id
            WHERE c.kyc_status='COMPLETED' AND c.customer_type='CORPORATE'
        ), roster AS (
            SELECT r.* FROM jsonb_to_recordset(candidates) AS r(
                source_reference text,full_name text,public_role text,jurisdiction text,source_name text,checked_at timestamptz)
        )
        SELECT s.customer_id,s.tenant_id,s.subject_id,s.full_name,
               jsonb_agg(to_jsonb(r) ORDER BY r.source_reference) AS hits
        FROM subjects s JOIN roster r
          ON lower(regexp_replace(btrim(r.full_name),'[[:space:]]+',' ','g')) =
             lower(regexp_replace(btrim(s.full_name),'[[:space:]]+',' ','g'))
        GROUP BY s.customer_id,s.tenant_id,s.subject_id,s.full_name
        ORDER BY s.customer_id,s.subject_id
    LOOP
        -- Use the same lock as the signed-in review RPC.
        PERFORM pg_advisory_xact_lock(hashtextextended(matched.customer_id::text||':'||matched.subject_id::text,0));
        SELECT e.* INTO prior
        FROM coreaml_private.pep_review_events e
        WHERE e.tenant_id=matched.tenant_id AND e.customer_id=matched.customer_id AND e.subject_id=matched.subject_id
        ORDER BY e.created_at DESC,e.id DESC LIMIT 1;
        IF prior.status IN ('CONFIRMED_EXPOSURE','EDD_REVIEWED') THEN CONTINUE; END IF;

        SELECT jsonb_agg(hit ORDER BY hit->>'source_reference') INTO evidence
        FROM jsonb_array_elements(matched.hits) AS hits(hit)
        WHERE NOT EXISTS (
            SELECT 1 FROM coreaml_private.pep_onboarding_tasks t
            CROSS JOIN LATERAL jsonb_array_elements(t.source_evidence) AS known(item)
            WHERE t.tenant_id=matched.tenant_id AND t.customer_id=matched.customer_id AND t.subject_id=matched.subject_id
              AND (item - 'checked_at') = (hit - 'checked_at')
            UNION ALL
            SELECT 1 FROM coreaml_private.pep_review_events e
            JOIN coreaml_private.pep_rescreen_evidence s ON s.event_id=e.id
            CROSS JOIN LATERAL jsonb_array_elements(s.source_evidence) AS known(item)
            WHERE e.tenant_id=matched.tenant_id AND e.customer_id=matched.customer_id AND e.subject_id=matched.subject_id
              AND (item - 'checked_at') = (hit - 'checked_at')
        );
        IF evidence IS NULL THEN CONTINUE; END IF;

        INSERT INTO coreaml_private.pep_review_events
            (id,customer_id,tenant_id,subject_id,subject_name,actor_id,status,exposure,evidence,prior_id)
        VALUES (gen_random_uuid(),matched.customer_id,matched.tenant_id,matched.subject_id,matched.full_name,
                NULL,'POSSIBLE_EXPOSURE','UNKNOWN',
                'Possible name match from roster rescreening. Compare identity before confirming exposure.',prior.id)
        RETURNING id INTO event_id;
        INSERT INTO coreaml_private.pep_rescreen_evidence
        VALUES (event_id,evidence,(
            SELECT p.id FROM public.user_profiles p
            WHERE p.tenant_id=matched.tenant_id AND p.role='compliance_officer' AND p.is_active
            ORDER BY p.id LIMIT 1
        ));
    END LOOP;
    RETURN NULL;
END
$$;
REVOKE ALL ON FUNCTION coreaml_private.queue_pep_roster_changes() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER pep_rescreen_roster_insert
AFTER INSERT ON coreaml_private.pep_officeholder_records
REFERENCING NEW TABLE AS roster_new
FOR EACH STATEMENT EXECUTE FUNCTION coreaml_private.queue_pep_roster_changes();

CREATE TRIGGER pep_rescreen_roster_update
AFTER UPDATE ON coreaml_private.pep_officeholder_records
REFERENCING OLD TABLE AS roster_old NEW TABLE AS roster_new
FOR EACH STATEMENT EXECUTE FUNCTION coreaml_private.queue_pep_roster_changes();

CREATE OR REPLACE FUNCTION public.coreaml_pep_subjects(p_customer uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.id=p_customer AND c.tenant_id=staff.tenant_id) THEN
        RAISE EXCEPTION 'Customer unavailable' USING ERRCODE='42501';
    END IF;
    RETURN jsonb_build_object('role',staff.role,'subjects',coalesce((
        SELECT jsonb_agg(to_jsonb(s) || jsonb_build_object('latest',to_jsonb(e),'onboarding',to_jsonb(t),'rescreening',rs.source_evidence)
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
    ),'[]'::jsonb));
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_pep_queue(p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF p_offset IS NULL OR p_offset < 0 THEN RAISE EXCEPTION 'Invalid offset' USING ERRCODE='22023'; END IF;
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
              AND NOT EXISTS (SELECT 1 FROM coreaml_private.pep_review_events n WHERE n.prior_id=e.id)
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 26 OFFSET p_offset
        ) q
    ),'[]'::jsonb);
END
$$;
NOTIFY pgrst, 'reload schema';
