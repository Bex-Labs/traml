CREATE TABLE IF NOT EXISTS coreaml_private.corporate_customer_people (
    customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
    tenant_id text NOT NULL,
    full_name text NOT NULL CHECK (length(full_name) BETWEEN 1 AND 200),
    bvn text NOT NULL CHECK (bvn ~ '^[0-9]{11}$'),
    person_role text NOT NULL CHECK (person_role IN ('DIRECTOR','SIGNATORY','BENEFICIAL_OWNER')),
    PRIMARY KEY (customer_id, bvn, person_role)
);
ALTER TABLE coreaml_private.corporate_customer_people ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE coreaml_private.corporate_customer_people FROM PUBLIC, anon, authenticated, service_role;

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
      'bvn',person->>'bvn','role',person->>'role') ORDER BY person->>'bvn', person->>'role')
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
    SELECT jsonb_agg(jsonb_build_object('full_name',p.full_name,'bvn',p.bvn,'role',p.person_role)
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
  INSERT INTO coreaml_private.corporate_customer_people(customer_id,tenant_id,full_name,bvn,person_role)
  SELECT p_customer_id,bank,person->>'full_name',person->>'bvn',person->>'role'
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

REVOKE ALL ON FUNCTION public.onboard_corporate_customer(uuid,text,text,jsonb,text,text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.onboard_corporate_customer(uuid,text,text,jsonb,text,text) TO authenticated;
NOTIFY pgrst, 'reload schema';
