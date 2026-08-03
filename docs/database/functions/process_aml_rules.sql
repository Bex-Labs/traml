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
    alert_severity TEXT;

BEGIN

    -- Identify the account and customer associated with the transaction

    SELECT *
    INTO account_record
    FROM public.accounts
    WHERE id = NEW.account_id;

    SELECT *
    INTO customer_record
    FROM public.customers
    WHERE id = account_record.customer_id;


    -- Evaluate all active transaction rules for the customer's tenant

    FOR active_rule IN

        SELECT *
        FROM public.aml_rules
        WHERE tenant_id = customer_record.tenant_id
          AND status = 'ACTIVE'
          AND target_entity = 'TRANSACTION'

    LOOP

        -- Reset evaluator output before processing each rule

        alert_text := NULL;
        alert_severity := 'HIGH';

        -- Dispatch to the appropriate evaluator

        CASE active_rule.condition_type

            WHEN 'AMOUNT_ABOVE' THEN

                alert_text := evaluate_amount_above(

                    NEW.amount,
                    active_rule.threshold_value,
                    active_rule.rule_name

                );

                alert_severity := 'CRITICAL';


            WHEN 'STRUCTURING_PATTERN' THEN

                alert_text := evaluate_structuring(

                    NEW.account_id,
                    NEW.amount,
                    active_rule.threshold_value,
                    active_rule.time_window_hours,
                    active_rule.rule_name

                );

                alert_severity := 'HIGH';


            WHEN 'VELOCITY_COUNT' THEN

                alert_text := evaluate_velocity_count(

                    NEW.account_id,
                    active_rule.threshold_value,
                    active_rule.time_window_hours,
                    active_rule.rule_name

                );

                alert_severity := 'MEDIUM';

            WHEN 'DORMANT_ACCOUNT_ACTIVITY' THEN

                alert_text := evaluate_dormant_account_activity(

                    NEW.account_id,
                    NEW.transaction_timestamp,
                    active_rule.threshold_value::INTEGER,
                    active_rule.rule_name

                );

                alert_severity := 'HIGH';
            
            -- Future evaluators

            WHEN 'STATIC_THRESHOLD' THEN
                NULL;

            WHEN 'BEHAVIORAL_VELOCITY' THEN
                NULL;

            ELSE
                NULL;

        END CASE;


        IF alert_text IS NOT NULL THEN

            PERFORM create_alert(

                customer_record.id,
                active_rule.rule_name,
                alert_severity,
                alert_text

            );

        END IF;

    END LOOP;


    RETURN NEW;

END;

$function$;