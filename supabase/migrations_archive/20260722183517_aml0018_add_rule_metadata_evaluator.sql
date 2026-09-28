CREATE OR REPLACE FUNCTION public.evaluate_rule_metadata(

    p_rule_metadata JSONB,
    p_transaction_type TEXT,
    p_channel TEXT,
    p_currency TEXT

)

RETURNS BOOLEAN

LANGUAGE plpgsql

SET search_path TO 'public'

AS $function$

DECLARE

    v_transaction_type TEXT;

BEGIN

    -- No metadata means no filtering

    IF p_rule_metadata IS NULL
       OR p_rule_metadata = '{}'::JSONB THEN
        RETURN TRUE;
    END IF;

    -----------------------------------------------------------------
    -- Transaction Type
    -----------------------------------------------------------------

    v_transaction_type := UPPER(
        COALESCE(
            p_rule_metadata ->> 'transaction_type',
            'BOTH'
        )
    );

    IF v_transaction_type <> 'BOTH'
       AND UPPER(p_transaction_type) <> v_transaction_type THEN
        RETURN FALSE;
    END IF;

    -----------------------------------------------------------------
    -- Channels (optional)
    -----------------------------------------------------------------

    IF p_rule_metadata ? 'channels'
       AND jsonb_array_length(p_rule_metadata -> 'channels') > 0 THEN

        IF NOT (
            p_rule_metadata -> 'channels'
            ? p_channel
        ) THEN
            RETURN FALSE;
        END IF;

    END IF;

    -----------------------------------------------------------------
    -- Currencies (optional)
    -----------------------------------------------------------------

    IF p_rule_metadata ? 'currencies'
       AND jsonb_array_length(p_rule_metadata -> 'currencies') > 0 THEN

        IF NOT (
            p_rule_metadata -> 'currencies'
            ? p_currency
        ) THEN
            RETURN FALSE;
        END IF;

    END IF;

    RETURN TRUE;

END;

$function$;