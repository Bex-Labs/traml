CREATE OR REPLACE FUNCTION public.evaluate_structuring(
    p_account_id UUID,
    p_amount NUMERIC,
    p_threshold NUMERIC,
    p_window_hours INTEGER,
    p_rule_name TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_stats JSON;
    v_total_volume NUMERIC;
    v_tx_count INTEGER;
BEGIN

    -- Get rolling statistics
    v_stats := get_rolling_tx_stats(
        p_account_id,
        p_window_hours,
        'CREDIT'
    );

    -- Extract values
    v_total_volume := COALESCE((v_stats ->> 'total_volume')::NUMERIC, 0);
    v_tx_count := COALESCE((v_stats ->> 'tx_count')::INTEGER, 0);

    -- Detect structuring
    IF p_amount < p_threshold
       AND v_total_volume >= p_threshold
       AND v_tx_count >= 2 THEN

        RETURN format(
            '%s: Structuring detected. %s transactions totaling %s within %s hours.',
            p_rule_name,
            v_tx_count,
            v_total_volume,
            p_window_hours
        );

    END IF;

    RETURN NULL;
END;
$$;