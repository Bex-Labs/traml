-- Preserve confirmed matches and record corrections through independent same-bank review.
CREATE OR REPLACE FUNCTION public.coreaml_kyc_hosted_referral_page(p_view text, p_offset integer)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    referrals jsonb;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    IF p_view IS NULL OR p_view NOT IN ('OPEN', 'HISTORY') OR p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 100000 THEN
        RAISE EXCEPTION 'Invalid referral page' USING ERRCODE = '22023';
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
            d.reviewed_at, d.rationale, r.hits->d.hit_index AS hit,
            coalesce(k.state = 'APPROVED', false) AS corrected,
            CASE WHEN k.id IS NOT NULL THEN jsonb_build_object(
                'id', k.id, 'state', k.state, 'reason', k.reason, 'evidence_reference', k.evidence_reference,
                'proposed_by', k.proposed_by, 'proposed_at', k.proposed_at, 'decided_by', k.decided_by,
                'decision_reason', k.decision_reason, 'decided_at', k.decided_at,
                'can_decide', k.state = 'PROPOSED' AND k.proposed_by <> staff.id
            ) END AS correction
        FROM coreaml_private.kyc_sanctions_runs r
        JOIN coreaml_private.kyc_sanctions_decisions d ON d.run_id = r.id
        JOIN public.customers c ON c.id = r.customer_id AND c.tenant_id = r.tenant_id
        LEFT JOIN LATERAL (
            SELECT x.* FROM coreaml_private.kyc_sanctions_corrections x
            WHERE x.run_id = d.run_id AND x.hit_index = d.hit_index
            ORDER BY (x.state IN ('APPROVED','PROPOSED')) DESC, x.proposed_at DESC, x.id DESC LIMIT 1
        ) k ON true
        WHERE r.tenant_id = staff.tenant_id AND d.outcome = 'CONFIRMED_MATCH'
          AND ((p_view = 'OPEN' AND k.state IS DISTINCT FROM 'APPROVED')
            OR (p_view = 'HISTORY' AND k.state = 'APPROVED'))
        ORDER BY d.reviewed_at DESC, r.id, d.hit_index OFFSET p_offset LIMIT 26
    ) x;
    RETURN referrals;
END
$$;

REVOKE ALL ON FUNCTION public.coreaml_kyc_hosted_referral_page(text, integer)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_kyc_hosted_referral_page(text, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_hosted_confirmed_referrals(p_offset integer)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
    SELECT public.coreaml_kyc_hosted_referral_page('OPEN', p_offset)
$$;

CREATE OR REPLACE FUNCTION public.coreaml_kyc_propose_sanctions_correction(
    p_request_id uuid, p_run_id uuid, p_hit_index integer, p_reason text, p_evidence_reference text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    saved coreaml_private.kyc_sanctions_corrections;
    application_status text;
    has_active_account boolean;
    reason text := btrim(p_reason);
    evidence text := btrim(p_evidence_reference);
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    IF p_request_id IS NULL OR reason IS NULL OR length(reason) NOT BETWEEN 10 AND 1000
        OR evidence IS NULL OR length(evidence) NOT BETWEEN 5 AND 500 THEN
        RAISE EXCEPTION 'Enter a correction reason and supporting evidence reference' USING ERRCODE = '22023';
    END IF;

    -- Serialize proposals, decisions, and KYC approval on the applicant row.
    SELECT c.kyc_status, EXISTS (
        SELECT 1 FROM public.accounts a WHERE a.customer_id = c.id AND a.status::text = 'ACTIVE'
    ) INTO application_status, has_active_account
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
    IF application_status IS NULL OR application_status NOT IN ('PENDING', 'PENDING_EDD') OR has_active_account THEN
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
    has_active_account boolean;
    review_reason text := btrim(p_reason);
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['head_of_compliance']);
    IF p_decision IS NULL OR p_decision NOT IN ('APPROVED', 'REJECTED')
        OR review_reason IS NULL OR length(review_reason) NOT BETWEEN 10 AND 1000 THEN
        RAISE EXCEPTION 'Choose a decision and enter a review reason' USING ERRCODE = '22023';
    END IF;

    SELECT c.kyc_status, EXISTS (
        SELECT 1 FROM public.accounts a WHERE a.customer_id = c.id AND a.status::text = 'ACTIVE'
    ) INTO application_status, has_active_account
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
    IF application_status IS NULL OR application_status NOT IN ('PENDING', 'PENDING_EDD') OR has_active_account THEN
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
