-- Local draft: no hosted changes and no migration history entry.
CREATE SCHEMA IF NOT EXISTS coreaml_private;
REVOKE ALL ON SCHEMA coreaml_private FROM PUBLIC,anon;
GRANT USAGE ON SCHEMA coreaml_private TO authenticated;
CREATE TABLE IF NOT EXISTS public.kyc_reviews (
 id uuid PRIMARY KEY, customer_id uuid NOT NULL REFERENCES public.customers(id),
 account_id uuid NOT NULL UNIQUE REFERENCES public.accounts(id), tenant_id text NOT NULL,
 reviewer_id uuid NOT NULL REFERENCES public.user_profiles(id),
 identity_reference text NOT NULL CHECK(length(btrim(identity_reference)) BETWEEN 5 AND 500),
 screening_reference text NOT NULL CHECK(length(btrim(screening_reference)) BETWEEN 5 AND 500),
 notes text NOT NULL CHECK(length(btrim(notes)) BETWEEN 20 AND 4000),
 risk_flags jsonb NOT NULL, risk_score integer NOT NULL CHECK(risk_score BETWEEN 1 AND 99),
 id_path text NOT NULL, utility_path text NOT NULL,
 review_method text NOT NULL DEFAULT 'MANUAL_ATTESTATION' CHECK(review_method='MANUAL_ATTESTATION'),
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.kyc_reviews ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.kyc_reviews FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.kyc_reviews TO authenticated;
DROP POLICY IF EXISTS coreaml_kyc_review_read ON public.kyc_reviews;
CREATE POLICY coreaml_kyc_review_read ON public.kyc_reviews FOR SELECT TO authenticated
USING(EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=(SELECT auth.uid()) AND p.is_active
 AND p.role=(SELECT auth.jwt()->'app_metadata'->>'role')
 AND p.tenant_id=kyc_reviews.tenant_id AND p.tenant_id=(SELECT auth.jwt()->'app_metadata'->>'tenant_id')));

