-- =====================================================
-- AML-0025
-- Dynamic Risk-Based Alert Severity
-- =====================================================

---------------------------------------------------------
-- Severity -> Rank
---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.severity_rank(
    p_severity TEXT
)
RETURNS INTEGER
LANGUAGE SQL
IMMUTABLE
AS $$
SELECT
CASE UPPER(TRIM($1))
    WHEN 'LOW' THEN 1
    WHEN 'MEDIUM' THEN 2
    WHEN 'HIGH' THEN 3
    WHEN 'CRITICAL' THEN 4
    ELSE NULL
END;
$$;

---------------------------------------------------------
-- Rank -> Severity
---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.severity_from_rank(
    p_rank INTEGER
)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
SELECT
CASE
    WHEN $1 <= 1 THEN 'LOW'
    WHEN $1 = 2 THEN 'MEDIUM'
    WHEN $1 = 3 THEN 'HIGH'
    ELSE 'CRITICAL'
END;
$$;

---------------------------------------------------------
-- Risk Escalation Offset
---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.risk_escalation_offset(
    p_risk_level TEXT
)
RETURNS INTEGER
LANGUAGE SQL
IMMUTABLE
AS $$
SELECT
CASE UPPER(TRIM(COALESCE($1,'LOW')))
    WHEN 'HIGH' THEN 1
    WHEN 'CRITICAL' THEN 2
    ELSE 0
END;
$$;

---------------------------------------------------------
-- Final Severity Calculator
---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.calculate_alert_severity(
    p_rule_severity TEXT,
    p_customer_risk TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE

    v_rank INTEGER;
    v_offset INTEGER;

BEGIN

    v_rank := public.severity_rank(p_rule_severity);

    IF v_rank IS NULL THEN
        RAISE EXCEPTION
            'Invalid alert severity: %',
            p_rule_severity;
    END IF;

    v_offset :=
        public.risk_escalation_offset(
            p_customer_risk
        );

    RETURN public.severity_from_rank(
        LEAST(v_rank + v_offset,4)
    );

END;
$$;

---------------------------------------------------------
-- Alert Creation
---------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_alert(

    p_customer_id UUID,
    p_rule_name TEXT,
    p_severity TEXT,
    p_details TEXT

)

RETURNS VOID

LANGUAGE plpgsql

SET search_path = public

AS $$

DECLARE

    v_rule_id UUID;
    v_customer_risk TEXT := 'LOW';
    v_final_severity TEXT;

BEGIN

    -----------------------------------------------------
    -- Resolve Rule
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
    -- Existing Customer Risk
    -----------------------------------------------------

    SELECT risk_level

    INTO v_customer_risk

    FROM public.customer_risk_profiles

    WHERE customer_id = p_customer_id;

    -----------------------------------------------------
    -- Escalate Severity
    -----------------------------------------------------

    v_final_severity :=
        public.calculate_alert_severity(
            p_severity,
            COALESCE(v_customer_risk,'LOW')
        );

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

        'ALT-' || UPPER(SUBSTRING(gen_random_uuid()::TEXT,1,6)),
        p_customer_id,
        p_rule_name,
        v_final_severity,
        'UNASSIGNED',
        p_details

    );

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