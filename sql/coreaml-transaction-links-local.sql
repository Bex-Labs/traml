BEGIN;
DO $$ DECLARE existing regclass:=to_regclass('public.coreaml_transaction_links');BEGIN
 IF existing IS NOT NULL AND obj_description(existing,'pg_class') IS DISTINCT FROM 'coreaml_transaction_links_v1' THEN RAISE EXCEPTION 'Unrecognized transfer links table';END IF;
END $$;
CREATE TABLE IF NOT EXISTS public.coreaml_transaction_links(
 id uuid PRIMARY KEY,
 tenant_id text NOT NULL,
 debit_transaction_id uuid NOT NULL UNIQUE REFERENCES public.transactions(id) ON DELETE RESTRICT,
 credit_transaction_id uuid NOT NULL UNIQUE REFERENCES public.transactions(id) ON DELETE RESTRICT,
 linkage_source text NOT NULL CHECK(linkage_source IN ('SYNTHETIC_DEMO','CORE_BANKING')),
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK(debit_transaction_id<>credit_transaction_id)
);
COMMENT ON TABLE public.coreaml_transaction_links IS 'coreaml_transaction_links_v1';
ALTER TABLE public.coreaml_transaction_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_transaction_links FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.coreaml_transaction_links TO authenticated;
DROP POLICY IF EXISTS coreaml_read_verified_transfer ON public.coreaml_transaction_links;
CREATE POLICY coreaml_read_verified_transfer ON public.coreaml_transaction_links FOR SELECT TO authenticated USING (
 EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=(SELECT auth.uid()) AND p.is_active IS TRUE AND p.tenant_id=coreaml_transaction_links.tenant_id AND p.role IN ('compliance_officer','head_of_compliance','bank_manager'))
 AND EXISTS(SELECT 1 FROM public.transactions d JOIN public.accounts da ON da.id=d.account_id JOIN public.customers dc ON dc.id=da.customer_id
 JOIN public.transactions c ON c.id=coreaml_transaction_links.credit_transaction_id JOIN public.accounts ca ON ca.id=c.account_id JOIN public.customers cc ON cc.id=ca.customer_id
 WHERE d.id=coreaml_transaction_links.debit_transaction_id AND dc.tenant_id=coreaml_transaction_links.tenant_id AND cc.tenant_id=coreaml_transaction_links.tenant_id
 AND d.transaction_type='DEBIT' AND c.transaction_type='CREDIT' AND d.amount=c.amount AND d.amount>0 AND d.currency=c.currency AND da.customer_id<>ca.customer_id)
);
COMMIT;
