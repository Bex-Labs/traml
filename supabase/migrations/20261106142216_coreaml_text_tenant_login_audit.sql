
DROP POLICY "Head of Compliance views own tenant logs" ON public.audit_logs;
DROP POLICY "Strict Tenant Audit Visibility" ON public.audit_logs;
ALTER TABLE public.audit_logs ALTER COLUMN tenant_id TYPE text USING tenant_id::text;
CREATE POLICY "Head of Compliance views own tenant logs" ON public.audit_logs FOR SELECT TO public USING(auth.jwt()->'app_metadata'->>'role'='head_of_compliance' AND tenant_id=NULLIF(auth.jwt()->'app_metadata'->>'tenant_id',''));
CREATE POLICY "Strict Tenant Audit Visibility" ON public.audit_logs FOR SELECT TO public USING(auth.jwt()->'app_metadata'->>'role'='it_admin' OR tenant_id=NULLIF(auth.jwt()->'app_metadata'->>'tenant_id',''));
CREATE OR REPLACE FUNCTION public.audit_safe_login_func() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF OLD.last_sign_in_at IS DISTINCT FROM NEW.last_sign_in_at THEN
 INSERT INTO public.audit_logs(event_type,actor_id,target_id,details,tenant_id)
 VALUES('auth_login',NEW.id,NEW.id,jsonb_build_object('action','session_started'),NULLIF(NEW.raw_app_meta_data->>'tenant_id',''));
 END IF;
 RETURN NEW;
END $fn$;
-- The second legacy trigger remains attached, but the canonical trigger above
-- is the single writer. Previously this function silently discarded every error.
CREATE OR REPLACE FUNCTION public.log_user_login() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN RETURN NEW; END $fn$;
CREATE OR REPLACE FUNCTION public.log_user_logout() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
BEGIN
 IF auth.uid() IS NOT NULL THEN
 INSERT INTO public.audit_logs(event_type,actor_id,target_id,details,tenant_id)
 VALUES('auth_logout',auth.uid(),auth.uid(),jsonb_build_object('action','session_disconnect'),NULLIF(auth.jwt()->'app_metadata'->>'tenant_id',''));
 END IF;
END $fn$;
REVOKE ALL ON FUNCTION public.audit_safe_login_func(),public.log_user_login(),public.log_user_logout() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.log_user_logout() TO authenticated;
CREATE SCHEMA IF NOT EXISTS coreaml_private;
REVOKE ALL ON SCHEMA coreaml_private FROM PUBLIC,anon,authenticated;
