CREATE OR REPLACE FUNCTION public.log_user_login()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

BEGIN

  -- Only track if it's an actual login update

  IF OLD.last_sign_in_at IS DISTINCT FROM NEW.last_sign_in_at THEN

      

      -- FIREWALL: Wrap the insert in a TRY/CATCH block

      BEGIN

          INSERT INTO public.audit_logs (user_id, event_type, description, tenant_id)

          VALUES (

            NEW.id, 

            'USER_LOGIN', 

            'Secure system authentication successful.',

            CAST(NULLIF(NEW.raw_app_meta_data ->> 'tenant_id', '') AS uuid)

          );

      EXCEPTION WHEN OTHERS THEN

          -- If the insert fails (due to invalid UUID text, missing columns, etc.)

          -- Do absolutely nothing. Just swallow the error so the login succeeds.

      END;



  END IF;

  RETURN NEW;

END;

$function$