-- Customer and account creation remain subject to caller RLS (no definer RPC).
-- No redundant accounts.tenant_id column is needed: customers hold bank ownership.
DROP POLICY IF EXISTS coreaml_pending_account_insert ON public.accounts;
CREATE POLICY coreaml_pending_account_insert ON public.accounts FOR INSERT TO authenticated
WITH CHECK (
  (SELECT auth.uid()) IS NOT NULL
  AND (SELECT auth.jwt()->'app_metadata'->>'role') IN ('teller','sales_rep','branch_manager','bankmanager')
  AND status::text='PENDING' AND balance=0
  AND EXISTS(SELECT 1 FROM public.customers c WHERE c.id=accounts.customer_id
    AND c.tenant_id=(SELECT auth.jwt()->'app_metadata'->>'tenant_id') AND c.kyc_status='PENDING')
  AND EXISTS(SELECT 1 FROM public.user_profiles s WHERE s.id=(SELECT auth.uid()) AND s.is_active
    AND s.role=(SELECT auth.jwt()->'app_metadata'->>'role')
    AND s.tenant_id=(SELECT auth.jwt()->'app_metadata'->>'tenant_id'))
);

INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('kyc-vault','kyc-vault',false,10485760,ARRAY['application/pdf','image/jpeg','image/png'])
ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=EXCLUDED.file_size_limit,allowed_mime_types=EXCLUDED.allowed_mime_types;

-- Existing permissive policies cannot override bank separation for this bucket.
DROP POLICY IF EXISTS coreaml_kyc_bank_boundary ON storage.objects;
CREATE POLICY coreaml_kyc_bank_boundary ON storage.objects AS RESTRICTIVE FOR ALL TO PUBLIC
USING(bucket_id<>'kyc-vault' OR ((SELECT auth.uid()) IS NOT NULL AND (
  (SELECT auth.jwt()->'app_metadata'->>'role')='it_admin'
  OR split_part(name,'/',1)=NULLIF((SELECT auth.jwt()->'app_metadata'->>'tenant_id'),'')
)))
WITH CHECK(bucket_id<>'kyc-vault' OR ((SELECT auth.uid()) IS NOT NULL
  AND split_part(name,'/',1)=NULLIF((SELECT auth.jwt()->'app_metadata'->>'tenant_id'),'')
));
DROP POLICY IF EXISTS coreaml_kyc_read ON storage.objects;
CREATE POLICY coreaml_kyc_read ON storage.objects FOR SELECT TO authenticated
USING(bucket_id='kyc-vault' AND EXISTS(SELECT 1 FROM public.user_profiles s
  WHERE s.id=(SELECT auth.uid()) AND s.is_active
    AND s.role=(SELECT auth.jwt()->'app_metadata'->>'role')));
DROP POLICY IF EXISTS coreaml_kyc_upload ON storage.objects;
CREATE POLICY coreaml_kyc_upload ON storage.objects FOR INSERT TO authenticated
WITH CHECK(bucket_id='kyc-vault' AND owner_id=(SELECT auth.uid())::text
  AND (SELECT auth.jwt()->'app_metadata'->>'role') IN ('teller','sales_rep','branch_manager','bankmanager')
  AND split_part(name,'/',1)=(SELECT auth.jwt()->'app_metadata'->>'tenant_id')
  AND EXISTS(SELECT 1 FROM public.user_profiles s WHERE s.id=(SELECT auth.uid()) AND s.is_active
    AND s.role=(SELECT auth.jwt()->'app_metadata'->>'role') AND s.tenant_id=split_part(name,'/',1))
);
DROP POLICY IF EXISTS coreaml_kyc_insert_guard ON storage.objects;
CREATE POLICY coreaml_kyc_insert_guard ON storage.objects AS RESTRICTIVE FOR INSERT TO PUBLIC
WITH CHECK(bucket_id<>'kyc-vault' OR (owner_id=(SELECT auth.uid())::text
  AND (SELECT auth.jwt()->'app_metadata'->>'role') IN ('teller','sales_rep','branch_manager','bankmanager')
  AND EXISTS(SELECT 1 FROM public.user_profiles s WHERE s.id=(SELECT auth.uid()) AND s.is_active
    AND s.role=(SELECT auth.jwt()->'app_metadata'->>'role') AND s.tenant_id=split_part(name,'/',1))
));
DROP POLICY IF EXISTS coreaml_kyc_cleanup ON storage.objects;
CREATE POLICY coreaml_kyc_cleanup ON storage.objects FOR DELETE TO authenticated
USING(bucket_id='kyc-vault' AND owner_id=(SELECT auth.uid())::text
  AND NOT EXISTS(SELECT 1 FROM public.customers c WHERE c.id_url=storage.objects.name OR c.utility_bill_url=storage.objects.name));