CREATE OR REPLACE FUNCTION coreaml_private.approve_manual_kyc(
 p_review_id uuid,p_customer_id uuid,p_identity_reference text,p_screening_reference text,p_notes text,p_flags jsonb
) RETURNS TABLE(customer_id uuid,account_id uuid,account_status text,review_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor uuid:=auth.uid(); staff public.user_profiles%ROWTYPE; c public.customers%ROWTYPE;
 a public.accounts%ROWTYPE; prior public.kyc_reviews%ROWTYPE; bank text:=NULLIF(auth.jwt()->'app_metadata'->>'tenant_id','');
 flags jsonb; score integer; tier text; prefix text;
BEGIN
 SELECT * INTO staff FROM public.user_profiles WHERE id=actor AND is_active FOR SHARE;
 IF actor IS NULL OR bank IS NULL OR staff.id IS NULL OR staff.tenant_id IS DISTINCT FROM bank
  OR staff.role IS DISTINCT FROM (auth.jwt()->'app_metadata'->>'role')
  OR staff.role NOT IN ('compliance_officer','head_of_compliance') THEN
  RAISE EXCEPTION 'Active same-bank compliance reviewer is required' USING ERRCODE='42501'; END IF;
 IF p_review_id IS NULL OR p_customer_id IS NULL OR p_flags IS NULL OR jsonb_typeof(p_flags)<>'object'
  OR p_identity_reference IS NULL OR length(btrim(p_identity_reference)) NOT BETWEEN 5 AND 500
  OR p_screening_reference IS NULL OR length(btrim(p_screening_reference)) NOT BETWEEN 5 AND 500
  OR p_notes IS NULL OR length(btrim(p_notes)) NOT BETWEEN 20 AND 4000 THEN
  RAISE EXCEPTION 'Evidence references, review notes and risk flags are required' USING ERRCODE='22023'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each(p_flags) f WHERE f.key NOT IN ('face_to_face','cash_intensive','complex_structure','pep_or_adverse_media') OR jsonb_typeof(f.value)<>'boolean')
  OR NOT p_flags ?& ARRAY['face_to_face','cash_intensive','complex_structure','pep_or_adverse_media'] THEN
  RAISE EXCEPTION 'All four risk flags must be explicit booleans' USING ERRCODE='22023'; END IF;
 flags:=p_flags;
 SELECT * INTO c FROM public.customers WHERE id=p_customer_id AND tenant_id=bank FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Application unavailable' USING ERRCODE='42501'; END IF;
 PERFORM 1 FROM public.accounts x WHERE x.customer_id=c.id ORDER BY x.id FOR UPDATE;
 IF (SELECT count(*) FROM public.accounts x WHERE x.customer_id=c.id)<>1 THEN
  RAISE EXCEPTION 'Application requires account reconciliation' USING ERRCODE='23514'; END IF;
 SELECT * INTO a FROM public.accounts x WHERE x.customer_id=c.id;
 SELECT * INTO prior FROM public.kyc_reviews r WHERE r.account_id=a.id;
 IF FOUND THEN
  IF prior.id=p_review_id AND prior.reviewer_id=actor AND prior.identity_reference=btrim(p_identity_reference)
   AND prior.screening_reference=btrim(p_screening_reference) AND prior.notes=btrim(p_notes) AND prior.risk_flags=flags
   AND c.kyc_status='COMPLETED' AND a.status::text='ACTIVE' THEN
   RETURN QUERY SELECT c.id,a.id,a.status::text,prior.id; RETURN;
  END IF;
  RAISE EXCEPTION 'Application already reviewed; details cannot be replaced' USING ERRCODE='22023';
 END IF;
 IF c.kyc_status<>'PENDING' OR a.status::text<>'PENDING' OR a.balance IS DISTINCT FROM 0::numeric THEN
  RAISE EXCEPTION 'Only pending zero-balance applications can be activated' USING ERRCODE='23514'; END IF;
 prefix:=bank||'/'||c.id::text||'/';
 IF c.id_url IS NULL OR c.utility_bill_url IS NULL OR c.id_url=c.utility_bill_url
  OR left(c.id_url,length(prefix))<>prefix OR left(c.utility_bill_url,length(prefix))<>prefix
  OR (SELECT count(*) FROM storage.objects o WHERE o.bucket_id='kyc-vault' AND o.name IN(c.id_url,c.utility_bill_url) AND NULLIF(o.owner_id,'') IS NOT NULL)<>2 THEN
  RAISE EXCEPTION 'Both bank-scoped KYC documents must be present' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT 1 FROM storage.objects o WHERE o.bucket_id='kyc-vault'
  AND o.name IN(c.id_url,c.utility_bill_url) AND o.owner_id=actor::text) THEN
  RAISE EXCEPTION 'The submitting staff member cannot approve this application' USING ERRCODE='42501'; END IF;
 score:=10+CASE WHEN c.customer_type IN ('CORPORATE','Corporate') THEN 20 ELSE 0 END
  +CASE WHEN flags->>'face_to_face'='true' THEN -10 ELSE 0 END
  +CASE WHEN flags->>'cash_intensive'='true' THEN 25 ELSE 0 END
  +CASE WHEN flags->>'complex_structure'='true' THEN 30 ELSE 0 END
  +CASE WHEN flags->>'pep_or_adverse_media'='true' THEN 40 ELSE 0 END;
 score:=greatest(1,least(99,score));
 -- Retain existing risk rather than overwrite a higher stored assessment.
 score:=greatest(score,least(99,ceil(coalesce(c.risk_score,0)))::integer,
  CASE WHEN c.risk_tier='HIGH' OR c.is_pep IS TRUE OR flags->>'pep_or_adverse_media'='true' THEN 75 ELSE 1 END);
 IF (score>=75 OR flags->>'pep_or_adverse_media'='true' OR c.is_pep IS TRUE)
  AND staff.role<>'head_of_compliance' THEN
  RAISE EXCEPTION 'High-risk or PEP applications require head-of-compliance review' USING ERRCODE='42501'; END IF;
 tier:=CASE WHEN score>=75 THEN 'HIGH' WHEN score>=40 THEN 'MEDIUM' ELSE 'LOW' END;
 INSERT INTO public.kyc_reviews(id,customer_id,account_id,tenant_id,reviewer_id,identity_reference,screening_reference,notes,risk_flags,risk_score,id_path,utility_path)
 VALUES(p_review_id,c.id,a.id,bank,actor,btrim(p_identity_reference),btrim(p_screening_reference),btrim(p_notes),flags,score,c.id_url,c.utility_bill_url);
 UPDATE public.customers SET kyc_status='COMPLETED',risk_score=score,risk_tier=tier,updated_at=now() WHERE id=c.id;
 UPDATE public.accounts SET status='ACTIVE',updated_at=now() WHERE id=a.id;
 RETURN QUERY SELECT c.id,a.id,'ACTIVE'::text,p_review_id;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.approve_manual_kyc(uuid,uuid,text,text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION coreaml_private.approve_manual_kyc(uuid,uuid,text,text,text,jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.approve_manual_kyc(p_review_id uuid,p_customer_id uuid,p_identity_reference text,p_screening_reference text,p_notes text,p_flags jsonb)
RETURNS TABLE(customer_id uuid,account_id uuid,account_status text,review_id uuid)
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT * FROM coreaml_private.approve_manual_kyc(p_review_id,p_customer_id,p_identity_reference,p_screening_reference,p_notes,p_flags);
$$;
REVOKE ALL ON FUNCTION public.approve_manual_kyc(uuid,uuid,text,text,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.approve_manual_kyc(uuid,uuid,text,text,text,jsonb) TO authenticated;

-- Review records, not browser flags, authorize the two state transitions.
CREATE OR REPLACE FUNCTION public.coreaml_guard_kyc_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF TG_TABLE_NAME='customers' THEN
  IF NEW.kyc_status='COMPLETED' AND (TG_OP='INSERT' OR OLD.kyc_status IS DISTINCT FROM NEW.kyc_status) THEN
   IF NOT EXISTS(SELECT 1 FROM public.kyc_reviews r WHERE r.customer_id=NEW.id AND r.tenant_id=NEW.tenant_id
    AND r.id_path=NEW.id_url AND r.utility_path=NEW.utility_bill_url) THEN
    RAISE EXCEPTION 'Recorded KYC review is required' USING ERRCODE='42501'; END IF;
  END IF;
 ELSE
  IF TG_OP='UPDATE' AND OLD.status::text='PENDING' AND NEW.status IS DISTINCT FROM OLD.status THEN
   IF NEW.status::text<>'ACTIVE' OR NEW.balance IS DISTINCT FROM 0::numeric OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
    OR NOT EXISTS(SELECT 1 FROM public.kyc_reviews r JOIN public.customers c ON c.id=r.customer_id
     WHERE r.account_id=NEW.id AND r.customer_id=NEW.customer_id AND c.kyc_status='COMPLETED') THEN
    RAISE EXCEPTION 'Recorded KYC approval is required for pending account activation' USING ERRCODE='42501'; END IF;
  END IF;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_guard_kyc_transition() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS coreaml_guard_customer_kyc ON public.customers;
CREATE TRIGGER coreaml_guard_customer_kyc BEFORE INSERT OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.coreaml_guard_kyc_transition();
DROP TRIGGER IF EXISTS coreaml_guard_account_activation ON public.accounts;
CREATE TRIGGER coreaml_guard_account_activation BEFORE UPDATE ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.coreaml_guard_kyc_transition();
NOTIFY pgrst,'reload schema';
