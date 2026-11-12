CREATE TABLE coreaml_private.pep_senate_refresh_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    status text NOT NULL CHECK (status IN ('SUCCEEDED','FAILED')),
    record_count integer,
    source_sha256 text,
    failure_code text
);
ALTER TABLE coreaml_private.pep_senate_refresh_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_senate_refresh_runs FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION coreaml_private.publish_pep_senate_roster(p_payload jsonb)
RETURNS integer LANGUAGE plpgsql SET search_path='' AS $$
DECLARE
    total integer;
    prior_count integer;
    changed integer;
    entries jsonb;
    roster_source CONSTANT text := 'Nigeria National Assembly Senate roster';
    checked timestamptz := clock_timestamp();
BEGIN
    IF jsonb_typeof(p_payload->'recordsTotal') IS DISTINCT FROM 'number'
       OR p_payload->>'recordsTotal' !~ '^[0-9]{1,3}$'
       OR p_payload->>'draw' IS DISTINCT FROM '1'
       OR p_payload->'recordsFiltered' IS DISTINCT FROM p_payload->'recordsTotal'
       OR jsonb_typeof(p_payload->'data') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Unexpected roster response' USING ERRCODE='22023';
    END IF;
    total := (p_payload->>'recordsTotal')::integer;
    IF total NOT BETWEEN 1 AND 109 OR jsonb_array_length(p_payload->'data') <> total THEN
        RAISE EXCEPTION 'Incomplete roster response' USING ERRCODE='22023';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload->'data') AS items(row)
               WHERE jsonb_typeof(row) <> 'array') THEN
        RAISE EXCEPTION 'Invalid roster row' USING ERRCODE='22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_payload->'data') AS items(row)
        WHERE jsonb_array_length(row) <> 5
           OR jsonb_typeof(row->0) IS DISTINCT FROM 'string'
           OR jsonb_typeof(row->1) IS DISTINCT FROM 'string'
           OR jsonb_typeof(row->2) IS DISTINCT FROM 'string'
           OR jsonb_typeof(row->4) IS DISTINCT FROM 'string'
           OR coalesce(row->>4,'') !~ '^[1-9][0-9]{0,11}$'
           OR length(btrim(row->>0)) NOT BETWEEN 1 AND 200
           OR length(btrim(row->>1)) NOT BETWEEN 1 AND 90
           OR length(btrim(row->>2)) NOT BETWEEN 1 AND 90
           OR concat(row->>0,row->>1,row->>2) ~ '[<>[:cntrl:]]'
    ) OR (SELECT count(DISTINCT row->>4) FROM jsonb_array_elements(p_payload->'data') AS items(row)) <> total THEN
        RAISE EXCEPTION 'Invalid or duplicate roster record' USING ERRCODE='22023';
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'source_reference','https://www.nass.gov.ng/mps/single/'||(row->>4),
        'full_name',regexp_replace(btrim(row->>0),'[[:space:]]+',' ','g'),
        'public_role',format('Senator · %s (%s)',btrim(row->>2),btrim(row->>1))
    )) INTO entries FROM jsonb_array_elements(p_payload->'data') AS items(row);
    LOCK TABLE coreaml_private.pep_officeholder_records IN SHARE ROW EXCLUSIVE MODE;
    SELECT count(*) INTO prior_count FROM coreaml_private.pep_officeholder_records WHERE source_name=roster_source;
    IF prior_count > 0 AND total * 10 < prior_count * 9 THEN
        RAISE EXCEPTION 'Roster count fell by more than ten percent' USING ERRCODE='22023';
    END IF;
    INSERT INTO coreaml_private.pep_officeholder_records AS r
        (source_reference,full_name,public_role,jurisdiction,source_name,checked_at,valid_until)
    SELECT source_reference,full_name,public_role,'Nigeria',roster_source,checked,checked+interval '7 days'
    FROM jsonb_to_recordset(entries) AS e(source_reference text, full_name text, public_role text)
    ON CONFLICT (source_reference) DO UPDATE SET
        full_name=excluded.full_name, public_role=excluded.public_role,
        jurisdiction=excluded.jurisdiction, checked_at=excluded.checked_at, valid_until=excluded.valid_until
    WHERE r.source_name=roster_source;
    GET DIAGNOSTICS changed=ROW_COUNT;
    IF changed <> total THEN RAISE EXCEPTION 'Roster reference belongs to another source' USING ERRCODE='22023'; END IF;
    DELETE FROM coreaml_private.pep_officeholder_records r WHERE r.source_name=roster_source
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(entries) AS e(row) WHERE row->>'source_reference'=r.source_reference);
    RETURN total;
END
$$;

CREATE FUNCTION coreaml_private.refresh_pep_senate_roster()
RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE
    started timestamptz := clock_timestamp();
    response_status integer;
    response_body text;
    published integer;
    failure text := 'FETCH_FAILED';
BEGIN
    IF NOT pg_try_advisory_xact_lock(174021322, 213662032) THEN
        RETURN jsonb_build_object('status','ALREADY_RUNNING');
    END IF;
    BEGIN
        PERFORM set_config('http.curlopt_timeout_ms','25000',true);
        PERFORM set_config('http.curlopt_followlocation','0',true);
        SELECT r.status,r.content INTO response_status,response_body
        FROM coreaml_refresh_transport.http_get(
            'https://www.nass.gov.ng/mps/get_legislators/?chamber=1&draw=1&start=0&length=109'
        ) r;
        IF response_status IS DISTINCT FROM 200 OR response_body IS NULL
           OR octet_length(response_body) > 524288 THEN
            RAISE EXCEPTION 'Unexpected roster HTTP response';
        END IF;
        failure := 'VALIDATION_OR_PUBLISH_FAILED';
        published := coreaml_private.publish_pep_senate_roster(response_body::jsonb);
        INSERT INTO coreaml_private.pep_senate_refresh_runs(started_at,status,record_count,source_sha256)
        VALUES (started,'SUCCEEDED',published,encode(sha256(convert_to(response_body,'UTF8')),'hex'));
        RETURN jsonb_build_object('status','SUCCEEDED','record_count',published);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO coreaml_private.pep_senate_refresh_runs(started_at,status,failure_code)
        VALUES (started,'FAILED',failure);
        RETURN jsonb_build_object('status','FAILED','failure_code',failure);
    END;
END
$$;

REVOKE ALL ON FUNCTION coreaml_private.publish_pep_senate_roster(jsonb),
    coreaml_private.refresh_pep_senate_roster() FROM PUBLIC, anon, authenticated, service_role;
