CREATE OR REPLACE FUNCTION public.update_str_timestamp()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$

BEGIN

    NEW.updated_at = NOW();

    RETURN NEW;

END;

$function$