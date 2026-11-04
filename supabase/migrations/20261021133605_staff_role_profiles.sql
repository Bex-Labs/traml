-- Draft local remediation. Keep existing role spellings; capabilities are not
-- inferred from a renamed role. Custom-role capability design remains separate.
ALTER TABLE public.user_profiles DROP CONSTRAINT IF EXISTS user_profiles_role_check;
ALTER TABLE public.user_profiles ADD CONSTRAINT user_profiles_role_check CHECK (
  role IN ('compliance_officer','bank_manager','head_of_compliance','it_admin',
           'branch_manager','teller','sales_rep','bankmanager')
);

-- This is an internal Auth-table trigger, not a callable public RPC. A definer
-- is required to maintain public profiles when the Auth service writes users.
CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  staff_role text := NEW.raw_app_meta_data->>'role';
  staff_bank text := NULLIF(NEW.raw_app_meta_data->>'tenant_id','');
  display_name text := COALESCE(NEW.raw_user_meta_data->>'full_name',NEW.email,'System User');
BEGIN
  IF staff_role IS NULL OR staff_role NOT IN (
    'compliance_officer','bank_manager','head_of_compliance','it_admin',
    'branch_manager','teller','sales_rep','bankmanager'
  ) THEN
    -- An unprovisioned signup must not obtain a staff role from user_metadata.
    IF TG_OP = 'UPDATE' AND OLD.raw_app_meta_data->>'role' IS DISTINCT FROM staff_role THEN
      UPDATE public.user_profiles SET is_active=false WHERE id=NEW.id;
      UPDATE public.profiles SET role=NULL,tenant_id=NULL WHERE id=NEW.id;
    END IF;
    RETURN NEW;
  END IF;
  IF (staff_bank IS NULL AND staff_role <> 'it_admin') OR
     (staff_bank IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.banks WHERE id=staff_bank)) THEN
    RAISE EXCEPTION 'Staff role requires a valid assigned bank' USING ERRCODE='23514';
  END IF;
  INSERT INTO public.profiles(id,email,role,tenant_id,full_name)
  VALUES(NEW.id,NEW.email,staff_role,staff_bank,display_name)
  ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,role=EXCLUDED.role,
    tenant_id=EXCLUDED.tenant_id,full_name=EXCLUDED.full_name;
  INSERT INTO public.user_profiles(id,tenant_id,role,full_name,is_active)
  VALUES(NEW.id,staff_bank,staff_role,display_name,
    NEW.banned_until IS NULL OR NEW.banned_until <= now())
  ON CONFLICT(id) DO UPDATE SET tenant_id=EXCLUDED.tenant_id,role=EXCLUDED.role,
    full_name=EXCLUDED.full_name; -- Preserve existing explicit deactivation.
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC,anon,authenticated;

DROP TRIGGER IF EXISTS coreaml_sync_staff_profiles ON auth.users;
CREATE TRIGGER coreaml_sync_staff_profiles
AFTER INSERT OR UPDATE OF raw_app_meta_data,raw_user_meta_data,email ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Backfill only roles in trusted Auth app_metadata, with an existing bank.
INSERT INTO public.profiles(id,email,role,tenant_id,full_name)
SELECT u.id,u.email,u.raw_app_meta_data->>'role',NULLIF(u.raw_app_meta_data->>'tenant_id',''),
       COALESCE(u.raw_user_meta_data->>'full_name',u.email,'System User')
FROM auth.users u
WHERE u.raw_app_meta_data->>'role' IN ('compliance_officer','bank_manager','head_of_compliance','it_admin','branch_manager','teller','sales_rep','bankmanager')
AND (EXISTS(SELECT 1 FROM public.banks b WHERE b.id=u.raw_app_meta_data->>'tenant_id')
  OR (u.raw_app_meta_data->>'role'='it_admin' AND NULLIF(u.raw_app_meta_data->>'tenant_id','') IS NULL))
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,role=EXCLUDED.role,
  tenant_id=EXCLUDED.tenant_id,full_name=EXCLUDED.full_name;

INSERT INTO public.user_profiles(id,tenant_id,role,full_name,is_active)
SELECT u.id,NULLIF(u.raw_app_meta_data->>'tenant_id',''),u.raw_app_meta_data->>'role',
       COALESCE(u.raw_user_meta_data->>'full_name',u.email,'System User'),
       u.banned_until IS NULL OR u.banned_until <= now()
FROM auth.users u
WHERE u.raw_app_meta_data->>'role' IN ('compliance_officer','bank_manager','head_of_compliance','it_admin','branch_manager','teller','sales_rep','bankmanager')
AND (EXISTS(SELECT 1 FROM public.banks b WHERE b.id=u.raw_app_meta_data->>'tenant_id')
  OR (u.raw_app_meta_data->>'role'='it_admin' AND NULLIF(u.raw_app_meta_data->>'tenant_id','') IS NULL))
ON CONFLICT(id) DO UPDATE SET tenant_id=EXCLUDED.tenant_id,role=EXCLUDED.role,
  full_name=EXCLUDED.full_name;

-- Profile directories are also bank-scoped. Users retain their own profile for
-- login/bootstrap; the existing IT-admin management policy remains effective.
DROP POLICY IF EXISTS coreaml_profiles_bank_boundary ON public.profiles;
CREATE POLICY coreaml_profiles_bank_boundary ON public.profiles AS RESTRICTIVE
FOR SELECT TO PUBLIC USING (
  (SELECT auth.uid()) IS NOT NULL AND (
    id=(SELECT auth.uid())
    OR (SELECT auth.jwt()->'app_metadata'->>'role')='it_admin'
    OR tenant_id=NULLIF((SELECT auth.jwt()->'app_metadata'->>'tenant_id'),'')
  )
);
DROP POLICY IF EXISTS coreaml_staff_directory_bank_boundary ON public.user_profiles;
CREATE POLICY coreaml_staff_directory_bank_boundary ON public.user_profiles AS RESTRICTIVE
FOR ALL TO PUBLIC USING (
  (SELECT auth.uid()) IS NOT NULL AND (
    id=(SELECT auth.uid())
    OR (SELECT auth.jwt()->'app_metadata'->>'role')='it_admin'
    OR tenant_id=NULLIF((SELECT auth.jwt()->'app_metadata'->>'tenant_id'),'')
  )
) WITH CHECK (
  (SELECT auth.uid()) IS NOT NULL
  AND (SELECT auth.jwt()->'app_metadata'->>'role')='it_admin'
);

-- Banks have text IDs in the schema. Do not cast them to UUID in the hook.
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  claims jsonb := event->'claims';
  metadata jsonb := COALESCE(event->'claims'->'app_metadata','{}'::jsonb);
  staff_role text;
  staff_bank text;
BEGIN
  SELECT role,tenant_id INTO staff_role,staff_bank FROM public.user_profiles
  WHERE id=(event->>'user_id')::uuid AND is_active=true;
  IF staff_role IS NULL THEN
    metadata := metadata || jsonb_build_object('role','access_disabled','tenant_id',NULL);
  ELSE
    metadata := metadata || jsonb_build_object('role',staff_role,'tenant_id',staff_bank);
  END IF;
  claims := jsonb_set(claims,'{app_metadata}',metadata,true);
  RETURN jsonb_set(event,'{claims}',claims,true);
END $$;
REVOKE ALL ON FUNCTION public.custom_access_token_hook(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;
