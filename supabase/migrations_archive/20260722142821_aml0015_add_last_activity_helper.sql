CREATE OR REPLACE FUNCTION public.get_last_account_activity(

    p_account_id UUID,
    p_current_transaction_timestamp TIMESTAMPTZ

)

RETURNS TIMESTAMPTZ

LANGUAGE plpgsql

SET search_path TO 'public'

AS $function$

DECLARE

    v_last_activity TIMESTAMPTZ;

BEGIN

    SELECT
        MAX(transaction_timestamp)
    INTO
        v_last_activity
    FROM
        public.transactions
    WHERE
        account_id = p_account_id
        AND transaction_timestamp < p_current_transaction_timestamp;

    RETURN v_last_activity;

END;

$function$;