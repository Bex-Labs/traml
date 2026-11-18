CREATE FUNCTION coreaml_private.compliance_mfa_satisfied()
RETURNS boolean LANGUAGE sql STABLE SET search_path='' AS $$
    SELECT coalesce(auth.jwt()->'app_metadata'->>'role','') NOT IN ('compliance_officer','head_of_compliance')
        OR coalesce(auth.jwt()->>'aal','')='aal2';
$$;
REVOKE ALL ON FUNCTION coreaml_private.compliance_mfa_satisfied()
    FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION coreaml_private.compliance_mfa_satisfied() TO authenticated;

CREATE FUNCTION public.coreaml_require_compliance_mfa()
RETURNS void LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
BEGIN
    IF current_user='authenticated' AND NOT coreaml_private.compliance_mfa_satisfied() THEN
        RAISE insufficient_privilege USING MESSAGE='Authenticator verification required. Sign in again to continue.';
    END IF;
END
$$;
REVOKE ALL ON FUNCTION public.coreaml_require_compliance_mfa() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_require_compliance_mfa() TO anon, authenticated, service_role;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_db_role_setting s
        CROSS JOIN LATERAL unnest(s.setconfig) AS setting(value)
        WHERE s.setrole='authenticator'::regrole
          AND s.setdatabase IN (0,(SELECT oid FROM pg_catalog.pg_database WHERE datname=current_database()))
          AND setting.value LIKE 'pgrst.db_pre_request=%'
          AND setting.value <> 'pgrst.db_pre_request=public.coreaml_require_compliance_mfa'
    ) THEN
        RAISE EXCEPTION 'An existing PostgREST pre-request hook must be combined with the CoreAML MFA check';
    END IF;
END
$$;
ALTER ROLE authenticator SET pgrst.db_pre_request = 'public.coreaml_require_compliance_mfa';

CREATE POLICY coreaml_compliance_storage_mfa ON storage.objects
    AS RESTRICTIVE FOR ALL TO authenticated
    USING ((SELECT coreaml_private.compliance_mfa_satisfied()))
    WITH CHECK ((SELECT coreaml_private.compliance_mfa_satisfied()));

INSERT INTO storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
VALUES ('staff-profile-photos','staff-profile-photos',false,2097152,ARRAY['image/jpeg','image/png','image/webp']);

CREATE POLICY coreaml_staff_profile_photo_owner ON storage.objects
    AS RESTRICTIVE FOR ALL TO authenticated
    USING (bucket_id <> 'staff-profile-photos' OR (
        name=(SELECT auth.uid())::text
        AND (SELECT auth.jwt()->>'aal')='aal2'
        AND (SELECT auth.jwt()->'app_metadata'->>'role') IN ('compliance_officer','head_of_compliance')
    ))
    WITH CHECK (bucket_id <> 'staff-profile-photos' OR (
        name=(SELECT auth.uid())::text
        AND (SELECT auth.jwt()->>'aal')='aal2'
        AND (SELECT auth.jwt()->'app_metadata'->>'role') IN ('compliance_officer','head_of_compliance')
    ));

CREATE POLICY coreaml_staff_profile_photo_access ON storage.objects
    FOR ALL TO authenticated
    USING (bucket_id='staff-profile-photos')
    WITH CHECK (bucket_id='staff-profile-photos');


-- Bank-wide reporting stays scoped even when both roles can open Settings.
CREATE POLICY coreaml_compliance_report_schedule_scope ON public.report_schedules
    AS RESTRICTIVE FOR ALL TO authenticated
    USING (
        (SELECT auth.jwt()->'app_metadata'->>'role')='head_of_compliance'
        AND tenant_id=(SELECT auth.jwt()->'app_metadata'->>'tenant_id')
        AND (SELECT auth.jwt()->>'aal')='aal2'
    )
    WITH CHECK (
        (SELECT auth.jwt()->'app_metadata'->>'role')='head_of_compliance'
        AND tenant_id=(SELECT auth.jwt()->'app_metadata'->>'tenant_id')
        AND configured_by=(SELECT auth.uid())
        AND (SELECT auth.jwt()->>'aal')='aal2'
    );

CREATE OR REPLACE FUNCTION coreaml_private.dashboard_business_access() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.user_id=auth.uid() AND s.id::text=auth.jwt()->>'session_id') THEN RETURN false;END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid();
 RETURN FOUND AND coreaml_private.compliance_mfa_satisfied() AND p.is_active IS TRUE AND nullif(p.tenant_id,'') IS NOT NULL AND EXISTS(SELECT 1 FROM auth.users u WHERE u.id=p.id AND u.raw_app_meta_data->>'role'=p.role AND nullif(u.raw_app_meta_data->>'tenant_id','') IS NOT DISTINCT FROM p.tenant_id AND (u.banned_until IS NULL OR u.banned_until<=now())) AND p.role IN ('head_of_compliance','compliance_officer','branch_manager','bankmanager','teller','sales_rep') AND p.role IS NOT DISTINCT FROM auth.jwt()->'app_metadata'->>'role' AND p.tenant_id IS NOT DISTINCT FROM auth.jwt()->'app_metadata'->>'tenant_id';END $$;
NOTIFY pgrst,'reload config';
NOTIFY pgrst,'reload schema';
