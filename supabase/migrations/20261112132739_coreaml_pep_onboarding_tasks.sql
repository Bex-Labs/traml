ALTER TABLE coreaml_private.corporate_customer_people
    ADD COLUMN pep_declaration text CHECK (pep_declaration IN ('NO_EXPOSURE','EXPOSURE','UNKNOWN'));

CREATE TABLE coreaml_private.pep_officeholder_records (
    source_reference text PRIMARY KEY CHECK (length(source_reference) BETWEEN 1 AND 500),
    full_name text NOT NULL CHECK (length(full_name) BETWEEN 1 AND 200),
    public_role text NOT NULL CHECK (length(public_role) BETWEEN 1 AND 200),
    jurisdiction text NOT NULL CHECK (length(jurisdiction) BETWEEN 1 AND 120),
    source_name text NOT NULL CHECK (length(source_name) BETWEEN 1 AND 200),
    checked_at timestamptz NOT NULL,
    valid_until timestamptz NOT NULL CHECK (valid_until > checked_at)
);
CREATE INDEX pep_officeholder_name ON coreaml_private.pep_officeholder_records
    (lower(regexp_replace(btrim(full_name), '[[:space:]]+', ' ', 'g')));
ALTER TABLE coreaml_private.pep_officeholder_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_officeholder_records FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE coreaml_private.pep_onboarding_tasks (
    subject_id uuid PRIMARY KEY REFERENCES coreaml_private.corporate_customer_people(subject_id) ON DELETE CASCADE,
    customer_id uuid NOT NULL,
    tenant_id text NOT NULL,
    assigned_to uuid,
    reason text NOT NULL CHECK (reason IN ('DECLARATION','POSSIBLE_MATCH','SCREENING_INCOMPLETE')),
    source_evidence jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE coreaml_private.pep_onboarding_tasks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.pep_onboarding_tasks FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION coreaml_private.queue_corporate_pep_onboarding()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE matches jsonb; reason text; evidence text; outcome text; owner_id uuid;
BEGIN
    IF NEW.person_role <> 'BENEFICIAL_OWNER' THEN RETURN NEW; END IF;
    SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.source_reference),'[]'::jsonb)
    INTO matches
    FROM (
        SELECT source_reference,full_name,public_role,jurisdiction,source_name,checked_at
        FROM coreaml_private.pep_officeholder_records r
        WHERE r.checked_at <= now() AND r.valid_until > now()
          AND lower(regexp_replace(btrim(r.full_name),'[[:space:]]+',' ','g')) =
              lower(regexp_replace(btrim(NEW.full_name),'[[:space:]]+',' ','g'))
        ORDER BY source_reference LIMIT 25
    ) m;
    IF jsonb_array_length(matches) > 0 THEN
        reason := 'POSSIBLE_MATCH';
        evidence := 'Possible name match in configured PEP sources. Compare identity before confirming exposure.';
        outcome := 'POSSIBLE_EXPOSURE';
    ELSIF NEW.pep_declaration='EXPOSURE' THEN
        reason := 'DECLARATION';
        evidence := 'Exposure declared at onboarding. Obtain supporting evidence and verify the relationship.';
        outcome := 'POSSIBLE_EXPOSURE';
    ELSIF NEW.pep_declaration IS DISTINCT FROM 'NO_EXPOSURE' OR NOT EXISTS (
        SELECT 1 FROM coreaml_private.pep_officeholder_records r
        WHERE r.checked_at <= now() AND r.valid_until > now()
    ) THEN
        reason := 'SCREENING_INCOMPLETE';
        evidence := 'The declaration or current source coverage is unavailable. Complete the missing checks.';
        outcome := 'INFORMATION_NEEDED';
    ELSE
        RETURN NEW;
    END IF;

    SELECT p.id INTO owner_id FROM public.user_profiles p
    WHERE p.tenant_id=NEW.tenant_id AND p.role='compliance_officer' AND p.is_active
    ORDER BY p.id LIMIT 1;

    INSERT INTO coreaml_private.pep_onboarding_tasks
        (subject_id,customer_id,tenant_id,assigned_to,reason,source_evidence)
    VALUES (NEW.subject_id,NEW.customer_id,NEW.tenant_id,owner_id,reason,matches);

    INSERT INTO coreaml_private.pep_review_events
        (id,customer_id,tenant_id,subject_id,subject_name,actor_id,status,exposure,evidence)
    VALUES (gen_random_uuid(),NEW.customer_id,NEW.tenant_id,NEW.subject_id,NEW.full_name,
            auth.uid(),outcome,CASE WHEN outcome='POSSIBLE_EXPOSURE' THEN 'UNKNOWN' END,evidence);
    RETURN NEW;
END
$$;
REVOKE ALL ON FUNCTION coreaml_private.queue_corporate_pep_onboarding() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER queue_corporate_pep_onboarding
AFTER INSERT ON coreaml_private.corporate_customer_people
FOR EACH ROW EXECUTE FUNCTION coreaml_private.queue_corporate_pep_onboarding();

