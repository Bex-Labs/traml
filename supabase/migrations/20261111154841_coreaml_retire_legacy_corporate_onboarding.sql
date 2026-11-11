CREATE OR REPLACE FUNCTION public.onboard_customer(p_customer_id uuid, p_customer_type text, p_first_name text, p_last_name text, p_entity_name text, p_bvn text, p_id_path text, p_utility_path text)
 RETURNS TABLE(customer_id uuid, account_id uuid, account_number text, account_status text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  actor uuid := auth.uid(); staff public.user_profiles%ROWTYPE;
  bank text := NULLIF(auth.jwt()->'app_metadata'->>'tenant_id','');
  staff_role text := auth.jwt()->'app_metadata'->>'role';
  prefix text; prior public.customers%ROWTYPE; acct public.accounts%ROWTYPE;
  generated_number text; tries integer := 0;
BEGIN
  SELECT * INTO staff FROM public.user_profiles WHERE id=actor AND is_active;
  IF actor IS NULL OR bank IS NULL OR staff.id IS NULL OR staff.tenant_id IS DISTINCT FROM bank
    OR staff.role IS DISTINCT FROM staff_role
    OR staff_role IS NULL OR staff_role NOT IN ('teller','sales_rep','branch_manager','bankmanager') THEN
    RAISE EXCEPTION 'Active banking staff assignment is required' USING ERRCODE='42501';
  END IF;
  IF p_customer_id IS NULL OR p_customer_type IS NULL OR p_customer_type NOT IN ('RETAIL','CORPORATE')
    OR p_bvn IS NULL OR p_bvn !~ '^[0-9]{11}$'
    OR (p_customer_type='RETAIL' AND (NULLIF(btrim(p_first_name),'') IS NULL OR NULLIF(btrim(p_last_name),'') IS NULL))
    OR (p_customer_type='CORPORATE' AND NULLIF(btrim(p_entity_name),'') IS NULL) THEN
    RAISE EXCEPTION 'Valid customer type, name, and 11-digit BVN are required' USING ERRCODE='22023';
  END IF;
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
    IF prior.tenant_id IS DISTINCT FROM bank OR prior.customer_type IS DISTINCT FROM p_customer_type
      OR prior.bvn::text IS DISTINCT FROM p_bvn OR prior.first_name IS DISTINCT FROM p_first_name
      OR prior.last_name IS DISTINCT FROM p_last_name OR prior.entity_name IS DISTINCT FROM p_entity_name
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
  IF p_customer_type='CORPORATE' THEN
    RAISE EXCEPTION 'Use the corporate onboarding form to provide the CAC RC number and linked people' USING ERRCODE='22023';
  END IF;
  INSERT INTO public.customers(id,tenant_id,customer_type,first_name,last_name,entity_name,bvn,kyc_status,id_url,utility_bill_url)
  VALUES(p_customer_id,bank,p_customer_type,p_first_name,p_last_name,p_entity_name,p_bvn,'PENDING',p_id_path,p_utility_path);
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

