CREATE OR REPLACE FUNCTION public.get_rolling_tx_volume(p_account_id uuid, p_hours integer, p_tx_type text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

DECLARE

  v_sum NUMERIC;

BEGIN

  -- We sum the amounts for this account, filtered by type and the lookback window

  SELECT COALESCE(SUM(amount), 0)

  INTO v_sum

  FROM transactions

  WHERE account_id = p_account_id

    AND transaction_type = p_tx_type

    AND transaction_timestamp > NOW() - (p_hours || ' hours')::INTERVAL;

    

  RETURN v_sum;

END;

$function$