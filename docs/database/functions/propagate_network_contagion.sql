CREATE OR REPLACE FUNCTION public.propagate_network_contagion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

DECLARE

    target_cust_id UUID;

    counterparty RECORD;

BEGIN

    -- Only execute when a SAR moves to APPROVED or is submitted

    IF NEW.status IN ('PENDING_APPROVAL', 'APPROVED') THEN

        

        -- Identify the primary customer linked to this SAR

        SELECT customer_id INTO target_cust_id 

        FROM public.alerts 

        WHERE id = NEW.alert_id;



        IF target_cust_id IS NOT NULL THEN

            -- Find all distinct accounts that transacted with the target in the last 30 days

            FOR counterparty IN 

                SELECT DISTINCT c.id, c.risk_score, c.risk_tier, c.entity_name

                FROM public.transactions t

                JOIN public.accounts a ON (t.account_id = a.id)

                JOIN public.customers c ON (a.customer_id = c.id)

                WHERE c.id != target_cust_id

                  AND t.transaction_timestamp >= NOW() - INTERVAL '30 days'

                  -- Add logic here to match counterparty account references if stored in tx metadata

            LOOP

                -- Apply a +25 point Contagion Penalty (capped at 99)

                UPDATE public.customers

                SET risk_score = LEAST(99, COALESCE(risk_score, 10) + 25),

                    risk_tier = CASE 

                        WHEN LEAST(99, COALESCE(risk_score, 10) + 25) >= 75 THEN 'HIGH'

                        WHEN LEAST(99, COALESCE(risk_score, 10) + 25) >= 40 THEN 'MEDIUM'

                        ELSE 'LOW'

                    END

                WHERE id = counterparty.id;



                -- Record the automated contagion shift in the immutable risk ledger

                INSERT INTO public.risk_score_history (

                    customer_id, previous_score, new_score, previous_tier, new_tier, change_reason

                ) VALUES (

                    counterparty.id,

                    COALESCE(counterparty.risk_score, 10),

                    LEAST(99, COALESCE(counterparty.risk_score, 10) + 25),

                    COALESCE(counterparty.risk_tier, 'LOW'),