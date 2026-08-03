CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$

  DECLARE

    claims jsonb;

    user_role text;

    user_tenant uuid;

  BEGIN

    -- Try to find your profile

    SELECT role, tenant_id INTO user_role, user_tenant

    FROM public.user_profiles

    WHERE id = (event->'claims'->>'sub')::uuid;



    claims := event->'claims';



    IF user_role IS NOT NULL THEN

      -- Success! Inject real data

      claims := jsonb_set(claims, '{app_metadata, role}', to_jsonb(user_role));

      claims := jsonb_set(claims, '{app_metadata, tenant_id}', to_jsonb(user_tenant));

    ELSE

      -- DIAGNOSTIC FAILURE FLAG

      claims := jsonb_set(claims, '{app_metadata, role}', '"DEBUG_PROFILE_NOT_FOUND"');

    END IF;



    event := jsonb_set(event, '{claims}', claims);

    RETURN event;

  END;

$function$