CREATE TABLE coreaml_private.pep_governors_refresh_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at timestamptz NOT NULL,
    finished_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    status text NOT NULL CHECK (status IN ('SUCCEEDED','FAILED')),
    record_count integer,
    source_sha256 text,
    failure_code text
);
ALTER TABLE coreaml_private.pep_governors_refresh_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_governors_refresh_runs FROM PUBLIC, anon, authenticated, service_role;


CREATE FUNCTION coreaml_private.publish_pep_governors_roster(p_html text)
RETURNS integer LANGUAGE plpgsql SET search_path='' AS $$
DECLARE
    roster_source CONSTANT text := 'Nigeria Governors’ Forum national directory';
    checked timestamptz := clock_timestamp();
    expected CONSTANT text[] := ARRAY['Abia','Adamawa','Akwa Ibom','Anambra','Bauchi','Bayelsa',
        'Benue','Borno','Cross River','Delta','Ebonyi','Edo','Ekiti','Enugu','Gombe','Imo','Jigawa',
        'Kaduna','Kano','Katsina','Kebbi','Kogi','Kwara','Lagos','Nasarawa','Niger','Ogun','Ondo',
        'Osun','Oyo','Plateau','Rivers','Sokoto','Taraba','Yobe','Zamfara'];
    seen text[] := '{}';
    links text[] := '{}';
    entries jsonb := '[]';
    card text[]; state text; name text; names text[]; total integer; changed integer;
BEGIN
    IF p_html IS NULL OR octet_length(p_html)>1048576 THEN
        RAISE EXCEPTION 'Invalid governor directory response';
    END IF;
    FOR card IN SELECT m FROM regexp_matches(p_html,
        '(?is)<h3 itemprop="name">[[:space:]]*?<a href="(/index[.]php/the-ngf/governors/[0-9]+-[a-z-]+-state-governor)"[^>]*?>[[:space:]]*?([^<]+?)</a>[[:space:]]*?</h3>(.*?)<div class="magazine-item-ct">(.*?)</div>', 'g') m
    LOOP
        state := replace(substring(coreaml_private.pep_state_house_text(card[2]) from '^(.+) State Governor$'),'-',' ');
        SELECT array_agg(value) INTO names FROM (
            SELECT coreaml_private.pep_state_house_text(m[1]) AS value
            FROM regexp_matches(card[4],'(?is)<p\y[^>]*?>(.*?)</p>','g') m
        ) x WHERE value<>'';
        IF card[3] ~* '<h3\y' OR state IS NULL OR NOT state=ANY(expected) OR state=ANY(seen)
           OR card[1]=ANY(links) OR cardinality(names) IS DISTINCT FROM 1 THEN
            RAISE EXCEPTION 'Invalid or duplicate governor profile %, %', state, cardinality(names);
        END IF;
        name := regexp_replace(names[1],
            '^(?:(?:Rt[.]|Hon[.]|Dr[.]|Sen[.]|Engr[.]|Prof[.]|Rev[.]|Fr[.]|Pastor|Engineer|Alhaji|Prince)[[:space:]]+)+','','i');
        name := regexp_replace(name,'[[:space:]]+(?:CFR|CON|OFR|MFR|MON)$','','i');
        -- Imo State's official governor profile uses this spelling.
        IF state='Imo' AND name='Hope Odidika Uzodinma' THEN
            name := 'Hope Odidika Uzodimma';
        END IF;
        IF length(name) NOT BETWEEN 2 AND 200 OR name ~ '[<>&[:cntrl:]]' THEN
            RAISE EXCEPTION 'Invalid governor name';
        END IF;
        seen := array_append(seen,state);
        links := array_append(links,card[1]);
        entries := entries || jsonb_build_object('source_reference','https://www.ngf.org.ng'||card[1],
            'full_name',name,'public_role','Governor · '||state||' State');
    END LOOP;
    total := cardinality(seen);
    IF total<>36 THEN RAISE EXCEPTION 'Expected all 36 state governor profiles'; END IF;
    LOCK TABLE coreaml_private.pep_officeholder_records IN SHARE ROW EXCLUSIVE MODE;
    INSERT INTO coreaml_private.pep_officeholder_records AS r
        (source_reference,full_name,public_role,jurisdiction,source_name,checked_at,valid_until)
    SELECT source_reference,full_name,public_role,'Nigeria',roster_source,checked,checked+interval '7 days'
    FROM jsonb_to_recordset(entries) AS e(source_reference text,full_name text,public_role text)
    ON CONFLICT (source_reference) DO UPDATE SET
        full_name=excluded.full_name,public_role=excluded.public_role,
        jurisdiction=excluded.jurisdiction,checked_at=excluded.checked_at,valid_until=excluded.valid_until
    WHERE r.source_name=roster_source;
    GET DIAGNOSTICS changed=ROW_COUNT;
    IF changed<>total THEN RAISE EXCEPTION 'Governors’ Forum reference belongs to another source' USING ERRCODE='22023'; END IF;
    -- Retain omitted records as history, without offering them for new screening.
    UPDATE coreaml_private.pep_officeholder_records r
    SET valid_until=checked
    WHERE r.source_name=roster_source AND r.valid_until>checked AND r.checked_at<checked
      AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(entries) AS e(row) WHERE row->>'source_reference'=r.source_reference);

    RETURN total;
END
$$;

CREATE FUNCTION coreaml_private.refresh_pep_governors_roster()
RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE
    started timestamptz := clock_timestamp();
    payload text; response_status integer; total integer;
    failure text := 'FETCH_FAILED';
BEGIN
    IF NOT pg_try_advisory_xact_lock(174021322,213662034) THEN
        RETURN jsonb_build_object('status','ALREADY_RUNNING');
    END IF;
    BEGIN
        PERFORM set_config('http.curlopt_timeout_ms','25000',true);
        PERFORM set_config('http.curlopt_followlocation','0',true);
        SELECT status,content INTO response_status,payload
        FROM coreaml_refresh_transport.http_get('https://www.ngf.org.ng/index.php/the-ngf/governors');
        IF response_status IS DISTINCT FROM 200 THEN RAISE EXCEPTION 'Governor directory fetch failed'; END IF;
        failure := 'VALIDATION_OR_PUBLISH_FAILED';
        total := coreaml_private.publish_pep_governors_roster(payload);
        INSERT INTO coreaml_private.pep_governors_refresh_runs(started_at,status,record_count,source_sha256)
        VALUES (started,'SUCCEEDED',total,encode(sha256(convert_to(payload,'UTF8')),'hex'));
        RETURN jsonb_build_object('status','SUCCEEDED','record_count',total);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO coreaml_private.pep_governors_refresh_runs(started_at,status,failure_code)
        VALUES (started,'FAILED',failure);
        RETURN jsonb_build_object('status','FAILED','failure_code',failure);
    END;
END
$$;
REVOKE ALL ON FUNCTION coreaml_private.publish_pep_governors_roster(text),
    coreaml_private.refresh_pep_governors_roster() FROM PUBLIC, anon, authenticated, service_role;
