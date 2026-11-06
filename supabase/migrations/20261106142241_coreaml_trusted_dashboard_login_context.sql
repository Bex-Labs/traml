CREATE FUNCTION coreaml_private.dashboard_staff(p_roles text[]) RETURNS public.user_profiles LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.user_id=auth.uid() AND s.id::text=auth.jwt()->>'session_id') THEN RAISE EXCEPTION 'Active authentication session required' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid();
 IF NOT FOUND OR p.is_active IS NOT TRUE OR NOT p.role=ANY(p_roles) OR p.role IS DISTINCT FROM auth.jwt()->'app_metadata'->>'role' OR p.tenant_id IS DISTINCT FROM nullif(auth.jwt()->'app_metadata'->>'tenant_id','') OR (p.role<>'it_admin' AND nullif(p.tenant_id,'') IS NULL) OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=p.id AND u.raw_app_meta_data->>'role'=p.role AND nullif(u.raw_app_meta_data->>'tenant_id','') IS NOT DISTINCT FROM p.tenant_id AND (u.banned_until IS NULL OR u.banned_until<=now())) THEN RAISE EXCEPTION 'Active matching trusted staff profile required' USING ERRCODE='42501';END IF;
 RETURN p;END $$;
CREATE FUNCTION public.coreaml_dashboard_context() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN p:=coreaml_private.dashboard_staff(ARRAY['it_admin','head_of_compliance','compliance_officer','bank_manager','branch_manager','bankmanager','teller','sales_rep']);
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'role',p.role,'name',coalesce(p.full_name,'Staff member'),'server_time',now());END $$;


REVOKE ALL ON FUNCTION coreaml_private.dashboard_staff(text[]) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.coreaml_dashboard_context() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_dashboard_context() TO authenticated;
NOTIFY pgrst,'reload schema';
