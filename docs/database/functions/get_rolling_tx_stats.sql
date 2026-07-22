CREATE OR REPLACE FUNCTION public.get_rolling_tx_stats(p_account_id uuid, p_hours integer, p_tx_type text DEFAULT 'CREDIT'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

DECLARE

    result json;

BEGIN

    SELECT json_build_object(

        'total_volume', COALESCE(SUM(amount), 0),

        'tx_count', COUNT(id)

    ) INTO result

    FROM public.transactions

    WHERE account_id = p_account_id

      AND transaction_type::text = p_tx_type  -- ðŸš¨ CRITICAL FIX: The explicit text cast

      AND transaction_timestamp >= NOW() - (p_hours || ' hours')::interval;

      

    RETURN result;

END;

$function$