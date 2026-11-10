-- Hosted sanctions foundation. Install schema and tenant-scoped review endpoints.
-- Onboarding KYC and worker authentication are separate deployment steps.
SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_snapshots (
    sha256 text PRIMARY KEY CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    retrieved_at timestamptz NOT NULL,
    entries jsonb NOT NULL CHECK (jsonb_typeof(entries) = 'array'),
    files jsonb NOT NULL CHECK (jsonb_typeof(files) = 'object')
);

ALTER TABLE coreaml_private.kyc_sanctions_snapshots
    ADD COLUMN IF NOT EXISTS last_verified_at timestamptz;

-- The worker validates the feeds before calling this private entry point.
CREATE OR REPLACE FUNCTION coreaml_private.import_kyc_sanctions_snapshot(
    p_sha256 text, p_retrieved_at timestamptz, p_entries jsonb, p_files jsonb
)
RETURNS jsonb LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
    current_snapshot coreaml_private.kyc_sanctions_snapshots;
    current_time_verified timestamptz;
    same_entries boolean;
BEGIN
    IF p_retrieved_at IS NULL OR p_retrieved_at < now() - interval '7 days'
        OR p_retrieved_at > now() + interval '1 minute' THEN
        RAISE EXCEPTION 'Import requires a current sanctions snapshot' USING ERRCODE = '22023';
    END IF;
    LOCK TABLE coreaml_private.kyc_sanctions_snapshots IN SHARE ROW EXCLUSIVE MODE;
    SELECT * INTO current_snapshot FROM coreaml_private.kyc_sanctions_snapshots
    ORDER BY coalesce(last_verified_at, retrieved_at) DESC, sha256 DESC LIMIT 1;
    IF FOUND THEN
        current_time_verified := coalesce(current_snapshot.last_verified_at, current_snapshot.retrieved_at);
        IF p_retrieved_at < current_time_verified THEN
            RAISE EXCEPTION 'Incoming snapshot is older than the latest successful refresh' USING ERRCODE = '22023';
        END IF;
        SELECT
            (SELECT jsonb_agg(e ORDER BY e->>'source' COLLATE "C", e->>'reference' COLLATE "C")
             FROM jsonb_array_elements(current_snapshot.entries) AS items(e))
            =
            (SELECT jsonb_agg(e ORDER BY e->>'source' COLLATE "C", e->>'reference' COLLATE "C")
             FROM jsonb_array_elements(p_entries) AS items(e))
        INTO same_entries;

        IF same_entries THEN
            UPDATE coreaml_private.kyc_sanctions_snapshots
            SET last_verified_at = p_retrieved_at WHERE sha256 = current_snapshot.sha256;
            RETURN jsonb_build_object('status', 'VERIFIED_UNCHANGED', 'sha256', current_snapshot.sha256);
        END IF;
        IF p_retrieved_at = current_time_verified THEN
            RAISE EXCEPTION 'Different sanctions records have the same retrieval time' USING ERRCODE = '22023';
        END IF;
    END IF;
    INSERT INTO coreaml_private.kyc_sanctions_snapshots(sha256, retrieved_at, entries, files, last_verified_at)
    VALUES (p_sha256, p_retrieved_at, p_entries, p_files, p_retrieved_at);
    RETURN jsonb_build_object('status', 'IMPORTED_LOCAL_PILOT', 'sha256', p_sha256);
END
$$;

REVOKE ALL ON FUNCTION coreaml_private.import_kyc_sanctions_snapshot(text, timestamptz, jsonb, jsonb)
    FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id uuid NOT NULL,
    tenant_id text NOT NULL,
    snapshot_sha256 text NOT NULL REFERENCES coreaml_private.kyc_sanctions_snapshots(sha256),
    name_key text NOT NULL,
    screened_by uuid NOT NULL,
    screened_at timestamptz NOT NULL DEFAULT now(),
    hits jsonb NOT NULL,
    UNIQUE (customer_id, tenant_id, snapshot_sha256, name_key)
);

CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_decisions (
    run_id uuid NOT NULL REFERENCES coreaml_private.kyc_sanctions_runs(id),
    hit_index integer NOT NULL CHECK (hit_index >= 0),
    outcome text NOT NULL CHECK (outcome IN ('CONFIRMED_MATCH', 'FALSE_POSITIVE')),
    rationale text NOT NULL CHECK (length(rationale) BETWEEN 10 AND 1000),
    reviewed_by uuid NOT NULL,
    reviewed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (run_id, hit_index)
);

CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_corrections (
    id uuid PRIMARY KEY,
    run_id uuid NOT NULL,
    hit_index integer NOT NULL,
    reason text NOT NULL CHECK (length(reason) BETWEEN 10 AND 1000),
    evidence_reference text NOT NULL CHECK (length(evidence_reference) BETWEEN 5 AND 500),
    proposed_by uuid NOT NULL,
    proposed_at timestamptz NOT NULL DEFAULT now(),
    state text NOT NULL DEFAULT 'PROPOSED' CHECK (state IN ('PROPOSED', 'APPROVED', 'REJECTED')),
    decided_by uuid,
    decided_at timestamptz,
    decision_reason text CHECK (length(decision_reason) BETWEEN 10 AND 1000),
    FOREIGN KEY (run_id, hit_index) REFERENCES coreaml_private.kyc_sanctions_decisions(run_id, hit_index),
    CHECK (
        (state = 'PROPOSED' AND decided_by IS NULL AND decided_at IS NULL AND decision_reason IS NULL)
        OR (state IN ('APPROVED', 'REJECTED') AND decided_by IS NOT NULL AND decided_by <> proposed_by
            AND decided_at IS NOT NULL AND decision_reason IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS kyc_sanctions_one_open_correction
    ON coreaml_private.kyc_sanctions_corrections (run_id, hit_index)
    WHERE state IN ('PROPOSED', 'APPROVED');

ALTER TABLE coreaml_private.kyc_sanctions_corrections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE coreaml_private.kyc_sanctions_corrections FROM PUBLIC, anon, authenticated, service_role;

ALTER TABLE coreaml_private.kyc_sanctions_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE coreaml_private.kyc_sanctions_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE coreaml_private.kyc_sanctions_decisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE coreaml_private.kyc_sanctions_snapshots, coreaml_private.kyc_sanctions_runs,
    coreaml_private.kyc_sanctions_decisions FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION coreaml_private.kyc_sanctions_name(value text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path = '' AS $$
    SELECT btrim(regexp_replace(lower(normalize(value, NFKC)), '[^[:alnum:]]+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION coreaml_private.kyc_sanctions_tokens(value text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path = '' AS $$
    SELECT string_agg(token, ' ' ORDER BY token COLLATE "C")
    FROM unnest(string_to_array(value, ' ')) AS tokens(token)
$$;

CREATE OR REPLACE FUNCTION coreaml_private.kyc_sanctions_is_person(customer public.customers)
RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path = '' AS $$
    SELECT upper(btrim(customer.customer_type)) IN ('RETAIL', 'INDIVIDUAL')
$$;

CREATE OR REPLACE FUNCTION coreaml_private.kyc_sanctions_customer_name(customer public.customers)
RETURNS text LANGUAGE sql IMMUTABLE STRICT SET search_path = '' AS $$
    SELECT coreaml_private.kyc_sanctions_name(CASE
        WHEN coreaml_private.kyc_sanctions_is_person(customer) THEN
            coalesce(nullif(btrim(concat_ws(' ', customer.first_name, customer.middle_name, customer.last_name)), ''),
                     customer.entity_name)
        ELSE coalesce(nullif(btrim(customer.company_name), ''), customer.entity_name)
    END)
$$;

CREATE OR REPLACE FUNCTION coreaml_private.kyc_sanctions_has_hold(customer_id uuid, tenant_id text)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT EXISTS (
        SELECT 1 FROM coreaml_private.kyc_sanctions_runs r
        JOIN coreaml_private.kyc_sanctions_decisions d ON d.run_id = r.id
        WHERE r.customer_id = $1 AND r.tenant_id = $2 AND d.outcome = 'CONFIRMED_MATCH'
          AND NOT EXISTS (
              SELECT 1 FROM coreaml_private.kyc_sanctions_corrections x
              WHERE x.run_id = d.run_id AND x.hit_index = d.hit_index AND x.state = 'APPROVED'
          )
    )
$$;

-- Preserve the existing run key until an approved correction requires rescreening.
CREATE OR REPLACE FUNCTION coreaml_private.kyc_sanctions_run_key(customer public.customers)
RETURNS text LANGUAGE sql STABLE STRICT SET search_path = '' AS $$
    SELECT md5(coreaml_private.kyc_sanctions_is_person(customer)::text || ':' ||
               coreaml_private.kyc_sanctions_customer_name(customer) ||
               CASE WHEN revision = 0 THEN '' ELSE ':corrections:' || revision::text END)
    FROM (
        SELECT count(*) AS revision
        FROM coreaml_private.kyc_sanctions_corrections x
        JOIN coreaml_private.kyc_sanctions_runs r ON r.id = x.run_id
        WHERE x.state = 'APPROVED' AND r.customer_id = customer.id AND r.tenant_id = customer.tenant_id
    ) revisions
$$;

REVOKE ALL ON FUNCTION coreaml_private.kyc_sanctions_name(text), coreaml_private.kyc_sanctions_tokens(text),
    coreaml_private.kyc_sanctions_is_person(public.customers), coreaml_private.kyc_sanctions_customer_name(public.customers),
    coreaml_private.kyc_sanctions_has_hold(uuid, text), coreaml_private.kyc_sanctions_run_key(public.customers)
    FROM PUBLIC, anon, authenticated, service_role;

-- Enrollment is explicit. A fresh installation has no participating banks.
CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_hosted_tenants (
    tenant_id text PRIMARY KEY CHECK (tenant_id <> '' AND tenant_id = btrim(tenant_id)),
    enabled boolean NOT NULL DEFAULT false
);
ALTER TABLE coreaml_private.kyc_sanctions_hosted_tenants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE coreaml_private.kyc_sanctions_hosted_tenants FROM PUBLIC, anon, authenticated, service_role;

-- Batch candidates and dispositions are separate from onboarding holds.
CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_hosted_batches (
    snapshot_sha256 text NOT NULL REFERENCES coreaml_private.kyc_sanctions_snapshots(sha256),
    tenant_id text NOT NULL REFERENCES coreaml_private.kyc_sanctions_hosted_tenants(tenant_id),
    completed_at timestamptz NOT NULL DEFAULT now(),
    screened_count bigint NOT NULL CHECK (screened_count >= 0),
    skipped_count bigint NOT NULL CHECK (skipped_count >= 0),
    new_candidate_count bigint NOT NULL CHECK (new_candidate_count >= 0),
    PRIMARY KEY (snapshot_sha256, tenant_id)
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

ALTER TABLE coreaml_private.kyc_sanctions_hosted_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE coreaml_private.kyc_sanctions_rescreen_candidates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE coreaml_private.kyc_sanctions_hosted_batches, coreaml_private.kyc_sanctions_rescreen_candidates
    FROM PUBLIC, anon, authenticated, service_role;

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

    INSERT INTO coreaml_private.kyc_sanctions_hosted_batches
        (snapshot_sha256, tenant_id, screened_count, skipped_count, new_candidate_count)
    VALUES (p_sha256, p_tenant_id, screened, skipped, new_candidates);
    RETURN jsonb_build_object('status', 'SCREENED', 'screened_count', screened,
        'skipped_count', skipped, 'new_candidate_count', new_candidates);
END
$$;

REVOKE ALL ON FUNCTION coreaml_private.rescreen_kyc_sanctions_hosted_snapshot(text, text) FROM PUBLIC, anon, authenticated, service_role;

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

-- Keep publication and bank batch receipts in a single transaction. This entry point
-- is owner-only until a scoped worker credential has been provisioned and tested.
CREATE OR REPLACE FUNCTION coreaml_private.publish_kyc_sanctions_hosted_snapshot(
    p_sha256 text, p_retrieved_at timestamptz, p_entries jsonb, p_files jsonb
)
RETURNS jsonb LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
    receipt jsonb;
    batches jsonb;
BEGIN
    IF jsonb_typeof(p_entries) IS DISTINCT FROM 'array'
        OR jsonb_typeof(p_files) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'Invalid watchlist snapshot payload' USING ERRCODE = '22023';
    END IF;
    IF jsonb_array_length(p_entries) NOT BETWEEN 4 AND 100000 OR
        (SELECT count(DISTINCT e->>'source') FROM jsonb_array_elements(p_entries) rows(e)
            WHERE e->>'source' IN ('UN','OFAC_SDN','OFAC_NON_SDN','NIGERIA')) <> 4 THEN
        RAISE EXCEPTION 'Watchlist snapshot is missing required sources or exceeds the pilot limit'
            USING ERRCODE = '22023';
    END IF;
    -- Enrollment changes take effect between publication runs.
    LOCK TABLE coreaml_private.kyc_sanctions_hosted_tenants IN SHARE MODE;
    receipt := coreaml_private.import_kyc_sanctions_snapshot(p_sha256, p_retrieved_at, p_entries, p_files);
    SELECT coalesce(jsonb_agg(coreaml_private.rescreen_kyc_sanctions_hosted_snapshot(receipt->>'sha256', tenant_id)),
        '[]'::jsonb)
    INTO batches FROM coreaml_private.kyc_sanctions_hosted_tenants WHERE enabled;
    RETURN receipt || jsonb_build_object('rescreening_batches', batches);
END
$$;

REVOKE ALL ON FUNCTION coreaml_private.publish_kyc_sanctions_hosted_snapshot(text, timestamptz, jsonb, jsonb)
    FROM PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