-- Uploaded KYC files are immutable through browser roles, including upsert.
DROP POLICY IF EXISTS coreaml_kyc_no_browser_update ON storage.objects;
CREATE POLICY coreaml_kyc_no_browser_update ON storage.objects AS RESTRICTIVE FOR UPDATE TO PUBLIC
USING(bucket_id<>'kyc-vault') WITH CHECK(bucket_id<>'kyc-vault');
DROP POLICY IF EXISTS coreaml_kyc_safe_delete ON storage.objects;
CREATE POLICY coreaml_kyc_safe_delete ON storage.objects AS RESTRICTIVE FOR DELETE TO PUBLIC
USING(bucket_id<>'kyc-vault' OR (owner_id=(SELECT auth.uid())::text
  AND NOT EXISTS(SELECT 1 FROM public.customers c WHERE c.id_url=storage.objects.name OR c.utility_bill_url=storage.objects.name)));

CREATE OR REPLACE FUNCTION public.onboard_customer(
  p_customer_id uuid,p_customer_type text,p_first_name text,p_last_name text,
  p_entity_name text,p_bvn text,p_id_path text,p_utility_path text
) RETURNS TABLE(customer_id uuid,account_id uuid,account_number text,account_status text)
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
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
END $$;
REVOKE ALL ON FUNCTION public.onboard_customer(uuid,text,text,text,text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.onboard_customer(uuid,text,text,text,text,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.reject_pending_account_posting() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE account_state text;
BEGIN
  SELECT status::text INTO account_state FROM public.accounts WHERE id=NEW.account_id;
  IF account_state IS NULL THEN RAISE EXCEPTION 'Account is unavailable to this caller' USING ERRCODE='42501'; END IF;
  IF account_state='PENDING' THEN RAISE EXCEPTION 'Pending accounts cannot receive transaction postings' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.reject_pending_account_posting() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS coreaml_reject_pending_account_posting ON public.transactions;
CREATE TRIGGER coreaml_reject_pending_account_posting BEFORE INSERT ON public.transactions
FOR EACH ROW EXECUTE FUNCTION public.reject_pending_account_posting();

-- Never send an unconfigured local webhook to another project's default port.
-- The existing webhook remains optional; pending onboarding is not a KYC pass.
CREATE OR REPLACE FUNCTION public.enqueue_match_entity_webhook() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_base_url text; v_anon_key text; v_secret text;
BEGIN
  SELECT decrypted_secret INTO v_base_url FROM vault.decrypted_secrets WHERE name='project_url';
  SELECT decrypted_secret INTO v_anon_key FROM vault.decrypted_secrets WHERE name='anon_key';
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name='match_entity_webhook_secret';
  IF NULLIF(v_base_url,'') IS NULL OR NULLIF(v_anon_key,'') IS NULL OR NULLIF(v_secret,'') IS NULL THEN
    RAISE LOG 'Entity screening webhook unconfigured; no external request queued';
    RETURN NEW;
  END IF;
  PERFORM net.http_post(url:=rtrim(v_base_url,'/')||'/functions/v1/match-entity',
    headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_anon_key,'x-webhook-secret',v_secret),
    body:=jsonb_build_object('type',TG_OP,'table',TG_TABLE_NAME,'schema',TG_TABLE_SCHEMA,'record',NEW,'old_record',OLD));
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.enqueue_match_entity_webhook() FROM PUBLIC,anon,authenticated;
NOTIFY pgrst,'reload schema';
