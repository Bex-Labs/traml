CREATE TABLE coreaml_private.pep_state_house_refresh_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at timestamptz NOT NULL,
    finished_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    status text NOT NULL CHECK (status IN ('SUCCEEDED','FAILED')),
    record_count integer,
    unnamed_cabinet_slots integer,
    source_sha256 text,
    failure_code text
);
ALTER TABLE coreaml_private.pep_state_house_refresh_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_state_house_refresh_runs FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION coreaml_private.pep_state_house_text(p_html text)
RETURNS text LANGUAGE plpgsql IMMUTABLE STRICT SET search_path='' AS $$
DECLARE value text;
BEGIN
    value := regexp_replace(p_html,'<br[[:space:]]*/?>',' ','gi');
    value := regexp_replace(value,'<[^>]+>','','g');
    value := replace(replace(replace(replace(replace(replace(replace(replace(value,
        '&nbsp;',' '),chr(160),' '),'&#160;',' '),'&#8217;',chr(8217)),
        '&#8211;',chr(8211)),'&#038;','&'),'&amp;','&'),'&#39;',chr(39));
    IF value ~ '&(#?[[:alnum:]]+);' THEN
        RAISE EXCEPTION 'Unexpected HTML entity in State House record' USING ERRCODE='22023';
    END IF;
    RETURN btrim(regexp_replace(value,'[[:space:]]+',' ','g'));
END
$$;

CREATE FUNCTION coreaml_private.pep_state_house_row(p_page text,p_name text,p_role text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE STRICT SET search_path='' AS $$
DECLARE name text; reference text; bytes bytea; code integer; idx integer;
BEGIN
    name := regexp_replace(p_name,'^(?:(?:Rt\.|Hon\.|Dr\.|Sen\.|Gen\.|Engr\.|Prof\.|Amb\.|Barr\.|Mr\.|Mrs\.|Chief)[[:space:]]+)+','','i');
    name := btrim(regexp_replace(name,'[[:space:]]*(?:\((?:GCFR|GCON|rtd)\)|\mPhD)[[:space:]]*$','','i'));
    bytes := convert_to(p_name,'UTF8');
    reference := 'https://statehouse.gov.ng/'||p_page||'/#:~:text=';
    FOR idx IN 0..length(bytes)-1 LOOP
        code := get_byte(bytes,idx);
        reference := reference || CASE
            WHEN code BETWEEN 48 AND 57 OR code BETWEEN 65 AND 90 OR code BETWEEN 97 AND 122
                 OR code IN (46,95,126) THEN chr(code)
            ELSE '%'||upper(lpad(to_hex(code),2,'0')) END;
    END LOOP;
    IF length(name) NOT BETWEEN 1 AND 200 OR length(p_role) NOT BETWEEN 1 AND 200
       OR length(reference)>500 THEN
        RAISE EXCEPTION 'Invalid State House roster record' USING ERRCODE='22023';
    END IF;
    RETURN jsonb_build_object('source_reference',reference,'full_name',name,'public_role',p_role);
END
$$;

CREATE FUNCTION coreaml_private.publish_pep_state_house_roster(p_cabinet text,p_leadership text)
RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE
    roster_source CONSTANT text := 'Nigeria State House federal executive roster';
    checked timestamptz := clock_timestamp();
    cabinet text; candidate text; row_html text; cells text[]; slot integer := 0;
    unnamed integer := 0; roster_tables integer := 0; previous_count integer;
    role text; names text[]; entries jsonb := '[]'; total integer; changed integer;
BEGIN
    IF p_cabinet IS NULL OR p_leadership IS NULL OR
       greatest(octet_length(p_cabinet),octet_length(p_leadership)) > 1048576 THEN
        RAISE EXCEPTION 'Invalid State House response size' USING ERRCODE='22023';
    END IF;
    FOR candidate IN SELECT m[1] FROM regexp_matches(p_cabinet,'(?is)<table\y[^>]*?>(.*?)</table>','g') m LOOP
        SELECT array_agg(coreaml_private.pep_state_house_text(m[1]) ORDER BY ord)
        INTO cells FROM regexp_matches(candidate,'(?is)<th\y[^>]*?>(.*?)</th>','g') WITH ORDINALITY AS x(m,ord);
        IF cells=ARRAY['S/N','Ministry','Portfolio','Name'] THEN
            roster_tables := roster_tables+1;
            cabinet := candidate;
        END IF;
    END LOOP;
    IF roster_tables<>1 THEN
        RAISE EXCEPTION 'Expected one State House cabinet table' USING ERRCODE='22023';
    END IF;
    FOR row_html IN SELECT m[1] FROM regexp_matches(cabinet,'(?is)<tr\y[^>]*?>(.*?)</tr>','g') m LOOP
        IF slot=0 AND row_html ~* '<th\y' THEN CONTINUE; END IF;
        slot := slot+1;
        SELECT array_agg(coreaml_private.pep_state_house_text(m[1]) ORDER BY ord)
        INTO cells FROM regexp_matches(row_html,'(?is)<td\y[^>]*?>(.*?)</td>','g') WITH ORDINALITY AS x(m,ord);
        IF cardinality(cells) IS DISTINCT FROM 4 OR cells[1]<>slot::text OR cells[2]='' OR cells[3]='' THEN
            RAISE EXCEPTION 'Invalid State House cabinet row' USING ERRCODE='22023';
        END IF;
        IF cells[4]='' THEN
            unnamed := unnamed+1;
        ELSE
            entries := entries || coreaml_private.pep_state_house_row('the-cabinet',cells[4],cells[3]||' · '||cells[2]);
        END IF;
    END LOOP;
    IF slot-unnamed NOT BETWEEN 1 AND 150 THEN
        RAISE EXCEPTION 'Invalid State House cabinet count' USING ERRCODE='22023';
    END IF;
    FOREACH role IN ARRAY ARRAY['President','Vice President'] LOOP
        WITH headings AS (
            SELECT lower(m[1]) tag,coreaml_private.pep_state_house_text(m[2]) value,ord
            FROM regexp_matches(p_leadership,'(?is)<(h[34])\y[^>]*?>(.*?)</h[34]>','g') WITH ORDINALITY AS x(m,ord)
        )
        SELECT array_agg(a.value) INTO names
        FROM headings a JOIN headings b ON b.ord=a.ord+1
        WHERE a.tag='h3' AND b.tag='h4' AND b.value=role||', Federal Republic of Nigeria';
        IF cardinality(names) IS DISTINCT FROM 1 THEN
            RAISE EXCEPTION 'Expected one State House leadership profile' USING ERRCODE='22023';
        END IF;
        entries := entries || coreaml_private.pep_state_house_row('people',names[1],role);
    END LOOP;
    total := jsonb_array_length(entries);
    IF (SELECT count(DISTINCT row->>'source_reference') FROM jsonb_array_elements(entries) AS e(row))<>total THEN
        RAISE EXCEPTION 'Duplicate State House source reference' USING ERRCODE='22023';
    END IF;
    LOCK TABLE coreaml_private.pep_officeholder_records IN SHARE ROW EXCLUSIVE MODE;
    SELECT record_count INTO previous_count FROM coreaml_private.pep_state_house_refresh_runs
    WHERE status='SUCCEEDED' ORDER BY finished_at DESC LIMIT 1;
    IF previous_count IS NULL THEN
        SELECT count(*) INTO previous_count FROM coreaml_private.pep_officeholder_records
        WHERE source_name=roster_source AND valid_until>checked;
    END IF;
    IF previous_count > 0 AND total * 10 < previous_count * 9 THEN
        RAISE EXCEPTION 'State House roster count fell by more than ten percent' USING ERRCODE='22023';
    END IF;
    INSERT INTO coreaml_private.pep_officeholder_records AS r
        (source_reference,full_name,public_role,jurisdiction,source_name,checked_at,valid_until)
    SELECT source_reference,full_name,public_role,'Nigeria',roster_source,checked,checked+interval '7 days'
    FROM jsonb_to_recordset(entries) AS e(source_reference text,full_name text,public_role text)
    ON CONFLICT (source_reference) DO UPDATE SET
        full_name=excluded.full_name,public_role=excluded.public_role,
        jurisdiction=excluded.jurisdiction,checked_at=excluded.checked_at,valid_until=excluded.valid_until
    WHERE r.source_name=roster_source;
    GET DIAGNOSTICS changed=ROW_COUNT;
    IF changed<>total THEN RAISE EXCEPTION 'State House reference belongs to another source' USING ERRCODE='22023'; END IF;
    -- Retain omitted records as history, without offering them for new screening.
    UPDATE coreaml_private.pep_officeholder_records r
    SET valid_until=checked
    WHERE r.source_name=roster_source AND r.valid_until>checked AND r.checked_at<checked
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(entries) AS e(row) WHERE row->>'source_reference'=r.source_reference);
    RETURN jsonb_build_object('record_count',total,'unnamed_cabinet_slots',unnamed);
