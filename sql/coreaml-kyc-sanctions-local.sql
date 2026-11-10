-- Local pilot. The operational watchlist and KYC approval functions are separate.
CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_snapshots (
    sha256 text PRIMARY KEY CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    retrieved_at timestamptz NOT NULL,
    entries jsonb NOT NULL CHECK (jsonb_typeof(entries) = 'array'),
    files jsonb NOT NULL CHECK (jsonb_typeof(files) = 'object')
);

ALTER TABLE coreaml_private.kyc_sanctions_snapshots
    ADD COLUMN IF NOT EXISTS last_verified_at timestamptz;

-- The importer validates the feeds before calling this local, private entry point.
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

CREATE OR REPLACE FUNCTION coreaml_private.kyc_sanctions_receipt(run_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT jsonb_build_object(
        'run_id', r.id, 'customer_id', r.customer_id, 'mode', 'LOCAL_PILOT',
        'screened_at', r.screened_at, 'retrieved_at', s.retrieved_at,
        'last_verified_at', coalesce(s.last_verified_at, s.retrieved_at),
        'snapshot_sha256', s.sha256, 'hits', r.hits,
        'confirmed_hold', coreaml_private.kyc_sanctions_has_hold(r.customer_id, r.tenant_id),
        'decisions', coalesce((
            SELECT jsonb_object_agg(d.hit_index, jsonb_build_object(
                'outcome', d.outcome, 'rationale', d.rationale, 'reviewed_at', d.reviewed_at
            ))
            FROM coreaml_private.kyc_sanctions_decisions d WHERE d.run_id = r.id
        ), '{}'::jsonb)
    )
    FROM coreaml_private.kyc_sanctions_runs r
    JOIN coreaml_private.kyc_sanctions_snapshots s ON s.sha256 = r.snapshot_sha256
    WHERE r.id = $1
$$;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_screen_sanctions(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    customer public.customers;
    snapshot coreaml_private.kyc_sanctions_snapshots;
    person boolean;
    name text;
    token_key text;
    fingerprint text;
    found_hits jsonb;
    run_id uuid;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer', 'head_of_compliance']);
    SELECT * INTO customer FROM public.customers c WHERE c.id = p_customer_id AND c.tenant_id = staff.tenant_id FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Application unavailable in your bank' USING ERRCODE = '42501'; END IF;

    person := coreaml_private.kyc_sanctions_is_person(customer);
    name := coreaml_private.kyc_sanctions_customer_name(customer);
    IF coalesce(name, '') = '' THEN RAISE EXCEPTION 'Application has no recorded name to screen' USING ERRCODE = '22023'; END IF;

    SELECT * INTO snapshot FROM coreaml_private.kyc_sanctions_snapshots
    ORDER BY coalesce(last_verified_at, retrieved_at) DESC, sha256 DESC LIMIT 1;
    IF NOT FOUND OR coalesce(snapshot.last_verified_at, snapshot.retrieved_at) < now() - interval '7 days' THEN
        RAISE EXCEPTION 'Import a current official sanctions snapshot before screening' USING ERRCODE = '22023';
    END IF;
    fingerprint := coreaml_private.kyc_sanctions_run_key(customer);
    SELECT r.id INTO run_id FROM coreaml_private.kyc_sanctions_runs r
    WHERE r.customer_id = customer.id AND r.tenant_id = staff.tenant_id
      AND r.snapshot_sha256 = snapshot.sha256 AND r.name_key = fingerprint;
    IF FOUND THEN RETURN coreaml_private.kyc_sanctions_receipt(run_id); END IF;

    token_key := coreaml_private.kyc_sanctions_tokens(name);
    SELECT coalesce(jsonb_agg(hit ORDER BY hit->>'source', hit->>'reference'), '[]'::jsonb)
    INTO found_hits
    FROM (
        SELECT entry - 'aliases' || jsonb_build_object('matched_name', candidate.label) AS hit
        FROM jsonb_array_elements(snapshot.entries) AS items(entry)
        CROSS JOIN LATERAL (
            SELECT label FROM (
                SELECT entry->>'name' AS label, 0 AS priority
                UNION ALL
                SELECT alias, 1 FROM jsonb_array_elements_text(entry->'aliases') AS aliases(alias)
            ) names
            CROSS JOIN LATERAL (SELECT coreaml_private.kyc_sanctions_name(label) AS key) normalized
            WHERE normalized.key = name
               OR (person AND entry->>'kind' = 'individual' AND coreaml_private.kyc_sanctions_tokens(normalized.key) = token_key)
            ORDER BY priority, label COLLATE "C" LIMIT 1
        ) candidate
        WHERE entry->>'kind' = CASE WHEN person THEN 'individual' ELSE 'entity' END
        LIMIT 51
    ) matches;
    IF jsonb_array_length(found_hits) > 50 THEN
        RAISE EXCEPTION 'Too many candidate matches for this pilot. Review the source lists manually.' USING ERRCODE = '22023';
    END IF;

    INSERT INTO coreaml_private.kyc_sanctions_runs(customer_id, tenant_id, snapshot_sha256, name_key, screened_by, hits)
    VALUES (customer.id, staff.tenant_id, snapshot.sha256, fingerprint, staff.id, found_hits)
    ON CONFLICT (customer_id, tenant_id, snapshot_sha256, name_key) DO NOTHING
    RETURNING id INTO run_id;
    IF run_id IS NULL THEN
        SELECT r.id INTO STRICT run_id FROM coreaml_private.kyc_sanctions_runs r
        WHERE r.customer_id = customer.id AND r.tenant_id = staff.tenant_id
          AND r.snapshot_sha256 = snapshot.sha256 AND r.name_key = fingerprint;
    END IF;
    RETURN coreaml_private.kyc_sanctions_receipt(run_id);
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_review_sanctions(
    p_run_id uuid, p_hit_index integer, p_outcome text, p_rationale text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    screened coreaml_private.kyc_sanctions_runs;
    saved coreaml_private.kyc_sanctions_decisions;
    rationale text := btrim(p_rationale);
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer', 'head_of_compliance']);
    SELECT r.* INTO screened FROM coreaml_private.kyc_sanctions_runs r
    JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
    WHERE r.id = p_run_id AND r.tenant_id = staff.tenant_id AND c.kyc_status = 'PENDING'
    FOR UPDATE OF c;
    IF NOT FOUND THEN RAISE EXCEPTION 'Screening run unavailable in your bank' USING ERRCODE = '42501'; END IF;
    IF p_hit_index IS NULL OR p_hit_index < 0 OR p_hit_index >= jsonb_array_length(screened.hits)
        OR p_outcome IS NULL OR p_outcome NOT IN ('CONFIRMED_MATCH', 'FALSE_POSITIVE')
        OR rationale IS NULL OR length(rationale) NOT BETWEEN 10 AND 1000 THEN
        RAISE EXCEPTION 'Select a candidate and enter a review reason of 10 to 1000 characters' USING ERRCODE = '22023';
    END IF;

    INSERT INTO coreaml_private.kyc_sanctions_decisions(run_id, hit_index, outcome, rationale, reviewed_by)
    VALUES (p_run_id, p_hit_index, p_outcome, rationale, staff.id)
    ON CONFLICT (run_id, hit_index) DO NOTHING;
    SELECT * INTO STRICT saved FROM coreaml_private.kyc_sanctions_decisions d
    WHERE d.run_id = p_run_id AND d.hit_index = p_hit_index;
    IF (saved.outcome, saved.rationale, saved.reviewed_by) IS DISTINCT FROM (p_outcome, rationale, staff.id) THEN
        RAISE EXCEPTION 'This candidate already has a recorded decision. Reload the screening result.' USING ERRCODE = '23505';
    END IF;
    RETURN coreaml_private.kyc_sanctions_receipt(p_run_id);
END
$$;

REVOKE ALL ON FUNCTION coreaml_private.kyc_sanctions_name(text), coreaml_private.kyc_sanctions_tokens(text),
    coreaml_private.kyc_sanctions_receipt(uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.coreaml_kyc_screen_sanctions(uuid),
    public.coreaml_kyc_review_sanctions(uuid, integer, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_kyc_screen_sanctions(uuid),
    public.coreaml_kyc_review_sanctions(uuid, integer, text, text) TO authenticated;

-- Existing reviews retain their original evidence and retry behavior.
ALTER TABLE public.kyc_reviews ADD COLUMN IF NOT EXISTS sanctions_run_id uuid
    REFERENCES coreaml_private.kyc_sanctions_runs(id);

CREATE OR REPLACE FUNCTION coreaml_private.require_kyc_sanctions_evidence()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    customer public.customers;
    snapshot coreaml_private.kyc_sanctions_snapshots;
    screened coreaml_private.kyc_sanctions_runs;
    fingerprint text;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer', 'head_of_compliance']);
    IF NEW.reviewer_id IS DISTINCT FROM staff.id OR NEW.tenant_id IS DISTINCT FROM staff.tenant_id THEN
        RAISE EXCEPTION 'Active same-bank KYC reviewer required' USING ERRCODE = '42501';
    END IF;
    -- The same customer lock serializes approval and sanctions decisions.
    SELECT * INTO customer FROM public.customers c
    WHERE c.id = NEW.customer_id AND c.tenant_id = staff.tenant_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Application unavailable in your bank' USING ERRCODE = '42501'; END IF;
    IF coreaml_private.kyc_sanctions_has_hold(customer.id, staff.tenant_id) THEN
        RAISE EXCEPTION 'A confirmed sanctions match is referred to Head of Compliance. Account activation is on hold.' USING ERRCODE = '23514';
    END IF;

    -- Prevent a new snapshot from becoming current while this approval commits.
    LOCK TABLE coreaml_private.kyc_sanctions_snapshots IN SHARE MODE;
    SELECT * INTO snapshot FROM coreaml_private.kyc_sanctions_snapshots
    ORDER BY coalesce(last_verified_at, retrieved_at) DESC, sha256 DESC LIMIT 1;
    IF NOT FOUND OR coalesce(snapshot.last_verified_at, snapshot.retrieved_at) < now() - interval '7 days' THEN
        RAISE EXCEPTION 'Import a current official sanctions snapshot before approving KYC' USING ERRCODE = '23514';
    END IF;
    fingerprint := coreaml_private.kyc_sanctions_run_key(customer);
    SELECT * INTO screened FROM coreaml_private.kyc_sanctions_runs r
    WHERE r.customer_id = customer.id AND r.tenant_id = staff.tenant_id
      AND r.snapshot_sha256 = snapshot.sha256 AND r.name_key = fingerprint;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Run the sanctions check for the current applicant name and snapshot before approving KYC' USING ERRCODE = '23514';
    END IF;
    IF jsonb_array_length(screened.hits) <> (
        SELECT count(*) FROM coreaml_private.kyc_sanctions_decisions d
        WHERE d.run_id = screened.id AND d.outcome = 'FALSE_POSITIVE'
    ) THEN
        RAISE EXCEPTION 'Review all possible sanctions matches before approving KYC' USING ERRCODE = '23514';
    END IF;
    NEW.sanctions_run_id := screened.id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS coreaml_require_kyc_sanctions ON public.kyc_reviews;
CREATE TRIGGER coreaml_require_kyc_sanctions BEFORE INSERT ON public.kyc_reviews
FOR EACH ROW EXECUTE FUNCTION coreaml_private.require_kyc_sanctions_evidence();

CREATE OR REPLACE FUNCTION public.coreaml_kyc_sanctions_referral_page(p_view text, p_offset integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    items jsonb;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    IF p_view IS NULL OR p_view NOT IN ('OPEN', 'HISTORY', 'ALL')
        OR p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 100000 THEN
        RAISE EXCEPTION 'Invalid referrals page' USING ERRCODE = '22023';
    END IF;
    SELECT coalesce(jsonb_agg(to_jsonb(rows) ORDER BY rows.corrected, rows.reviewed_at DESC, rows.run_id, rows.hit_index), '[]'::jsonb)
    INTO items
    FROM (
        SELECT c.id AS customer_id, r.id AS run_id, d.hit_index, d.reviewed_at, d.rationale,
            c.kyc_status,
            coalesce(nullif(btrim(c.company_name), ''), nullif(btrim(c.entity_name), ''),
                     nullif(btrim(concat_ws(' ', c.first_name, c.middle_name, c.last_name)), ''),
                     'Applicant') AS applicant_name,
            r.hits->d.hit_index AS hit,
            coalesce(x.state = 'APPROVED', false) AS corrected,
            CASE WHEN x.id IS NOT NULL THEN jsonb_build_object(
                'id', x.id, 'state', x.state, 'reason', x.reason, 'evidence_reference', x.evidence_reference,
                'proposed_at', x.proposed_at, 'decision_reason', x.decision_reason, 'decided_at', x.decided_at,
                'can_decide', x.state = 'PROPOSED' AND x.proposed_by <> staff.id
            ) END AS correction
        FROM coreaml_private.kyc_sanctions_decisions d
        JOIN coreaml_private.kyc_sanctions_runs r ON r.id = d.run_id
        JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
        LEFT JOIN LATERAL (
            SELECT * FROM coreaml_private.kyc_sanctions_corrections x
            WHERE x.run_id = d.run_id AND x.hit_index = d.hit_index
            ORDER BY x.proposed_at DESC, x.id DESC LIMIT 1
        ) x ON true
        WHERE d.outcome = 'CONFIRMED_MATCH' AND r.tenant_id = staff.tenant_id
          AND (
              (p_view IN ('OPEN', 'ALL') AND c.kyc_status = 'PENDING' AND x.state IS DISTINCT FROM 'APPROVED')
              OR (p_view IN ('HISTORY', 'ALL') AND x.state = 'APPROVED')
          )
        ORDER BY corrected, d.reviewed_at DESC, r.id, d.hit_index OFFSET p_offset LIMIT 26
    ) rows;
    RETURN items;
END
$$;

-- Keep existing local callers working while the UI uses the two paged views.
CREATE OR REPLACE FUNCTION public.coreaml_kyc_sanctions_referrals(p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT public.coreaml_kyc_sanctions_referral_page('ALL', p_offset)
$$;

REVOKE ALL ON FUNCTION public.coreaml_kyc_sanctions_referral_page(text, integer)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_kyc_sanctions_referral_page(text, integer) TO authenticated;

REVOKE ALL ON FUNCTION coreaml_private.kyc_sanctions_is_person(public.customers),
    coreaml_private.kyc_sanctions_customer_name(public.customers),
    coreaml_private.kyc_sanctions_has_hold(uuid, text),
    coreaml_private.kyc_sanctions_run_key(public.customers),
    coreaml_private.require_kyc_sanctions_evidence() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.coreaml_kyc_sanctions_referrals(integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_kyc_sanctions_referrals(integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_propose_sanctions_correction(
    p_request_id uuid, p_run_id uuid, p_hit_index integer, p_reason text, p_evidence_reference text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    saved coreaml_private.kyc_sanctions_corrections;
    application_status text;
    reason text := btrim(p_reason);
    evidence text := btrim(p_evidence_reference);
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    IF p_request_id IS NULL OR reason IS NULL OR length(reason) NOT BETWEEN 10 AND 1000
        OR evidence IS NULL OR length(evidence) NOT BETWEEN 5 AND 500 THEN
        RAISE EXCEPTION 'Enter a correction reason and supporting evidence reference' USING ERRCODE = '22023';
    END IF;

    -- Serialize proposals, decisions, and KYC approval on the applicant row.
    SELECT c.kyc_status INTO application_status
    FROM coreaml_private.kyc_sanctions_decisions d
    JOIN coreaml_private.kyc_sanctions_runs r ON r.id = d.run_id
    JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
    WHERE d.run_id = p_run_id AND d.hit_index = p_hit_index AND d.outcome = 'CONFIRMED_MATCH'
      AND r.tenant_id = staff.tenant_id
    FOR UPDATE OF c;
    IF NOT FOUND THEN RAISE EXCEPTION 'Confirmed referral unavailable in your bank' USING ERRCODE = '42501'; END IF;

    SELECT * INTO saved FROM coreaml_private.kyc_sanctions_corrections x WHERE x.id = p_request_id;
    IF FOUND THEN
        IF (saved.run_id, saved.hit_index, saved.reason, saved.evidence_reference, saved.proposed_by)
            IS DISTINCT FROM (p_run_id, p_hit_index, reason, evidence, staff.id) THEN
            RAISE EXCEPTION 'Correction request reference already used' USING ERRCODE = '23505';
        END IF;
        RETURN jsonb_build_object('id', saved.id, 'state', saved.state);
    END IF;
    IF application_status IS DISTINCT FROM 'PENDING' THEN
        RAISE EXCEPTION 'Only pending applications can receive a correction proposal' USING ERRCODE = '23514';
    END IF;

    INSERT INTO coreaml_private.kyc_sanctions_corrections(id, run_id, hit_index, reason, evidence_reference, proposed_by)
    VALUES (p_request_id, p_run_id, p_hit_index, reason, evidence, staff.id);
    RETURN jsonb_build_object('id', p_request_id, 'state', 'PROPOSED');
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_decide_sanctions_correction(
    p_correction_id uuid, p_decision text, p_reason text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    saved coreaml_private.kyc_sanctions_corrections;
    application_status text;
    review_reason text := btrim(p_reason);
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    IF p_decision IS NULL OR p_decision NOT IN ('APPROVED', 'REJECTED')
        OR review_reason IS NULL OR length(review_reason) NOT BETWEEN 10 AND 1000 THEN
        RAISE EXCEPTION 'Choose a decision and enter a review reason' USING ERRCODE = '22023';
    END IF;

    SELECT c.kyc_status INTO application_status
    FROM coreaml_private.kyc_sanctions_corrections x
    JOIN coreaml_private.kyc_sanctions_runs r ON r.id = x.run_id
    JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
    WHERE x.id = p_correction_id AND r.tenant_id = staff.tenant_id
    FOR UPDATE OF c;
    IF NOT FOUND THEN RAISE EXCEPTION 'Correction unavailable in your bank' USING ERRCODE = '42501'; END IF;
    SELECT * INTO STRICT saved FROM coreaml_private.kyc_sanctions_corrections x WHERE x.id = p_correction_id;
    IF saved.proposed_by = staff.id THEN
        RAISE EXCEPTION 'A different Head of Compliance must review this correction' USING ERRCODE = '42501';
    END IF;
    IF saved.state <> 'PROPOSED' THEN
        IF (saved.state, saved.decided_by, saved.decision_reason) IS DISTINCT FROM (p_decision, staff.id, review_reason) THEN
            RAISE EXCEPTION 'This correction already has a recorded decision' USING ERRCODE = '23505';
        END IF;
        RETURN jsonb_build_object('id', saved.id, 'state', saved.state);
    END IF;
    IF application_status IS DISTINCT FROM 'PENDING' THEN
        RAISE EXCEPTION 'Only pending applications can receive a correction decision' USING ERRCODE = '23514';
    END IF;

    UPDATE coreaml_private.kyc_sanctions_corrections
    SET state = p_decision, decided_by = staff.id, decided_at = now(), decision_reason = review_reason
    WHERE id = saved.id;
    RETURN jsonb_build_object('id', saved.id, 'state', p_decision);
END
$$;

REVOKE ALL ON FUNCTION public.coreaml_kyc_propose_sanctions_correction(uuid, uuid, integer, text, text),
    public.coreaml_kyc_decide_sanctions_correction(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_kyc_propose_sanctions_correction(uuid, uuid, integer, text, text),
    public.coreaml_kyc_decide_sanctions_correction(uuid, text, text) TO authenticated;
NOTIFY pgrst, 'reload schema';
