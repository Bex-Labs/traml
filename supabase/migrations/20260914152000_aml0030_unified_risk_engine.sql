-- Phase 3: Unified Risk Scoring Engine

-- 1. Drop the redundant table and conflicting triggers
DROP TRIGGER IF EXISTS trigger_recalculate_risk ON public.alerts;
DROP TRIGGER IF EXISTS trigger_risk_scoring ON public.alerts;
DROP FUNCTION IF EXISTS public.recalculate_customer_risk();
DROP FUNCTION IF EXISTS public.update_customer_risk_score();
DROP TABLE IF EXISTS public.customer_risk_profiles CASCADE;

-- 2. Create the unified risk calculation function
CREATE OR REPLACE FUNCTION public.unified_risk_scoring() RETURNS trigger
LANGUAGE plpgsql
SET search_path TO public
AS $$
DECLARE
    v_base_score NUMERIC := 10.00;
    v_critical_count INTEGER;
    v_high_count INTEGER;
    v_medium_count INTEGER;
    v_calculated_score NUMERIC;
    v_calculated_tier TEXT;
    v_old_score NUMERIC;
    v_old_tier TEXT;
BEGIN
    -- Fetch the current authoritative score from the customers table
    SELECT risk_score, risk_tier::TEXT INTO v_old_score, v_old_tier
    FROM public.customers 
    WHERE id = NEW.customer_id;

    -- Aggregate all alerts to determine the true penalty
    SELECT 
        COUNT(*) FILTER (WHERE severity = 'CRITICAL'),
        COUNT(*) FILTER (WHERE severity = 'HIGH'),
        COUNT(*) FILTER (WHERE severity = 'MEDIUM')
    INTO v_critical_count, v_high_count, v_medium_count
    FROM public.alerts 
    WHERE customer_id = NEW.customer_id 
      AND status != 'DISMISSED';

    -- Apply weighted penalties and cap at 100
    v_calculated_score := LEAST(100.00, v_base_score + (v_critical_count * 40) + (v_high_count * 20) + (v_medium_count * 10));

    -- Map score to the risk_tier ENUM
    IF v_calculated_score >= 85 THEN v_calculated_tier := 'VERY_HIGH';
    ELSIF v_calculated_score >= 60 THEN v_calculated_tier := 'HIGH';
    ELSIF v_calculated_score >= 35 THEN v_calculated_tier := 'MEDIUM';
    ELSE v_calculated_tier := 'LOW';
    END IF;

    -- Only execute an update and log if the score actually changed
    IF v_old_score IS DISTINCT FROM v_calculated_score OR v_old_tier IS DISTINCT FROM v_calculated_tier THEN
        UPDATE public.customers
        SET risk_score = v_calculated_score, 
            risk_tier = v_calculated_tier::public.risk_tier,
            updated_at = NOW()
        WHERE id = NEW.customer_id;

        INSERT INTO public.risk_score_history (
            customer_id, previous_score, new_score, previous_tier, new_tier, change_reason
        ) VALUES (
            NEW.customer_id, 
            v_old_score::integer, 
            v_calculated_score::integer, 
            v_old_tier, 
            v_calculated_tier, 
            'Unified Engine Recalculation: Triggered by alert ' || NEW.alert_ref
        );
    END IF;

    RETURN NEW;
END;
$$;

-- 3. Attach the single unified trigger to the alerts table
CREATE TRIGGER trigger_unified_risk_scoring
AFTER INSERT OR UPDATE OF severity, status ON public.alerts
FOR EACH ROW
EXECUTE FUNCTION public.unified_risk_scoring();

-- 4. Neutralize the legacy update function so it doesn't write to the deleted profiles table
CREATE OR REPLACE FUNCTION public.update_customer_risk(
    p_customer_id uuid, p_rule_id uuid, p_change_reason text, p_changed_by uuid DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_score INTEGER;
BEGIN
    -- The unified trigger on the alerts table now handles all risk calculations.
    -- This function remains to prevent breaking the existing create_alert signature, 
    -- but simply returns the current authoritative score.
    SELECT risk_score::integer INTO v_current_score FROM public.customers WHERE id = p_customer_id;
    RETURN COALESCE(v_current_score, 10);
END;
$$;