CREATE OR REPLACE FUNCTION public.process_aml_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$

DECLARE

    account_record RECORD;

    customer_record RECORD;

    active_rule RECORD;

    alert_text TEXT;

BEGIN

    -- 1. Identify the Customer moving the money

    SELECT * INTO account_record FROM public.accounts WHERE id = NEW.account_id;

    SELECT * INTO customer_record FROM public.customers WHERE id = account_record.customer_id;



    -- 2. Loop through all ACTIVE rules built by the Head of Compliance for this specific Bank

    FOR active_rule IN 

        SELECT * FROM public.aml_rules 

        WHERE tenant_id = customer_record.tenant_id 

        AND status = 'ACTIVE' 

        AND target_entity = 'TRANSACTION'

    LOOP

        

        -- EVALUATOR 1: AMOUNT_ABOVE Threshold

IF active_rule.condition_type = 'AMOUNT_ABOVE' THEN

    alert_text := evaluate_amount_above(
        NEW.amount,
        active_rule.threshold_value,
        active_rule.rule_name
    );

    IF alert_text IS NOT NULL THEN

        PERFORM create_alert(
            customer_record.id,
            active_rule.rule_name,
            'CRITICAL',
            alert_text
        );

    END IF;

END IF;


        -- (Future logic for VELOCITY_COUNT and STRUCTURING can be stacked here)



    END LOOP;



    RETURN NEW;

END;

$function$
