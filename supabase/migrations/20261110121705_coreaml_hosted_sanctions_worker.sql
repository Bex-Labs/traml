-- Hosted refresh transport. Scheduling is configured per environment after the first run.
-- Keep the HTTP client in an owner-only schema. Synchronous dispatch avoids
-- putting the one-use capability in the shared pg_net queue.
CREATE SCHEMA IF NOT EXISTS coreaml_refresh_transport;
REVOKE ALL ON SCHEMA coreaml_refresh_transport FROM PUBLIC, anon, authenticated, service_role;
CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA coreaml_refresh_transport;

CREATE TABLE IF NOT EXISTS coreaml_private.kyc_sanctions_refresh_attempts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    state text NOT NULL DEFAULT 'QUEUED' CHECK (state IN ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED')),
    queued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at timestamptz,
    finished_at timestamptz,
    http_status integer,
    token_hash bytea,
    failure text,
    receipt jsonb
);
ALTER TABLE coreaml_private.kyc_sanctions_refresh_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE coreaml_private.kyc_sanctions_refresh_attempts FROM PUBLIC, anon, authenticated, service_role;

-- Call at the top level through pg_cron. The claim must see the committed attempt
-- before the Edge Function can finish the HTTP request.
CREATE OR REPLACE PROCEDURE coreaml_private.dispatch_kyc_sanctions_hosted_refresh(p_project_url text)
LANGUAGE plpgsql AS $$
DECLARE
    dispatch_token text := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
    attempt_id uuid;
    http_status integer;
BEGIN
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog', true);
    IF p_project_url IS NULL OR p_project_url !~ '^https://[a-z0-9]{20}\.supabase\.co$' THEN
        RAISE EXCEPTION 'Invalid hosted refresh project URL' USING ERRCODE = '22023';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(193762332, 3518224);
    UPDATE coreaml_private.kyc_sanctions_refresh_attempts
    SET state = 'FAILED', failure = 'ATTEMPT_EXPIRED', finished_at = clock_timestamp(), token_hash = NULL
    WHERE state IN ('QUEUED', 'RUNNING') AND queued_at < clock_timestamp() - interval '5 minutes';
    IF EXISTS (SELECT 1 FROM coreaml_private.kyc_sanctions_refresh_attempts WHERE state IN ('QUEUED', 'RUNNING')) THEN
        RETURN;
    END IF;

    INSERT INTO coreaml_private.kyc_sanctions_refresh_attempts (token_hash)
    VALUES (sha256(convert_to(dispatch_token, 'UTF8'))) RETURNING id INTO attempt_id;
    COMMIT;

    PERFORM pg_catalog.set_config('search_path', 'pg_catalog', true);
    BEGIN
        PERFORM pg_catalog.set_config('http.curlopt_timeout_ms', '90000', true);
        SELECT result.status INTO http_status
        FROM coreaml_refresh_transport.http(ROW(
            'POST',
            p_project_url || '/functions/v1/coreaml-sanctions-refresh',
            ARRAY[
                coreaml_refresh_transport.http_header('X-CoreAML-Dispatch', dispatch_token),
                coreaml_refresh_transport.http_header('X-CoreAML-Attempt', attempt_id::text)
            ],
            'application/json',
            '{}'
        )::coreaml_refresh_transport.http_request) AS result;
    EXCEPTION WHEN OTHERS THEN
        http_status := NULL;
    END;

    UPDATE coreaml_private.kyc_sanctions_refresh_attempts a
    SET http_status = dispatch_kyc_sanctions_hosted_refresh.http_status,
        state = CASE WHEN a.state IN ('QUEUED', 'RUNNING') THEN 'FAILED' ELSE a.state END,
        finished_at = coalesce(a.finished_at, clock_timestamp()),
        failure = CASE WHEN a.state IN ('QUEUED', 'RUNNING') THEN 'DISPATCH' ELSE a.failure END,
        token_hash = NULL
    WHERE a.id = attempt_id;
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_claim_sanctions_refresh(p_id uuid, p_token text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF p_token IS NULL OR p_token !~ '^[a-f0-9]{64}$' THEN RETURN false; END IF;
    UPDATE coreaml_private.kyc_sanctions_refresh_attempts
    SET state = 'RUNNING', token_hash = NULL, started_at = clock_timestamp()
    WHERE id = p_id AND state = 'QUEUED' AND queued_at >= clock_timestamp() - interval '90 seconds'
      AND token_hash = sha256(convert_to(p_token, 'UTF8'));
    RETURN FOUND;
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_finish_sanctions_refresh(
    p_id uuid, p_sha256 text DEFAULT NULL, p_retrieved_at timestamptz DEFAULT NULL,
    p_entries jsonb DEFAULT NULL, p_files jsonb DEFAULT NULL, p_failure text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
    outcome jsonb;
BEGIN
    PERFORM 1 FROM coreaml_private.kyc_sanctions_refresh_attempts
    WHERE id = p_id AND state = 'RUNNING' AND started_at > clock_timestamp() - interval '4 minutes'
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hosted refresh attempt is not active' USING ERRCODE = '22023';
    END IF;

    IF p_failure IS NOT NULL THEN
        IF p_failure NOT IN ('UN_FEED', 'OFAC_SDN_FEED', 'OFAC_NON_SDN_FEED', 'NIGERIA_FEED', 'SNAPSHOT_VALIDATION', 'PUBLICATION') THEN
            RAISE EXCEPTION 'Invalid refresh failure code' USING ERRCODE = '22023';
        END IF;
        UPDATE coreaml_private.kyc_sanctions_refresh_attempts
        SET state = 'FAILED', finished_at = clock_timestamp(), failure = p_failure WHERE id = p_id;
        RETURN jsonb_build_object('status', 'FAILED', 'failure', p_failure);
    END IF;

    outcome := coreaml_private.publish_kyc_sanctions_hosted_snapshot(p_sha256, p_retrieved_at, p_entries, p_files);
    UPDATE coreaml_private.kyc_sanctions_refresh_attempts
    SET state = 'SUCCEEDED', finished_at = clock_timestamp(), receipt = outcome WHERE id = p_id;
    RETURN outcome;
END
$$;

REVOKE ALL ON PROCEDURE coreaml_private.dispatch_kyc_sanctions_hosted_refresh(text)
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.coreaml_claim_sanctions_refresh(uuid, text),
    public.coreaml_finish_sanctions_refresh(uuid, text, timestamptz, jsonb, jsonb, text)
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_claim_sanctions_refresh(uuid, text),
    public.coreaml_finish_sanctions_refresh(uuid, text, timestamptz, jsonb, jsonb, text) TO service_role;

NOTIFY pgrst, 'reload schema';
