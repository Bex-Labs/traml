CREATE OR REPLACE FUNCTION public.log_user_logout()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

BEGIN

    -- Ensure we actually have an active user before logging

    IF auth.uid() IS NOT NULL THEN

        INSERT INTO public.audit_logs (

            event_type, 

            actor_id, 

            target_id, 

            details, 

            tenant_id

        ) VALUES (

            'auth_logout',

            auth.uid(),

            auth.uid(),

            jsonb_build_object('action', 'global_disconnect'),

            CAST(NULLIF(current_setting('request.jwt.claims', true)::jsonb->'app_metadata'->>'tenant_id', '') AS UUID)

        );

    END IF;

END;

$function$
