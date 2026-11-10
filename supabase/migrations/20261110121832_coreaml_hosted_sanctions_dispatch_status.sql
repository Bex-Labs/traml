CREATE OR REPLACE PROCEDURE coreaml_private.dispatch_kyc_sanctions_hosted_refresh(p_project_url text)
LANGUAGE plpgsql AS $$
DECLARE
    dispatch_token text := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
    attempt_id uuid;
    dispatch_http_status integer;
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
        SELECT result.status INTO dispatch_http_status
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
        dispatch_http_status := NULL;
    END;

    UPDATE coreaml_private.kyc_sanctions_refresh_attempts a
    SET http_status = dispatch_http_status,
        state = CASE WHEN a.state IN ('QUEUED', 'RUNNING') THEN 'FAILED' ELSE a.state END,
        finished_at = coalesce(a.finished_at, clock_timestamp()),
        failure = CASE WHEN a.state IN ('QUEUED', 'RUNNING') THEN 'DISPATCH' ELSE a.failure END,
        token_hash = NULL
    WHERE a.id = attempt_id;
END
$$;

