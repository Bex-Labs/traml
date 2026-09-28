-- =====================================================
-- AML-0024
-- Integrate Risk Engine
-- =====================================================

---------------------------------------------------------
-- 1. Ensure Rule Names Are Unique
---------------------------------------------------------

ALTER TABLE public.aml_rules
ADD CONSTRAINT aml_rules_rule_name_key
UNIQUE (rule_name);

---------------------------------------------------------
-- 2. Integrate Risk Engine into Alert Creation
---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_alert(

    p_customer_id UUID,
    p_rule_name TEXT,
    p_severity TEXT,
    p_details TEXT

)

RETURNS VOID

LANGUAGE plpgsql

SET search_path TO public

AS $$

DECLARE

    v_rule_id UUID;

BEGIN

    -----------------------------------------------------
    -- Persist Alert
    -----------------------------------------------------

    INSERT INTO public.alerts (

        alert_ref,
        customer_id,
        rule_triggered,
        severity,
        status,
        details

    )

    VALUES (

        'ALT-' || UPPER(SUBSTRING(gen_random_uuid()::TEXT, 1, 6)),
        p_customer_id,
        p_rule_name,
        p_severity,
        'UNASSIGNED',
        p_details

    );

    -----------------------------------------------------
    -- Resolve AML Rule
    -----------------------------------------------------

    SELECT id
    INTO v_rule_id
    FROM public.aml_rules
    WHERE rule_name = p_rule_name;

    IF NOT FOUND THEN

        RAISE EXCEPTION
            'AML rule "%" not found.',
            p_rule_name;

    END IF;

    -----------------------------------------------------
    -- Update Customer Risk
    -----------------------------------------------------

    PERFORM public.update_customer_risk(

        p_customer_id,
        v_rule_id,
        'AML_ALERT: ' || p_rule_name

    );

END;

$$;