-- Draft remediation for the local baseline at source commit 24691a2.
-- Existing permissive policies remain in place. These restrictive policies
-- constrain them for every command; adding another permissive policy cannot
-- bypass the bank boundary. Existing it_admin visibility is retained.
-- Other tables, RPCs, views, and server/service-role paths need separate review.

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS coreaml_customers_bank_boundary ON public.customers;
CREATE POLICY coreaml_customers_bank_boundary
ON public.customers AS RESTRICTIVE FOR ALL TO PUBLIC
USING (
    (SELECT auth.uid()) IS NOT NULL
    AND (
        (SELECT auth.jwt() -> 'app_metadata' ->> 'role') = 'it_admin'
        OR tenant_id = NULLIF((SELECT auth.jwt() -> 'app_metadata' ->> 'tenant_id'), '')
    )
)
WITH CHECK (
    (SELECT auth.uid()) IS NOT NULL
    AND (
        (SELECT auth.jwt() -> 'app_metadata' ->> 'role') = 'it_admin'
        OR tenant_id = NULLIF((SELECT auth.jwt() -> 'app_metadata' ->> 'tenant_id'), '')
    )
);

-- Account ownership comes from its customer; no redundant tenant_id column
-- is added in this change. The onboarding column mismatch remains open.
DROP POLICY IF EXISTS coreaml_accounts_bank_boundary ON public.accounts;
CREATE POLICY coreaml_accounts_bank_boundary
ON public.accounts AS RESTRICTIVE FOR ALL TO PUBLIC
USING (
    (SELECT auth.uid()) IS NOT NULL
    AND (
        (SELECT auth.jwt() -> 'app_metadata' ->> 'role') = 'it_admin'
        OR EXISTS (
            SELECT 1 FROM public.customers AS account_customer
            WHERE account_customer.id = accounts.customer_id
              AND account_customer.tenant_id = NULLIF((SELECT auth.jwt() -> 'app_metadata' ->> 'tenant_id'), '')
        )
    )
)
WITH CHECK (
    (SELECT auth.uid()) IS NOT NULL
    AND (
        (SELECT auth.jwt() -> 'app_metadata' ->> 'role') = 'it_admin'
        OR EXISTS (
            SELECT 1 FROM public.customers AS account_customer
            WHERE account_customer.id = accounts.customer_id
              AND account_customer.tenant_id = NULLIF((SELECT auth.jwt() -> 'app_metadata' ->> 'tenant_id'), '')
        )
    )
);
