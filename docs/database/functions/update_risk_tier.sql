CREATE OR REPLACE FUNCTION public.update_risk_tier(p_id uuid, p_score integer, p_tier text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

BEGIN

    UPDATE public.customers

    SET risk_score = p_score, 

        risk_tier = p_tier::risk_tier -- This converts the text to your Enum type safely

    WHERE id = p_id;

END;

$function$