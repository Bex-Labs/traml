CREATE OR REPLACE FUNCTION public.screen_transactions_for_sanctions()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$

DECLARE

    target_customer_id UUID;

    sanction_match TEXT;

BEGIN

    -- Find the customer associated with this account

    SELECT customer_id INTO target_customer_id FROM public.accounts WHERE id = NEW.account_id;



    -- Check if the counterparty or the narration contains any name from our watchlist

    SELECT entity_name INTO sanction_match 

    FROM public.sanctions_watchlist 

    WHERE NEW.counterparty_name ILIKE '%' || entity_name || '%' 

       OR NEW.narration ILIKE '%' || entity_name || '%'

    LIMIT 1;



    -- If a match is found, spawn a Sanctions Alert

    IF sanction_match IS NOT NULL THEN

        INSERT INTO public.alerts (alert_ref, customer_id, rule_triggered, severity, status, details)

        VALUES (

            'SNC-' || UPPER(SUBSTRING(MD5(RANDOM()::TEXT) FROM 1 FOR 6)), 

            target_customer_id,

            'Sanctions / Watchlist Match', 

            'CRITICAL', 

            'UNASSIGNED',

            'Direct match found for restricted entity: ' || sanction_match

        );

    END IF;

    

    RETURN NEW;

END;

$function$