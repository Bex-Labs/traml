CREATE OR REPLACE FUNCTION public.evaluate_dormant_account_activity(

    p_account_id UUID,
    p_current_transaction_timestamp TIMESTAMPTZ,
    p_threshold_days INTEGER,
    p_rule_name TEXT

)

RETURNS TEXT

LANGUAGE plpgsql

SET search_path TO 'public'

AS $function$

DECLARE

    v_last_activity TIMESTAMPTZ;

    v_inactive_days INTEGER;

BEGIN

    -- Retrieve the previous account activity

    v_last_activity := get_last_account_activity(

        p_account_id,
        p_current_transaction_timestamp

    );

    -- No previous activity means this is the first transaction

    IF v_last_activity IS NULL THEN
        RETURN NULL;
    END IF;

    -- Calculate inactive days

    v_inactive_days := FLOOR(

        EXTRACT(
            EPOCH FROM (
                p_current_transaction_timestamp - v_last_activity
            )
        ) / 86400

    );

    -- Evaluate dormancy

    IF v_inactive_days >= p_threshold_days THEN

        RETURN format(

            'Dormant Account Activity detected. Rule "%s" triggered. Account was inactive for %s day(s).',

            p_rule_name,
            v_inactive_days

        );

    END IF;

    RETURN NULL;

END;

$function$;