END
$$;

CREATE FUNCTION coreaml_private.refresh_pep_state_house_roster()
RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE
    started timestamptz := clock_timestamp();
    cabinet text; leadership text; response_status integer; receipt jsonb;
    failure text := 'CABINET_FETCH_FAILED';
BEGIN
    IF NOT pg_try_advisory_xact_lock(174021322,213662033) THEN
        RETURN jsonb_build_object('status','ALREADY_RUNNING');
    END IF;
    BEGIN
        PERFORM set_config('http.curlopt_timeout_ms','15000',true);
        PERFORM set_config('http.curlopt_followlocation','0',true);
        SELECT status,content INTO response_status,cabinet
        FROM coreaml_refresh_transport.http_get('https://statehouse.gov.ng/the-cabinet/');
        IF response_status IS DISTINCT FROM 200 THEN RAISE EXCEPTION 'Cabinet fetch failed'; END IF;
        failure := 'LEADERSHIP_FETCH_FAILED';
        SELECT status,content INTO response_status,leadership
        FROM coreaml_refresh_transport.http_get('https://statehouse.gov.ng/people/');
        IF response_status IS DISTINCT FROM 200 THEN RAISE EXCEPTION 'Leadership fetch failed'; END IF;
        failure := 'VALIDATION_OR_PUBLISH_FAILED';
        receipt := coreaml_private.publish_pep_state_house_roster(cabinet,leadership);
        INSERT INTO coreaml_private.pep_state_house_refresh_runs
            (started_at,status,record_count,unnamed_cabinet_slots,source_sha256)
        VALUES (started,'SUCCEEDED',(receipt->>'record_count')::integer,(receipt->>'unnamed_cabinet_slots')::integer,
                encode(sha256(convert_to(jsonb_build_array(cabinet,leadership)::text,'UTF8')),'hex'));
        RETURN receipt||jsonb_build_object('status','SUCCEEDED');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO coreaml_private.pep_state_house_refresh_runs(started_at,status,failure_code)
        VALUES (started,'FAILED',failure);
        RETURN jsonb_build_object('status','FAILED','failure_code',failure);
    END;
END
$$;

REVOKE ALL ON FUNCTION coreaml_private.pep_state_house_text(text),
    coreaml_private.pep_state_house_row(text,text,text),
    coreaml_private.publish_pep_state_house_roster(text,text),
    coreaml_private.refresh_pep_state_house_roster()
    FROM PUBLIC, anon, authenticated, service_role;