CREATE OR REPLACE FUNCTION public.onboard_corporate_customer(p_customer_id uuid, p_entity_name text, p_registration_number text, p_people jsonb, p_id_path text, p_utility_path text)
 RETURNS TABLE(customer_id uuid, account_id uuid, account_number text, account_status text)
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  actor uuid := auth.uid(); staff public.user_profiles%ROWTYPE;
  bank text;
  prefix text; prior public.customers%ROWTYPE; acct public.accounts%ROWTYPE;
  people jsonb; previous_people jsonb;
  generated_number text; tries integer := 0;
BEGIN
  staff := coreaml_private.dashboard_staff(ARRAY['teller','sales_rep','branch_manager','bankmanager']);
  bank := staff.tenant_id;
  IF p_customer_id IS NULL OR length(btrim(coalesce(p_entity_name,''))) NOT BETWEEN 1 AND 200
    OR p_registration_number IS NULL OR p_registration_number !~ '^[0-9]{1,20}$'
    OR jsonb_typeof(p_people) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Registered company name, CAC RC number, and linked people are required' USING ERRCODE='22023';
  END IF;
  IF jsonb_array_length(p_people) NOT BETWEEN 1 AND 50 OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_people) AS items(person)
    WHERE jsonb_typeof(person) <> 'object'
       OR length(btrim(coalesce(person->>'full_name',''))) NOT BETWEEN 1 AND 200
       OR coalesce(person->>'bvn','') !~ '^[0-9]{11}$'
       OR (person ? 'pep_declaration' AND coalesce(person->>'pep_declaration','') NOT IN ('NO_EXPOSURE','EXPOSURE','UNKNOWN'))
       OR coalesce(person->>'role','') NOT IN ('DIRECTOR','SIGNATORY','BENEFICIAL_OWNER')
  ) THEN
    RAISE EXCEPTION 'Enter a valid name, role, and BVN for each linked person' USING ERRCODE='22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_people) AS items(person)
    GROUP BY person->>'bvn'
    HAVING count(DISTINCT lower(btrim(person->>'full_name'))) > 1
      OR count(*) <> count(DISTINCT person->>'role')
  ) THEN
    RAISE EXCEPTION 'Use a consistent name and one entry per role for each BVN' USING ERRCODE='22023';
  END IF;
  SELECT jsonb_agg(jsonb_build_object('full_name',btrim(person->>'full_name'),
      'bvn',person->>'bvn','role',person->>'role','pep_declaration',person->>'pep_declaration') ORDER BY person->>'bvn', person->>'role')
    INTO people FROM jsonb_array_elements(p_people) AS items(person);
  prefix:=bank||'/'||p_customer_id::text||'/';
  IF p_id_path IS NULL OR p_utility_path IS NULL
    OR left(p_id_path,length(prefix))<>prefix OR left(p_utility_path,length(prefix))<>prefix
    OR substring(p_id_path FROM length(prefix)+1) !~ '^id_document[.](pdf|jpg|jpeg|png)$'
    OR substring(p_utility_path FROM length(prefix)+1) !~ '^utility_bill[.](pdf|jpg|jpeg|png)$' THEN
    RAISE EXCEPTION 'KYC document paths must match the assigned bank and customer reference' USING ERRCODE='22023';
  END IF;
  IF (SELECT count(*) FROM storage.objects o WHERE o.bucket_id='kyc-vault'
       AND o.name IN (p_id_path,p_utility_path) AND o.owner_id=actor::text)<>2 THEN
    RAISE EXCEPTION 'Both KYC documents must be uploaded by this staff user first' USING ERRCODE='22023';
  END IF;
  -- Serialize retries for this request reference. A retry cannot create an
  -- additional account after a response is lost or two submits overlap.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_customer_id::text,0));
  SELECT * INTO prior FROM public.customers c WHERE c.id=p_customer_id;
  IF FOUND THEN
    SELECT jsonb_agg(jsonb_build_object('full_name',p.full_name,'bvn',p.bvn,'role',p.person_role,'pep_declaration',p.pep_declaration)
        ORDER BY p.bvn,p.person_role)
      INTO previous_people FROM coreaml_private.corporate_customer_people p
      WHERE p.customer_id=p_customer_id AND p.tenant_id=bank;
    IF prior.tenant_id IS DISTINCT FROM bank OR prior.customer_type <> 'CORPORATE'
      OR prior.registration_number IS DISTINCT FROM p_registration_number
      OR prior.entity_name IS DISTINCT FROM btrim(p_entity_name)
      OR previous_people IS DISTINCT FROM people
      OR prior.id_url IS DISTINCT FROM p_id_path OR prior.utility_bill_url IS DISTINCT FROM p_utility_path THEN
      RAISE EXCEPTION 'Submission reference already exists with different details' USING ERRCODE='22023';
    END IF;
    IF (SELECT count(*) FROM public.accounts a WHERE a.customer_id=p_customer_id)<>1 THEN
      RAISE EXCEPTION 'Existing submission needs account reconciliation' USING ERRCODE='22023';
    END IF;
    SELECT * INTO acct FROM public.accounts a WHERE a.customer_id=p_customer_id;
    RETURN QUERY SELECT p_customer_id,acct.id,acct.account_number::text,acct.status::text;
    RETURN;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(bank||':corporate-rc:'||p_registration_number,0));
  IF EXISTS (SELECT 1 FROM public.customers c
    WHERE c.tenant_id=bank AND c.customer_type='CORPORATE'
      AND regexp_replace(upper(btrim(c.registration_number)), '^RC[ -]*', '')=p_registration_number) THEN
    RAISE EXCEPTION 'A company with this CAC RC number already exists in this bank' USING ERRCODE='22023';
  END IF;
  INSERT INTO public.customers(id,tenant_id,customer_type,entity_name,registration_number,kyc_status,id_url,utility_bill_url)
  VALUES(p_customer_id,bank,'CORPORATE',btrim(p_entity_name),p_registration_number,'PENDING',p_id_path,p_utility_path);
  INSERT INTO coreaml_private.corporate_customer_people(customer_id,tenant_id,full_name,bvn,person_role,pep_declaration)
  SELECT p_customer_id,bank,person->>'full_name',person->>'bvn',person->>'role',person->>'pep_declaration'
  FROM jsonb_array_elements(people) AS items(person);
  LOOP
    tries:=tries+1;
    generated_number:=(1000000000+floor(random()*9000000000))::bigint::text;
    BEGIN
      INSERT INTO public.accounts(customer_id,account_number,account_type,currency,status,opened_at,balance)
      VALUES(p_customer_id,generated_number,'SAVINGS','NGN','PENDING',CURRENT_DATE,0) RETURNING * INTO acct;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      IF tries>=5 THEN RAISE; END IF;
    END;
  END LOOP;
  RETURN QUERY SELECT p_customer_id,acct.id,acct.account_number::text,acct.status::text;
