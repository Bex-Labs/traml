CREATE OR REPLACE FUNCTION public.update_customer_risk_score()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$

DECLARE

    total_alerts INT;

    calculated_score INT;

    calculated_tier TEXT;

BEGIN

    -- Count open/historical alerts for this specific customer

    SELECT COUNT(*) INTO total_alerts FROM public.alerts WHERE customer_id = NEW.customer_id;

    

    -- Formula: Base score 15 + (25 penalty points per alert). Capped at 99.

    calculated_score := LEAST(15 + (total_alerts * 25), 99);

    

    -- Matrix Mapping

    IF calculated_score >= 75 THEN

        calculated_tier := 'HIGH';

    ELSIF calculated_score >= 40 THEN

        calculated_tier := 'MEDIUM';

    ELSE

        calculated_tier := 'LOW';

    END IF;



    -- Instantly update the Customer 360 profile (Notice the ::risk_tier cast!)

    UPDATE public.customers 

    SET risk_score = calculated_score, risk_tier = calculated_tier::public.risk_tier

    WHERE id = NEW.customer_id;



    RETURN NEW;

END;

$function$
