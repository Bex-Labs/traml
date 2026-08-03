CREATE OR REPLACE FUNCTION public.audit_safe_login_func()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

BEGIN

    -- We only want to log when the user ACTUALLY logs in (when the timestamp changes)

    IF OLD.last_sign_in_at IS DISTINCT FROM NEW.last_sign_in_at THEN

        INSERT INTO public.audit_logs (

            event_type,

            actor_id,

            target_id,

            details,

            tenant_id

        ) VALUES (

            'auth_login',

            NEW.id,

            NEW.id,

            jsonb_build_object('email', NEW.email, 'action', 'session_started'),

            CAST(NULLIF(NEW.raw_app_meta_data->>'tenant_id', '') AS UUID)

        );

    END IF;

    RETURN NEW;

END;

$function$
