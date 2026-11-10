-- Require screening evidence on new hosted KYC approvals. Prior approvals remain reviewable.
SET LOCAL lock_timeout = '5s';

ALTER TABLE public.kyc_reviews ADD COLUMN IF NOT EXISTS sanctions_run_id uuid
    REFERENCES coreaml_private.kyc_sanctions_runs(id);

CREATE OR REPLACE FUNCTION coreaml_private.require_hosted_kyc_sanctions_evidence()
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
        RAISE EXCEPTION 'A current official sanctions snapshot is required before approving KYC' USING ERRCODE = '23514';
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

DROP TRIGGER IF EXISTS coreaml_require_hosted_kyc_sanctions ON public.kyc_reviews;
CREATE TRIGGER coreaml_require_hosted_kyc_sanctions BEFORE INSERT ON public.kyc_reviews
FOR EACH ROW EXECUTE FUNCTION coreaml_private.require_hosted_kyc_sanctions_evidence();

REVOKE ALL ON FUNCTION coreaml_private.require_hosted_kyc_sanctions_evidence()
    FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION coreaml_private.kyc_sanctions_hosted_receipt(p_run_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT jsonb_build_object(
        'mode', 'HOSTED_AUDIT', 'run_id', r.id, 'customer_id', r.customer_id,
        'screened_at', r.screened_at, 'screened_by', r.screened_by,
        'snapshot_sha256', s.sha256, 'retrieved_at', s.retrieved_at,
        'last_verified_at', coalesce(s.last_verified_at, s.retrieved_at), 'hits', r.hits,
        'confirmed_hold', coreaml_private.kyc_sanctions_has_hold(r.customer_id, r.tenant_id),
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

CREATE OR REPLACE FUNCTION public.coreaml_kyc_hosted_confirmed_referrals(p_offset integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    referrals jsonb;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    IF p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 100000 THEN
        RAISE EXCEPTION 'Invalid referral offset' USING ERRCODE = '22023';
    END IF;

    SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.reviewed_at DESC, x.run_id, x.hit_index), '[]'::jsonb)
    INTO referrals
    FROM (
        SELECT r.id AS run_id, d.hit_index, r.customer_id,
            coalesce(nullif(btrim(c.company_name), ''), nullif(btrim(c.entity_name), ''),
                nullif(btrim(concat_ws(' ', c.first_name, c.middle_name, c.last_name)), ''), 'Applicant') AS applicant_name,
            c.kyc_status, EXISTS (
                SELECT 1 FROM public.accounts a WHERE a.customer_id = c.id AND a.status::text = 'ACTIVE'
            ) AS has_active_account,
            d.reviewed_at, d.rationale, r.hits->d.hit_index AS hit
        FROM coreaml_private.kyc_sanctions_runs r
        JOIN coreaml_private.kyc_sanctions_decisions d ON d.run_id = r.id
        JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
        WHERE r.tenant_id = staff.tenant_id AND d.outcome = 'CONFIRMED_MATCH'
          AND NOT EXISTS (
              SELECT 1 FROM coreaml_private.kyc_sanctions_corrections k
              WHERE k.run_id = r.id AND k.hit_index = d.hit_index AND k.state = 'APPROVED'
          )
        ORDER BY d.reviewed_at DESC, r.id, d.hit_index OFFSET p_offset LIMIT 26
    ) x;
    RETURN referrals;
END
$$;

REVOKE ALL ON FUNCTION public.coreaml_kyc_hosted_confirmed_referrals(integer)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_kyc_hosted_confirmed_referrals(integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
