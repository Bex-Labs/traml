-- =====================================================
-- AML-0023
-- Risk Calculation Engine
-- =====================================================

---------------------------------------------------------
-- Update Customer Risk
---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.update_customer_risk(

    p_customer_id UUID,
    p_rule_id UUID,
    p_change_reason TEXT,
    p_changed_by UUID DEFAULT NULL

)

RETURNS INTEGER

LANGUAGE plpgsql

AS $$

DECLARE

    v_previous_score INTEGER := 0;
    v_new_score INTEGER;

    v_previous_tier TEXT := 'LOW';
    v_new_tier TEXT;

    v_rule_weight INTEGER;
    v_rule_name TEXT;

BEGIN

    -----------------------------------------------------
    -- Load Rule
    -----------------------------------------------------

    SELECT
        risk_weight,
        rule_name
    INTO
        v_rule_weight,
        v_rule_name
    FROM public.aml_rules
    WHERE id = p_rule_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'AML rule % not found',
            p_rule_id;
    END IF;

    -----------------------------------------------------
    -- Existing Profile
    -----------------------------------------------------

    SELECT
        total_score,
        risk_level
    INTO
        v_previous_score,
        v_previous_tier
    FROM public.customer_risk_profiles
    WHERE customer_id = p_customer_id;

    IF NOT FOUND THEN

        v_previous_score := 0;
        v_previous_tier := 'LOW';

    END IF;

    -----------------------------------------------------
    -- Calculate Score
    -----------------------------------------------------

    v_new_score := v_previous_score + v_rule_weight;

    -----------------------------------------------------
    -- Calculate Tier
    -----------------------------------------------------

    v_new_tier := CASE

        WHEN v_new_score >= 150 THEN 'CRITICAL'

        WHEN v_new_score >= 100 THEN 'HIGH'

        WHEN v_new_score >= 50 THEN 'MEDIUM'

        ELSE 'LOW'

    END;

    -----------------------------------------------------
    -- Upsert Risk Profile
    -----------------------------------------------------

    INSERT INTO public.customer_risk_profiles (

        customer_id,
        total_score,
        risk_level

    )

    VALUES (

        p_customer_id,
        v_new_score,
        v_new_tier

    )

    ON CONFLICT (customer_id)

    DO UPDATE

    SET

        total_score = EXCLUDED.total_score,
        risk_level = EXCLUDED.risk_level,
        updated_at = now();

    -----------------------------------------------------
    -- Audit History
    -----------------------------------------------------

    INSERT INTO public.risk_score_history (

        customer_id,
        previous_score,
        new_score,
        previous_tier,
        new_tier,
        change_reason,
        changed_by

    )

    VALUES (

        p_customer_id,
        v_previous_score,
        v_new_score,
        v_previous_tier,
        v_new_tier,
        p_change_reason,
        p_changed_by

    );

    RETURN v_new_score;

END;

$$;