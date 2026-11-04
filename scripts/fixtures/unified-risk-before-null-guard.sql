CREATE OR REPLACE FUNCTION public.unified_risk_scoring()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
$function$;
