CREATE OR REPLACE FUNCTION public.recalculate_customer_risk()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$

DECLARE

    base_score INTEGER := 10;

    critical_count INTEGER;

    high_count INTEGER;

    calculated_score INTEGER;

    calculated_tier TEXT;

    old_score INTEGER;

    old_tier TEXT;

BEGIN

    -- Get the customer's current score before we change it (Explicitly cast to TEXT)

    SELECT risk_score, risk_tier::TEXT INTO old_score, old_tier 

    FROM public.customers 

    WHERE id = NEW.customer_id;

    

    -- Count how many bad things they've done

    SELECT count(*) INTO critical_count FROM public.alerts WHERE customer_id = NEW.customer_id AND severity = 'CRITICAL';

    SELECT count(*) INTO high_count FROM public.alerts WHERE customer_id = NEW.customer_id AND severity = 'HIGH';



    -- The Penalty Math: 40 points for Critical, 20 points for High

    calculated_score := base_score + (critical_count * 40) + (high_count * 20);

    IF calculated_score > 100 THEN calculated_score := 100; END IF;



    -- Map Score to Tier

    IF calculated_score >= 75 THEN calculated_tier := 'HIGH';

    ELSIF calculated_score >= 40 THEN calculated_tier := 'MEDIUM';

    ELSE calculated_tier := 'LOW';

    END IF;



    -- If the score actually changed, update the customer and log it

    IF old_score IS DISTINCT FROM calculated_score THEN

        -- Update the profile (Explicitly cast back to the custom ENUM type)

        UPDATE public.customers 

        SET risk_score = calculated_score, risk_tier = calculated_tier::public.risk_tier

        WHERE id = NEW.customer_id;



        -- Write the receipt to the ledger

        INSERT INTO public.risk_score_history (

            customer_id, previous_score, new_score, previous_tier, new_tier, change_reason

        ) VALUES (

            NEW.customer_id, old_score, calculated_score, old_tier, calculated_tier, 

            'System auto-recalculation triggered by new ' || NEW.severity || ' alert: ' || NEW.rule_triggered

        );

    END IF;



    RETURN NEW;

END;

$function$
