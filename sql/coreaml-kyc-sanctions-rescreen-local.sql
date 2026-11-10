-- Local pilot. Batch candidates and their dispositions are separate from onboarding holds.
CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_rescreen_batches (
    snapshot_sha256 text PRIMARY KEY REFERENCES coreaml_private.kyc_sanctions_snapshots(sha256),
    completed_at timestamptz NOT NULL DEFAULT now(),
    screened_count bigint NOT NULL CHECK (screened_count >= 0),
    skipped_count bigint NOT NULL CHECK (skipped_count >= 0),
    new_candidate_count bigint NOT NULL CHECK (new_candidate_count >= 0)
);

CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_rescreen_candidates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id text NOT NULL,
    customer_id uuid NOT NULL,
    name_key text NOT NULL,
    hit_key text NOT NULL,
    snapshot_sha256 text NOT NULL REFERENCES coreaml_private.kyc_sanctions_snapshots(sha256),
    hit jsonb NOT NULL CHECK (jsonb_typeof(hit) = 'object'),
    detected_at timestamptz NOT NULL DEFAULT now(),
    disposition text CHECK (disposition IN ('FALSE_POSITIVE', 'FOLLOW_UP')),
    rationale text CHECK (length(rationale) BETWEEN 10 AND 1000),
    reviewed_by uuid,
    reviewed_at timestamptz,
    UNIQUE (tenant_id, customer_id, name_key, hit_key),
    CHECK ((disposition IS NULL AND rationale IS NULL AND reviewed_by IS NULL AND reviewed_at IS NULL)
        OR (disposition IS NOT NULL AND rationale IS NOT NULL AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS kyc_sanctions_rescreen_queue
    ON coreaml_private.kyc_sanctions_rescreen_candidates (tenant_id, (disposition IS NOT NULL), detected_at DESC, id);

ALTER TABLE coreaml_private.kyc_sanctions_rescreen_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE coreaml_private.kyc_sanctions_rescreen_candidates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE coreaml_private.kyc_sanctions_rescreen_batches, coreaml_private.kyc_sanctions_rescreen_candidates
    FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION coreaml_private.rescreen_kyc_sanctions_snapshot(p_sha256 text)
RETURNS jsonb LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
    snapshot coreaml_private.kyc_sanctions_snapshots;
    batch coreaml_private.kyc_sanctions_rescreen_batches;
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

    SELECT * INTO batch FROM coreaml_private.kyc_sanctions_rescreen_batches WHERE snapshot_sha256 = p_sha256;
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
        WHERE c.kyc_status = 'COMPLETED' AND nullif(btrim(c.tenant_id), '') IS NOT NULL
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
            -- Keep same-evidence manual decisions for the customer's current recorded identity.
            SELECT 1 FROM coreaml_private.kyc_sanctions_runs r
            JOIN coreaml_private.kyc_sanctions_decisions d ON d.run_id = r.id
            JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
            WHERE r.tenant_id = m.tenant_id AND r.customer_id = m.customer_id
                AND r.name_key = coreaml_private.kyc_sanctions_run_key(c)
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

    INSERT INTO coreaml_private.kyc_sanctions_rescreen_batches
        (snapshot_sha256, screened_count, skipped_count, new_candidate_count)
    VALUES (p_sha256, screened, skipped, new_candidates);
    RETURN jsonb_build_object('status', 'SCREENED', 'screened_count', screened,
        'skipped_count', skipped, 'new_candidate_count', new_candidates);
END
$$;

REVOKE ALL ON FUNCTION coreaml_private.rescreen_kyc_sanctions_snapshot(text) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_sanctions_rescreen_page(p_offset integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    items jsonb;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    IF p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 100000 THEN
        RAISE EXCEPTION 'Invalid rescreening page' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(jsonb_agg(to_jsonb(rows) ORDER BY rows.disposition IS NOT NULL, rows.detected_at DESC, rows.id), '[]'::jsonb)
    INTO items
    FROM (
        SELECT r.id, r.customer_id, r.hit, r.detected_at, r.snapshot_sha256,
            r.disposition, r.rationale, r.reviewed_at, s.retrieved_at,
            r.name_key IS DISTINCT FROM md5(coreaml_private.kyc_sanctions_is_person(c)::text || ':' ||
                coreaml_private.kyc_sanctions_customer_name(c)) AS identity_changed,
            coalesce(CASE WHEN coreaml_private.kyc_sanctions_is_person(c)
                THEN nullif(btrim(concat_ws(' ', c.first_name, c.middle_name, c.last_name)), '')
                ELSE nullif(btrim(c.company_name), '') END, nullif(btrim(c.entity_name), ''), 'Customer') AS applicant_name
        FROM coreaml_private.kyc_sanctions_rescreen_candidates r
        JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
        JOIN coreaml_private.kyc_sanctions_snapshots s ON s.sha256 = r.snapshot_sha256
        WHERE r.tenant_id = staff.tenant_id
        ORDER BY r.disposition IS NOT NULL, r.detected_at DESC, r.id
        OFFSET p_offset LIMIT 26
    ) rows;
    RETURN items;
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_sanctions_review_rescreen_match(
    p_candidate_id uuid, p_disposition text, p_rationale text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    candidate coreaml_private.kyc_sanctions_rescreen_candidates;
    reason text := btrim(p_rationale);
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    IF p_disposition IS NULL OR p_disposition NOT IN ('FALSE_POSITIVE', 'FOLLOW_UP')
        OR reason IS NULL OR length(reason) NOT BETWEEN 10 AND 1000 THEN
        RAISE EXCEPTION 'Choose a disposition and enter a review reason' USING ERRCODE = '22023';
    END IF;

    SELECT r.* INTO candidate FROM coreaml_private.kyc_sanctions_rescreen_candidates r
    JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
    WHERE r.id = p_candidate_id AND r.tenant_id = staff.tenant_id
    FOR UPDATE OF r FOR SHARE OF c;
    IF NOT FOUND THEN RAISE EXCEPTION 'Rescreening match unavailable in your bank' USING ERRCODE = '42501'; END IF;

    IF candidate.disposition IS NULL THEN
        UPDATE coreaml_private.kyc_sanctions_rescreen_candidates
        SET disposition = p_disposition, rationale = reason, reviewed_by = staff.id, reviewed_at = now()
        WHERE id = candidate.id;
    ELSIF (candidate.disposition, candidate.rationale, candidate.reviewed_by)
        IS DISTINCT FROM (p_disposition, reason, staff.id) THEN
        RAISE EXCEPTION 'This match already has a recorded disposition' USING ERRCODE = '23505';
    END IF;
    RETURN jsonb_build_object('id', candidate.id, 'disposition', p_disposition);
END
$$;

REVOKE ALL ON FUNCTION public.coreaml_kyc_sanctions_rescreen_page(integer),
    public.coreaml_kyc_sanctions_review_rescreen_match(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_kyc_sanctions_rescreen_page(integer),
    public.coreaml_kyc_sanctions_review_rescreen_match(uuid, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
