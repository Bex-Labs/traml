-- Read-only screening against the current hosted snapshot for a bank's pending applicant.
CREATE OR REPLACE FUNCTION public.coreaml_kyc_preview_sanctions(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    staff public.user_profiles;
    customer public.customers;
    snapshot coreaml_private.kyc_sanctions_snapshots;
    person boolean;
    name text;
    token_key text;
    found_hits jsonb;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer', 'head_of_compliance']);
    SELECT * INTO customer
    FROM public.customers c
    WHERE c.id = p_customer_id AND c.tenant_id = staff.tenant_id
      AND c.kyc_status IN ('PENDING', 'PENDING_EDD');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pending application unavailable in your bank' USING ERRCODE = '42501';
    END IF;

    person := coreaml_private.kyc_sanctions_is_person(customer);
    name := coreaml_private.kyc_sanctions_customer_name(customer);
    IF person IS NULL OR coalesce(name, '') = '' THEN
        RAISE EXCEPTION 'Application has no recorded name and customer type to screen' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO snapshot FROM coreaml_private.kyc_sanctions_snapshots
    ORDER BY coalesce(last_verified_at, retrieved_at) DESC, sha256 DESC LIMIT 1;
    IF NOT FOUND OR coalesce(snapshot.last_verified_at, snapshot.retrieved_at) < now() - interval '7 days' THEN
        RAISE EXCEPTION 'A current official sanctions snapshot is unavailable' USING ERRCODE = '22023';
    END IF;

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
        RAISE EXCEPTION 'Too many candidate matches for this check. Review the source lists manually.' USING ERRCODE = '22023';
    END IF;

    RETURN jsonb_build_object(
        'mode', 'HOSTED_PREVIEW', 'customer_id', customer.id, 'hits', found_hits,
        'last_verified_at', coalesce(snapshot.last_verified_at, snapshot.retrieved_at),
        'snapshot_sha256', snapshot.sha256
    );
END
$$;

REVOKE ALL ON FUNCTION public.coreaml_kyc_preview_sanctions(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_kyc_preview_sanctions(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
