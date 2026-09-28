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
    v_channel TEXT;
    v_currency TEXT;

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

    v_channel := UPPER(COALESCE(p_channel,''));

    v_currency := UPPER(COALESCE(p_currency,''));

    IF v_transaction_type <> 'BOTH'
       AND UPPER(p_transaction_type) <> v_transaction_type THEN
        RETURN FALSE;
    END IF;

    -----------------------------------------------------------------
    -- Channels (optional)
    -----------------------------------------------------------------

    IF p_rule_metadata ? 'channels'
        AND jsonb_array_length(p_rule_metadata -> 'channels') > 0 THEN

        IF NOT EXISTS (

            SELECT 1
            FROM jsonb_array_elements_text(
                p_rule_metadata -> 'channels'
            ) AS c(channel)

            WHERE UPPER(channel) = v_channel

        ) THEN

            RETURN FALSE;

        END IF;

    END IF;

    -----------------------------------------------------------------
    -- Currencies (optional)
    -----------------------------------------------------------------

    IF p_rule_metadata ? 'currencies'
        AND jsonb_array_length(p_rule_metadata -> 'currencies') > 0 THEN

        IF NOT EXISTS (

            SELECT 1
            FROM jsonb_array_elements_text(
                p_rule_metadata -> 'currencies'
            ) AS c(currency)

            WHERE UPPER(currency) = v_currency

        ) THEN

            RETURN FALSE;

        END IF;

    END IF;

    RETURN TRUE;

END;

$function$;