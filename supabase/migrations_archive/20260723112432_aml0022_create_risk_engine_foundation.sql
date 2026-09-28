-- =====================================================
-- AML-0022
-- Risk Engine Foundation
-- =====================================================

---------------------------------------------------------
-- 1. Extend AML Rules
---------------------------------------------------------

ALTER TABLE public.aml_rules
ADD COLUMN risk_weight INTEGER NOT NULL DEFAULT 0;

---------------------------------------------------------
-- 2. Customer Risk Profiles
---------------------------------------------------------

CREATE TABLE public.customer_risk_profiles (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    customer_id UUID NOT NULL
        REFERENCES public.customers(id)
        ON DELETE CASCADE,

    total_score INTEGER NOT NULL DEFAULT 0,

    risk_level TEXT NOT NULL
        DEFAULT 'LOW'
        CHECK (
            risk_level IN (
                'LOW',
                'MEDIUM',
                'HIGH',
                'CRITICAL'
            )
        ),

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT customer_risk_profiles_customer_id_key
        UNIQUE (customer_id)

);

---------------------------------------------------------
-- 3. Seed Initial Rule Weights
---------------------------------------------------------

UPDATE public.aml_rules
SET risk_weight =
CASE condition_type

    WHEN 'AMOUNT_ABOVE' THEN 40

    WHEN 'STRUCTURING_PATTERN' THEN 60

    WHEN 'VELOCITY_COUNT' THEN 20

    WHEN 'DORMANT_ACCOUNT_ACTIVITY' THEN 50

    ELSE 0

END;