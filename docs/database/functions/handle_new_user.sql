CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

BEGIN

  INSERT INTO public.profiles (id, email, role, tenant_id, full_name)

  VALUES (

    new.id,

    new.email,

    -- Safely extract the role and tenant from the token metadata injected by your invite function

    COALESCE(new.raw_app_meta_data->>'role', new.raw_user_meta_data->>'role', 'compliance_officer'),

    COALESCE(new.raw_app_meta_data->>'tenant_id', new.raw_user_meta_data->>'tenant_id', 'default'),

    COALESCE(new.raw_user_meta_data->>'full_name', 'System User')

  )

  -- If the profile already exists somehow, update it to ensure it matches Auth

  ON CONFLICT (id) DO UPDATE

  SET 

    role = EXCLUDED.role,

    tenant_id = EXCLUDED.tenant_id;

  RETURN new;

END;

$function$