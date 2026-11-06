
DROP POLICY coreaml_dashboard_telemetry_fence ON public.system_events;
ALTER TABLE public.system_events ALTER COLUMN tenant_id TYPE text USING tenant_id::text;
CREATE POLICY coreaml_dashboard_telemetry_fence ON public.system_events AS RESTRICTIVE FOR ALL TO authenticated USING(coreaml_private.dashboard_business_access() AND tenant_id=auth.jwt()->'app_metadata'->>'tenant_id') WITH CHECK(coreaml_private.dashboard_business_access() AND tenant_id=auth.jwt()->'app_metadata'->>'tenant_id');
DO $repair$
DECLARE f record; definition text;
BEGIN
 FOR f IN SELECT p.oid,n.nspname,p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE (n.nspname='public' AND p.proname IN ('coreaml_claim_case','coreaml_submit_case_review','coreaml_review_decision','coreaml_case_action_before_governance','coreaml_admin_finish','coreaml_create_bank'))
 OR (n.nspname='coreaml_private' AND p.proname='reporting_review_decision_v3')
 LOOP
 definition:=pg_get_functiondef(f.oid);
 definition:=replace(definition,'staff.tenant_id::uuid','staff.tenant_id');
 definition:=replace(definition,'p.tenant_id::uuid','p.tenant_id');
 definition:=replace(definition,'(ctx->>''tenant_id'')::uuid','ctx->>''tenant_id''');
 definition:=replace(definition,'CASE WHEN r.target_tenant ~* ''^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'' THEN r.target_tenant::uuid ELSE NULL END','r.target_tenant');
 definition:=replace(definition,'v_id::uuid','v_id');
 EXECUTE definition;
 END LOOP;
END $repair$;
NOTIFY pgrst,'reload schema';