END $function$;

CREATE OR REPLACE FUNCTION public.coreaml_pep_subjects(p_customer uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.id=p_customer AND c.tenant_id=staff.tenant_id) THEN
        RAISE EXCEPTION 'Customer unavailable' USING ERRCODE='42501';
    END IF;
    RETURN jsonb_build_object('role',staff.role,'subjects',coalesce((
        SELECT jsonb_agg(to_jsonb(s) || jsonb_build_object('latest',to_jsonb(e),'onboarding',to_jsonb(t))
                         ORDER BY s.full_name,s.person_role,s.subject_id)
        FROM coreaml_private.pep_subjects(staff.tenant_id,p_customer) s
        LEFT JOIN LATERAL (
            SELECT reason,source_evidence,created_at,assigned_to IS NOT NULL AS assigned,
                   coalesce(assigned_to=staff.id,false) AS assigned_to_me
            FROM coreaml_private.pep_onboarding_tasks t
            WHERE t.tenant_id=staff.tenant_id AND t.customer_id=p_customer AND t.subject_id=s.subject_id
        ) t ON true
        LEFT JOIN LATERAL (
            SELECT id,status,exposure,evidence,created_at
            FROM coreaml_private.pep_review_events e
            WHERE e.tenant_id=staff.tenant_id AND e.customer_id=p_customer AND e.subject_id=s.subject_id
            ORDER BY e.created_at DESC,e.id DESC LIMIT 1
        ) e ON true
    ),'[]'::jsonb));
END
$$;

CREATE OR REPLACE FUNCTION public.coreaml_pep_queue(p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles;
BEGIN
    staff := coreaml_private.dashboard_staff(ARRAY['compliance_officer','head_of_compliance']);
    IF p_offset IS NULL OR p_offset < 0 THEN RAISE EXCEPTION 'Invalid offset' USING ERRCODE='22023'; END IF;
    RETURN coalesce((
        SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC,q.id DESC)
        FROM (
            SELECT e.id,e.customer_id,e.subject_id,e.subject_name,e.status,e.exposure,e.evidence,e.created_at,
                   t.reason,t.assigned_to IS NOT NULL AS assigned,
                   coalesce(t.assigned_to=staff.id,false) AS assigned_to_me,
                   coalesce(c.entity_name,concat_ws(' ',c.first_name,c.last_name)) AS customer_name
            FROM coreaml_private.pep_review_events e
            JOIN public.customers c ON c.id=e.customer_id AND c.tenant_id=e.tenant_id
            LEFT JOIN coreaml_private.pep_onboarding_tasks t
              ON t.tenant_id=e.tenant_id AND t.customer_id=e.customer_id AND t.subject_id=e.subject_id
            WHERE e.tenant_id=staff.tenant_id
              AND e.status IN ('POSSIBLE_EXPOSURE','INFORMATION_NEEDED','CONFIRMED_EXPOSURE','EDD_REVIEWED')
              AND NOT EXISTS (SELECT 1 FROM coreaml_private.pep_review_events n WHERE n.prior_id=e.id)
            ORDER BY e.created_at DESC,e.id DESC
            LIMIT 26 OFFSET p_offset
        ) q
    ),'[]'::jsonb);
END
$$;
NOTIFY pgrst, 'reload schema';
