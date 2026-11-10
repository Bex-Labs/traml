-- Hosted applicant screening audit trail. Approval and account activation are separate.
CREATE OR REPLACE FUNCTION coreaml_private.kyc_sanctions_hosted_receipt(p_run_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT jsonb_build_object(
        'mode', 'HOSTED_AUDIT', 'run_id', r.id, 'customer_id', r.customer_id,
        'screened_at', r.screened_at, 'screened_by', r.screened_by,
        'snapshot_sha256', s.sha256, 'retrieved_at', s.retrieved_at,
        'last_verified_at', coalesce(s.last_verified_at, s.retrieved_at), 'hits', r.hits,
        'decisions', coalesce((
            SELECT jsonb_object_agg(d.hit_index, jsonb_build_object(
                'outcome', d.outcome, 'rationale', d.rationale,
                'reviewed_by', d.reviewed_by, 'reviewed_at', d.reviewed_at
            ))
            FROM coreaml_private.kyc_sanctions_decisions d WHERE d.run_id = r.id
        ), '{}'::jsonb)
    )
    FROM coreaml_private.kyc_sanctions_runs r
    JOIN coreaml_private.kyc_sanctions_snapshots s ON s.sha256 = r.snapshot_sha256
    WHERE r.id = p_run_id
$$;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_screen_hosted_sanctions(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    customer public.customers;
    preview jsonb;
    run_id uuid;
    fingerprint text;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer', 'head_of_compliance']);
    SELECT * INTO customer FROM public.customers c
    WHERE c.id = p_customer_id AND c.tenant_id = staff.tenant_id
      AND c.kyc_status IN ('PENDING', 'PENDING_EDD') FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pending application unavailable in your bank' USING ERRCODE = '42501';
    END IF;

    preview := public.coreaml_kyc_preview_sanctions(customer.id);
    fingerprint := coreaml_private.kyc_sanctions_run_key(customer);
    INSERT INTO coreaml_private.kyc_sanctions_runs(customer_id, tenant_id, snapshot_sha256, name_key, screened_by, hits)
    VALUES (customer.id, staff.tenant_id, preview->>'snapshot_sha256', fingerprint, staff.id, preview->'hits')
    ON CONFLICT (customer_id, tenant_id, snapshot_sha256, name_key) DO NOTHING
    RETURNING id INTO run_id;

    IF run_id IS NULL THEN
        SELECT r.id INTO STRICT run_id FROM coreaml_private.kyc_sanctions_runs r
        WHERE r.customer_id = customer.id AND r.tenant_id = staff.tenant_id
          AND r.snapshot_sha256 = preview->>'snapshot_sha256' AND r.name_key = fingerprint;
    END IF;
    RETURN coreaml_private.kyc_sanctions_hosted_receipt(run_id);
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_review_hosted_sanctions(
    p_run_id uuid, p_hit_index integer, p_outcome text, p_rationale text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    customer public.customers;
    screened coreaml_private.kyc_sanctions_runs;
    saved coreaml_private.kyc_sanctions_decisions;
    latest_snapshot coreaml_private.kyc_sanctions_snapshots;
    rationale text := btrim(p_rationale);
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer', 'head_of_compliance']);
    SELECT * INTO screened FROM coreaml_private.kyc_sanctions_runs r
    WHERE r.id = p_run_id AND r.tenant_id = staff.tenant_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Screening run unavailable in your bank' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO customer FROM public.customers c
    WHERE c.id = screened.customer_id AND c.tenant_id = staff.tenant_id
      AND c.kyc_status IN ('PENDING', 'PENDING_EDD') FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pending application unavailable in your bank' USING ERRCODE = '42501';
    END IF;
    IF p_hit_index IS NULL OR p_hit_index < 0 OR p_hit_index >= jsonb_array_length(screened.hits)
        OR p_outcome IS NULL OR p_outcome NOT IN ('CONFIRMED_MATCH', 'FALSE_POSITIVE')
        OR rationale IS NULL OR length(rationale) NOT BETWEEN 10 AND 1000 THEN
        RAISE EXCEPTION 'Select a candidate and enter a review reason of 10 to 1000 characters' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO saved FROM coreaml_private.kyc_sanctions_decisions d
    WHERE d.run_id = p_run_id AND d.hit_index = p_hit_index;
    IF FOUND THEN
        IF (saved.outcome, saved.rationale, saved.reviewed_by) IS DISTINCT FROM (p_outcome, rationale, staff.id) THEN
            RAISE EXCEPTION 'A decision is already recorded for this candidate. Reload the screening result.'
                USING ERRCODE = '23505';
        END IF;
        RETURN coreaml_private.kyc_sanctions_hosted_receipt(p_run_id);
    END IF;

    -- Prevent a publish or applicant change from superseding a new decision while it is saved.
    LOCK TABLE coreaml_private.kyc_sanctions_snapshots IN SHARE MODE;
    SELECT * INTO latest_snapshot FROM coreaml_private.kyc_sanctions_snapshots
    ORDER BY coalesce(last_verified_at, retrieved_at) DESC, sha256 DESC LIMIT 1;
    IF screened.snapshot_sha256 IS DISTINCT FROM latest_snapshot.sha256
        OR coalesce(latest_snapshot.last_verified_at, latest_snapshot.retrieved_at) < now() - interval '7 days'
        OR screened.name_key IS DISTINCT FROM coreaml_private.kyc_sanctions_run_key(customer) THEN
        RAISE EXCEPTION 'Screening is no longer current. Run the sanctions check again.' USING ERRCODE = '22023';
    END IF;

    INSERT INTO coreaml_private.kyc_sanctions_decisions(run_id, hit_index, outcome, rationale, reviewed_by)
    VALUES (p_run_id, p_hit_index, p_outcome, rationale, staff.id);
    RETURN coreaml_private.kyc_sanctions_hosted_receipt(p_run_id);
END
$$;

REVOKE ALL ON FUNCTION coreaml_private.kyc_sanctions_hosted_receipt(uuid)
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.coreaml_kyc_screen_hosted_sanctions(uuid),
    public.coreaml_kyc_review_hosted_sanctions(uuid, integer, text, text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_kyc_screen_hosted_sanctions(uuid),
    public.coreaml_kyc_review_hosted_sanctions(uuid, integer, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION coreaml_private.rescreen_kyc_sanctions_hosted_snapshot(p_sha256 text, p_tenant_id text)
RETURNS jsonb LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
    snapshot coreaml_private.kyc_sanctions_snapshots;
    batch coreaml_private.kyc_sanctions_hosted_batches;
    screened bigint;
    skipped bigint;
    new_candidates bigint;
BEGIN
    -- Serialize with imports and reject requests for a stale or superseded snapshot.
    LOCK TABLE coreaml_private.kyc_sanctions_snapshots IN SHARE ROW EXCLUSIVE MODE;
    SELECT * INTO snapshot FROM coreaml_private.kyc_sanctions_snapshots
    ORDER BY coalesce(last_verified_at, retrieved_at) DESC, sha256 DESC LIMIT 1;
    IF NOT FOUND OR snapshot.sha256 IS DISTINCT FROM p_sha256
        OR coalesce(snapshot.last_verified_at, snapshot.retrieved_at) < now() - interval '7 days' THEN
        RAISE EXCEPTION 'Rescreening requires the current verified snapshot' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM coreaml_private.kyc_sanctions_hosted_tenants
        WHERE tenant_id = p_tenant_id AND enabled) THEN
        RAISE EXCEPTION 'Bank has not enabled hosted sanctions rescreening' USING ERRCODE = '42501';
    END IF;
    SELECT * INTO batch FROM coreaml_private.kyc_sanctions_hosted_batches
    WHERE snapshot_sha256 = p_sha256 AND tenant_id = p_tenant_id;
    IF FOUND THEN
        RETURN jsonb_build_object('status', 'ALREADY_SCREENED', 'screened_count', batch.screened_count,
            'skipped_count', batch.skipped_count, 'new_candidate_count', 0);
    END IF;

    -- Normalize list labels once per snapshot. Match canonical names and aliases,
    -- with order-insensitive individual matches as in the manual KYC pilot.
    WITH customers AS MATERIALIZED (
        SELECT c.id, c.tenant_id, coreaml_private.kyc_sanctions_customer_name(c) AS name,
            coreaml_private.kyc_sanctions_is_person(c) AS person
        FROM public.customers c
        WHERE c.kyc_status = 'COMPLETED' AND c.tenant_id = p_tenant_id
    ), watchlist AS MATERIALIZED (
        SELECT entry - 'aliases' AS evidence, entry->>'kind' = 'individual' AS person,
            candidate.label, candidate.priority, coreaml_private.kyc_sanctions_name(candidate.label) AS name
        FROM jsonb_array_elements(snapshot.entries) AS entries(entry)
        CROSS JOIN LATERAL (
            SELECT entry->>'name' AS label, 0 AS priority
            UNION ALL
            SELECT alias, 1 FROM jsonb_array_elements_text(entry->'aliases') AS aliases(alias)
        ) candidate
        WHERE entry->>'kind' IN ('individual', 'entity')
    ), names AS (
        SELECT person, name AS match_key, evidence, label, priority FROM watchlist
        WHERE NOT person AND name <> ''
        UNION ALL
        SELECT person, coreaml_private.kyc_sanctions_tokens(name), evidence, label, priority FROM watchlist
        WHERE person AND name <> ''
    ), matches AS (
        SELECT DISTINCT ON (c.tenant_id, c.id, w.evidence->>'source', w.evidence->>'reference')
            c.tenant_id, c.id AS customer_id, c.name, c.person,
            w.evidence || jsonb_build_object('matched_name', w.label) AS hit
        FROM customers c
        JOIN names w ON w.person = c.person AND w.match_key = CASE WHEN c.person
            THEN coreaml_private.kyc_sanctions_tokens(c.name) ELSE c.name END
        WHERE c.name <> ''
        ORDER BY c.tenant_id, c.id, w.evidence->>'source', w.evidence->>'reference', w.priority, w.label COLLATE "C"
    ), inserted AS (
        INSERT INTO coreaml_private.kyc_sanctions_rescreen_candidates
            (tenant_id, customer_id, name_key, hit_key, snapshot_sha256, hit)
        SELECT m.tenant_id, m.customer_id, md5(m.person::text || ':' || m.name),
            encode(sha256(convert_to(m.hit::text, 'UTF8')), 'hex'), p_sha256, m.hit
        FROM matches m
        WHERE NOT EXISTS (
            -- A false positive can suppress the same evidence. Confirmed matches stay eligible.
            SELECT 1 FROM coreaml_private.kyc_sanctions_runs r
            JOIN coreaml_private.kyc_sanctions_decisions d ON d.run_id = r.id
            JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
            WHERE r.tenant_id = m.tenant_id AND r.customer_id = m.customer_id
                AND r.name_key = coreaml_private.kyc_sanctions_run_key(c)
                AND d.outcome = 'FALSE_POSITIVE'
                AND r.hits->d.hit_index = m.hit
        )
        ON CONFLICT (tenant_id, customer_id, name_key, hit_key) DO NOTHING
        RETURNING id
    )
    SELECT count(*) FILTER (WHERE name <> '' AND person IS NOT NULL),
        count(*) FILTER (WHERE coalesce(name, '') = '' OR person IS NULL),
        (SELECT count(*) FROM inserted)
    INTO screened, skipped, new_candidates
    FROM customers;

    INSERT INTO coreaml_private.kyc_sanctions_hosted_batches
        (snapshot_sha256, tenant_id, screened_count, skipped_count, new_candidate_count)
    VALUES (p_sha256, p_tenant_id, screened, skipped, new_candidates);
    RETURN jsonb_build_object('status', 'SCREENED', 'screened_count', screened,
        'skipped_count', skipped, 'new_candidate_count', new_candidates);
END
$$;

NOTIFY pgrst, 'reload schema';
