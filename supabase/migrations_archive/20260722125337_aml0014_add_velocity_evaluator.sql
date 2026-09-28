CREATE OR REPLACE FUNCTION public.evaluate_velocity_count(

    p_account_id UUID,
    p_threshold NUMERIC,
    p_time_window_hours INTEGER,
    p_rule_name TEXT

)

RETURNS TEXT

LANGUAGE plpgsql

SET search_path TO 'public'

AS $function$

DECLARE

    rolling_stats JSONB;

    rolling_volume NUMERIC;
    rolling_count INTEGER;

BEGIN

    -- Retrieve rolling transaction statistics

    rolling_stats := get_rolling_tx_stats(

        p_account_id,
        p_time_window_hours,
        'CREDIT'

    );

    -- Extract returned values

    rolling_volume := COALESCE(
        (rolling_stats->>'total_volume')::NUMERIC,
        0
    );

    rolling_count := COALESCE(
        (rolling_stats->>'tx_count')::INTEGER,
        0
    );

    -- Evaluate transaction count

    IF rolling_count >= p_threshold THEN

        RETURN format(

            'Velocity Rule Triggered: "%s". %s credit transactions detected within the last %s hour(s).',

            p_rule_name,
            rolling_count,
            p_time_window_hours

        );

    END IF;

    RETURN NULL;

END;

$function$;