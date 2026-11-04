-- Dashboard and role boundaries; no existing bank, customer, report or account rows are rewritten.
CREATE TABLE public.coreaml_admin_requests (
 request_id uuid PRIMARY KEY, actor_id uuid NOT NULL, actor_role text NOT NULL, actor_tenant text,
 action text NOT NULL CHECK(action IN ('INVITE','DEACTIVATE','RESTORE','CREATE_BANK')),
 payload jsonb NOT NULL, target_id uuid, target_tenant text,
 state text NOT NULL CHECK(state IN ('RESERVED','AUTH_CREATED','COMPLETED','UNCONFIRMED')),
 result jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX coreaml_one_invite_request ON public.coreaml_admin_requests(lower(payload->>'email')) WHERE action='INVITE' AND state IN ('RESERVED','AUTH_CREATED','UNCONFIRMED');
ALTER TABLE public.coreaml_admin_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_admin_requests FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION coreaml_private.dashboard_staff(p_roles text[]) RETURNS public.user_profiles LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.user_id=auth.uid() AND s.id::text=auth.jwt()->>'session_id') THEN RAISE EXCEPTION 'Active authentication session required' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid();
 IF NOT FOUND OR p.is_active IS NOT TRUE OR NOT p.role=ANY(p_roles) OR p.role IS DISTINCT FROM auth.jwt()->'app_metadata'->>'role' OR p.tenant_id IS DISTINCT FROM nullif(auth.jwt()->'app_metadata'->>'tenant_id','') OR (p.role<>'it_admin' AND nullif(p.tenant_id,'') IS NULL) OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=p.id AND u.raw_app_meta_data->>'role'=p.role AND nullif(u.raw_app_meta_data->>'tenant_id','') IS NOT DISTINCT FROM p.tenant_id AND (u.banned_until IS NULL OR u.banned_until<=now())) THEN RAISE EXCEPTION 'Active matching trusted staff profile required' USING ERRCODE='42501';END IF;
 RETURN p;END $$;
CREATE FUNCTION public.coreaml_dashboard_context() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN p:=coreaml_private.dashboard_staff(ARRAY['it_admin','head_of_compliance','compliance_officer','bank_manager','branch_manager','bankmanager','teller','sales_rep']);
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'role',p.role,'name',coalesce(p.full_name,'Staff member'),'server_time',now());END $$;
-- Restrictive fences supplement existing policies, even where legacy permissive policies remain.
CREATE FUNCTION coreaml_private.dashboard_business_access() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM auth.sessions s WHERE s.user_id=auth.uid() AND s.id::text=auth.jwt()->>'session_id') THEN RETURN false;END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid();
 RETURN FOUND AND p.is_active IS TRUE AND nullif(p.tenant_id,'') IS NOT NULL AND EXISTS(SELECT 1 FROM auth.users u WHERE u.id=p.id AND u.raw_app_meta_data->>'role'=p.role AND nullif(u.raw_app_meta_data->>'tenant_id','') IS NOT DISTINCT FROM p.tenant_id AND (u.banned_until IS NULL OR u.banned_until<=now())) AND p.role IN ('head_of_compliance','compliance_officer','branch_manager','bankmanager','teller','sales_rep') AND p.role IS NOT DISTINCT FROM auth.jwt()->'app_metadata'->>'role' AND p.tenant_id IS NOT DISTINCT FROM auth.jwt()->'app_metadata'->>'tenant_id';END $$;
DO $$ DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY['customers','accounts','transactions','alerts','investigation_drafts','suspicious_transaction_reports','report_archives','risk_score_history','tills','vault_transfers','aml_rules','shadow_evaluations','coreaml_compatible_sets','coreaml_compatible_runs','coreaml_compatible_results','coreaml_review_submissions','coreaml_review_actions','coreaml_filing_drafts','coreaml_filing_events','coreaml_filing_exports','transaction_evaluation_outbox','coreaml_case_claims','coreaml_case_actions','customer_baselines','customer_risk_profiles','report_schedules'] LOOP
 IF to_regclass('public.'||t) IS NOT NULL THEN
 EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('CREATE POLICY coreaml_dashboard_plane_fence ON public.%I AS RESTRICTIVE FOR ALL TO PUBLIC USING (coreaml_private.dashboard_business_access()) WITH CHECK (coreaml_private.dashboard_business_access())',t);
 END IF;END LOOP;
END $$;
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.banks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.custom_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_events ENABLE ROW LEVEL SECURITY;
-- Profiles, banks and role definitions change through reviewed endpoints, not browser table writes.
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.user_profiles,public.profiles,public.banks,public.custom_roles FROM PUBLIC,anon,authenticated;
CREATE POLICY coreaml_dashboard_profile_read ON public.user_profiles AS RESTRICTIVE FOR SELECT TO authenticated USING (
 id=auth.uid() OR EXISTS(SELECT 1 FROM public.coreaml_dashboard_context() c WHERE c->>'role' IN ('it_admin','head_of_compliance','compliance_officer') AND (c->>'role'='it_admin' OR tenant_id=c->>'tenant_id'))
);
-- Keep manager/admin directory access behind projection RPCs. The own-profile row remains available.
CREATE POLICY coreaml_dashboard_banks_read ON public.banks AS RESTRICTIVE FOR SELECT TO authenticated USING (EXISTS(SELECT 1 FROM public.coreaml_dashboard_context() c WHERE c->>'role'='it_admin' OR id=c->>'tenant_id'));
CREATE POLICY coreaml_dashboard_roles_read ON public.custom_roles AS RESTRICTIVE FOR SELECT TO authenticated USING (coreaml_private.dashboard_business_access());
CREATE POLICY coreaml_dashboard_legacy_profiles ON public.profiles AS RESTRICTIVE FOR SELECT TO authenticated USING (
 id=auth.uid() OR (coreaml_private.dashboard_business_access() AND tenant_id=auth.jwt()->'app_metadata'->>'tenant_id')
);
CREATE POLICY coreaml_dashboard_audit_fence ON public.audit_logs AS RESTRICTIVE FOR ALL TO authenticated USING (
 coreaml_private.dashboard_business_access() AND tenant_id::text=auth.jwt()->'app_metadata'->>'tenant_id'
) WITH CHECK(false);
CREATE POLICY coreaml_dashboard_telemetry_fence ON public.system_events AS RESTRICTIVE FOR ALL TO authenticated USING (
 coreaml_private.dashboard_business_access() AND tenant_id::text=auth.jwt()->'app_metadata'->>'tenant_id'
) WITH CHECK(coreaml_private.dashboard_business_access() AND tenant_id::text=auth.jwt()->'app_metadata'->>'tenant_id');
CREATE FUNCTION public.coreaml_manager_dashboard(p_section text DEFAULT 'OVERVIEW',p_offset integer DEFAULT 0,p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;rows jsonb;total bigint;BEGIN
 p:=coreaml_private.dashboard_staff(ARRAY['bank_manager']);
 IF p_section IS NULL OR p_section NOT IN ('OVERVIEW','CASES','TRANSACTIONS','STAFF') OR p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 100000 OR p_search IS NULL OR length(p_search)>120 THEN RAISE EXCEPTION 'Invalid bounded oversight query' USING ERRCODE='22023';END IF;
 IF p_section='OVERVIEW' THEN RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'section',p_section,'server_time',now(),
 'bank_name',(SELECT name FROM public.banks WHERE id=p.tenant_id),
 'customers',(SELECT count(*) FROM public.customers WHERE tenant_id=p.tenant_id),
 'open_cases',(SELECT count(*) FROM public.coreaml_case_claims c WHERE c.tenant_id=p.tenant_id AND EXISTS(SELECT 1 FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND a.tenant_id=p.tenant_id AND a.status<>'CLOSED')),
 'unassigned_alerts',(SELECT count(*) FROM public.alerts WHERE tenant_id=p.tenant_id AND status='UNASSIGNED'),
 'severity',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT severity,count(*) AS count FROM public.alerts WHERE tenant_id=p.tenant_id AND status<>'CLOSED' GROUP BY severity ORDER BY severity) q),
 'risk_tiers',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT risk_tier::text AS risk_tier,count(*) AS count FROM public.customers WHERE tenant_id=p.tenant_id GROUP BY risk_tier ORDER BY risk_tier) q),
 'case_states',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT status,count(*) AS count FROM public.alerts WHERE tenant_id=p.tenant_id GROUP BY status ORDER BY status) q),
 'filing_counts',(SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') FROM (SELECT mode,state,count(*) AS count FROM public.coreaml_filing_drafts WHERE tenant_id=p.tenant_id GROUP BY mode,state ORDER BY mode,state) q),
 'governed_rules',(SELECT count(*) FROM public.coreaml_rule_deployments WHERE tenant_id=p.tenant_id AND status='ACTIVE'),
 'evaluation_errors',(SELECT count(*) FROM public.coreaml_rule_results WHERE tenant_id=p.tenant_id AND outcome='ERROR'));
 ELSIF p_section='CASES' THEN
 SELECT count(*) INTO total FROM public.coreaml_case_claims c WHERE c.tenant_id=p.tenant_id AND (p_search='' OR position(lower(p_search) in lower(c.case_reference))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT c.case_reference,cardinality(c.alert_ids) AS alert_members,coalesce(u.full_name,'Name unavailable') AS owner,
 CASE WHEN (SELECT count(DISTINCT a.status) FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND a.tenant_id=p.tenant_id)=1 THEN (SELECT min(a.status) FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND a.tenant_id=p.tenant_id) ELSE 'MIXED' END AS state,
 (SELECT min(a.created_at) FROM public.alerts a WHERE a.id=ANY(c.alert_ids) AND a.tenant_id=p.tenant_id) AS detected_at
 FROM public.coreaml_case_claims c LEFT JOIN public.user_profiles u ON u.id=c.investigator_id AND u.tenant_id=c.tenant_id WHERE c.tenant_id=p.tenant_id AND (p_search='' OR position(lower(p_search) in lower(c.case_reference))>0) ORDER BY c.case_reference,c.id OFFSET p_offset LIMIT 25) q;
 ELSIF p_section='TRANSACTIONS' THEN
 SELECT count(*) INTO total FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id JOIN public.customers c ON c.id=a.customer_id WHERE c.tenant_id=p.tenant_id AND (p_search='' OR position(lower(p_search) in lower(t.transaction_reference))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT t.transaction_reference,t.transaction_timestamp,t.amount::text AS amount,t.currency::text AS currency,t.transaction_type::text AS direction,t.channel::text AS channel FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id JOIN public.customers c ON c.id=a.customer_id WHERE c.tenant_id=p.tenant_id AND (p_search='' OR position(lower(p_search) in lower(t.transaction_reference))>0) ORDER BY t.transaction_timestamp DESC,t.id DESC OFFSET p_offset LIMIT 25) q;
 ELSE
 SELECT count(*) INTO total FROM public.user_profiles WHERE tenant_id=p.tenant_id AND role IN ('compliance_officer','head_of_compliance') AND (p_search='' OR position(lower(p_search) in lower(coalesce(full_name,'')||' '||role))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT coalesce(full_name,'Name unavailable') AS name,role,is_active FROM public.user_profiles WHERE tenant_id=p.tenant_id AND role IN ('compliance_officer','head_of_compliance') AND (p_search='' OR position(lower(p_search) in lower(coalesce(full_name,'')||' '||role))>0) ORDER BY role,id OFFSET p_offset LIMIT 25) q;
 END IF;
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'section',p_section,'offset',p_offset,'total',total,'rows',rows,'server_time',now());END $$;
CREATE FUNCTION public.coreaml_admin_directory(p_section text DEFAULT 'USERS',p_offset integer DEFAULT 0,p_search text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;rows jsonb;total bigint;BEGIN p:=coreaml_private.dashboard_staff(ARRAY['it_admin','head_of_compliance']);
 IF p_section IS NULL OR p_section NOT IN ('USERS','BANKS','ROLES','AUDIT','REQUESTS') OR p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 100000 OR p_search IS NULL OR length(p_search)>120 THEN RAISE EXCEPTION 'Invalid directory query' USING ERRCODE='22023';END IF;
 IF p_section='USERS' THEN
 SELECT count(*) INTO total FROM public.user_profiles u WHERE (p.role='it_admin' OR u.tenant_id=p.tenant_id AND u.role IN ('compliance_officer','head_of_compliance')) AND (p_search='' OR position(lower(p_search) in lower(coalesce(u.full_name,'')||' '||u.role||' '||coalesce(u.tenant_id,'')))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT u.id,u.full_name,u.role,u.tenant_id,u.is_active,u.created_at,b.name AS bank_name,(u.id<>p.id AND (p.role='it_admin' OR u.role='compliance_officer')) AS can_manage FROM public.user_profiles u LEFT JOIN public.banks b ON b.id=u.tenant_id WHERE (p.role='it_admin' OR u.tenant_id=p.tenant_id AND u.role IN ('compliance_officer','head_of_compliance')) AND (p_search='' OR position(lower(p_search) in lower(coalesce(u.full_name,'')||' '||u.role||' '||coalesce(u.tenant_id,'')))>0) ORDER BY u.created_at DESC,u.id OFFSET p_offset LIMIT 25) q;
 ELSIF p_section='BANKS' THEN
 SELECT count(*) INTO total FROM public.banks WHERE (p.role='it_admin' OR id=p.tenant_id) AND (p_search='' OR position(lower(p_search) in lower(name||' '||id))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT id,name,created_at FROM public.banks WHERE (p.role='it_admin' OR id=p.tenant_id) AND (p_search='' OR position(lower(p_search) in lower(name||' '||id))>0) ORDER BY name,id OFFSET p_offset LIMIT 25) q;
 ELSIF p_section='ROLES' THEN
 IF p.role<>'it_admin' THEN RAISE EXCEPTION 'Platform role inventory required' USING ERRCODE='42501';END IF;
 SELECT count(*) INTO total FROM public.custom_roles WHERE p_search='' OR position(lower(p_search) in lower(role_name||' '||coalesce(description,'')))>0;
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT id,role_name,description,tenant_id,created_at FROM public.custom_roles WHERE p_search='' OR position(lower(p_search) in lower(role_name||' '||coalesce(description,'')))>0 ORDER BY created_at DESC,id OFFSET p_offset LIMIT 25) q;
 ELSIF p_section='AUDIT' THEN
 SELECT count(*) INTO total FROM public.audit_logs WHERE (p.role='it_admin' OR tenant_id::text=p.tenant_id) AND (p_search='' OR position(lower(p_search) in lower(event_type))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT id,created_at,event_type,actor_id,target_id,tenant_id FROM public.audit_logs WHERE (p.role='it_admin' OR tenant_id::text=p.tenant_id) AND (p_search='' OR position(lower(p_search) in lower(event_type))>0) ORDER BY created_at DESC,id DESC OFFSET p_offset LIMIT 25) q;
 ELSE
 SELECT count(*) INTO total FROM public.coreaml_admin_requests WHERE (p.role='it_admin' OR actor_id=p.id) AND (p_search='' OR position(lower(p_search) in lower(request_id::text||' '||action||' '||state||' '||coalesce(payload->>'email','')))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT request_id,action,state,target_id,target_tenant,payload->>'email' AS invited_email,payload->>'role' AS requested_role,created_at,updated_at,result FROM public.coreaml_admin_requests WHERE (p.role='it_admin' OR actor_id=p.id) AND (p_search='' OR position(lower(p_search) in lower(request_id::text||' '||action||' '||state||' '||coalesce(payload->>'email','')))>0) ORDER BY created_at DESC,request_id DESC OFFSET p_offset LIMIT 25) q;
 END IF;
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'role',p.role,'section',p_section,'offset',p_offset,'total',total,'rows',rows,'server_time',now());END $$;
CREATE FUNCTION public.coreaml_admin_reserve(p_action text,p_payload jsonb,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;t public.user_profiles%ROWTYPE;r public.coreaml_admin_requests%ROWTYPE;bank text;v_role text;BEGIN
 p:=coreaml_private.dashboard_staff(ARRAY['it_admin','head_of_compliance']);
 PERFORM 1 FROM public.user_profiles WHERE id=p.id FOR SHARE;
 IF p_request_id IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR p_action IS NULL OR p_action NOT IN ('INVITE','DEACTIVATE','RESTORE') THEN RAISE EXCEPTION 'Invalid administration request' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('admin-request:'||p_request_id::text,0));
 SELECT * INTO r FROM public.coreaml_admin_requests WHERE request_id=p_request_id FOR UPDATE;
 IF FOUND THEN
 IF r.actor_id<>p.id OR r.actor_role<>p.role OR r.actor_tenant IS DISTINCT FROM p.tenant_id THEN RAISE EXCEPTION 'Request unavailable' USING ERRCODE='42501';END IF;
 IF (r.action,r.payload) IS DISTINCT FROM (p_action,p_payload) THEN RAISE EXCEPTION 'Request reference reused with different content' USING ERRCODE='22023';END IF;
 RETURN to_jsonb(r)||jsonb_build_object('replayed',true,'dispatch',r.state<>'COMPLETED' AND (r.action<>'INVITE' OR r.state='AUTH_CREATED'));END IF;
 IF p_action='INVITE' THEN
 bank:=nullif(p_payload->>'tenant_id','');v_role:=p_payload->>'role';
 IF coalesce(p_payload->>'email','') !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' OR length(p_payload->>'email')>254 OR v_role IS NULL OR v_role NOT IN ('it_admin','head_of_compliance','compliance_officer','bank_manager','branch_manager','bankmanager','teller','sales_rep') THEN RAISE EXCEPTION 'Supported built-in role and valid email required' USING ERRCODE='22023';END IF;
 IF (v_role='it_admin' AND (p.role<>'it_admin' OR bank IS NOT NULL)) OR (v_role<>'it_admin' AND (bank IS NULL OR NOT EXISTS(SELECT 1 FROM public.banks WHERE id=bank))) OR (p.role='head_of_compliance' AND (v_role<>'compliance_officer' OR bank IS DISTINCT FROM p.tenant_id)) THEN RAISE EXCEPTION 'Invitation exceeds your bank or role authority' USING ERRCODE='42501';END IF;
 -- Do not use inviteUserByEmail as an implicit role-change tool for existing identities.
 IF EXISTS(SELECT 1 FROM auth.users WHERE lower(email)=lower(p_payload->>'email')) THEN RAISE EXCEPTION 'An identity already exists for this email; invitation cannot change its role' USING ERRCODE='22023';END IF;
 ELSE
 SELECT * INTO t FROM public.user_profiles WHERE id=(p_payload->>'target_id')::uuid FOR UPDATE;
 IF NOT FOUND OR t.id=p.id OR (p.role='head_of_compliance' AND (t.tenant_id IS DISTINCT FROM p.tenant_id OR t.role<>'compliance_officer')) THEN RAISE EXCEPTION 'Target is outside your authority or is your own account' USING ERRCODE='42501';END IF;
 bank:=t.tenant_id;
 IF p_action='DEACTIVATE' THEN UPDATE public.user_profiles SET is_active=false WHERE id=t.id;END IF;
 END IF;
 INSERT INTO public.coreaml_admin_requests(request_id,actor_id,actor_role,actor_tenant,action,payload,target_id,target_tenant,state,result)
 VALUES(p_request_id,p.id,p.role,p.tenant_id,p_action,p_payload,t.id,bank,'RESERVED',jsonb_build_object('target_role',coalesce(t.role,v_role))) RETURNING * INTO r;
 RETURN to_jsonb(r)||jsonb_build_object('replayed',false,'dispatch',true);
END $$;
CREATE FUNCTION public.coreaml_admin_auth_checkpoint(p_actor uuid,p_request_id uuid,p_target uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.coreaml_admin_requests%ROWTYPE;BEGIN
 SELECT * INTO r FROM public.coreaml_admin_requests WHERE request_id=p_request_id FOR UPDATE;
 IF NOT FOUND OR r.actor_id<>p_actor OR r.action<>'INVITE' OR r.state NOT IN ('RESERVED','AUTH_CREATED') OR p_target IS NULL OR (r.target_id IS NOT NULL AND r.target_id<>p_target) THEN RAISE EXCEPTION 'Invalid authentication checkpoint' USING ERRCODE='42501';END IF;
 UPDATE public.coreaml_admin_requests SET target_id=p_target,state='AUTH_CREATED',updated_at=now() WHERE request_id=p_request_id RETURNING * INTO r;RETURN to_jsonb(r);
END $$;
CREATE FUNCTION public.coreaml_admin_finish(p_actor uuid,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r public.coreaml_admin_requests%ROWTYPE;p public.user_profiles%ROWTYPE;t public.user_profiles%ROWTYPE;u auth.users%ROWTYPE;answer jsonb;BEGIN
 SELECT * INTO r FROM public.coreaml_admin_requests WHERE request_id=p_request_id FOR UPDATE;
 IF NOT FOUND OR r.actor_id<>p_actor THEN RAISE EXCEPTION 'Request unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO p FROM public.user_profiles WHERE id=p_actor FOR SHARE;
 IF NOT FOUND OR p.is_active IS NOT TRUE OR (p.role,p.tenant_id) IS DISTINCT FROM (r.actor_role,r.actor_tenant) OR NOT EXISTS(SELECT 1 FROM auth.users actor WHERE actor.id=p.id AND actor.raw_app_meta_data->>'role'=p.role AND nullif(actor.raw_app_meta_data->>'tenant_id','') IS NOT DISTINCT FROM p.tenant_id AND (actor.banned_until IS NULL OR actor.banned_until<=now())) THEN RAISE EXCEPTION 'Actor authority changed' USING ERRCODE='42501';END IF;
 IF r.state='COMPLETED' THEN RETURN r.result||jsonb_build_object('replayed',true);END IF;
 SELECT * INTO t FROM public.user_profiles WHERE id=r.target_id FOR UPDATE;
 IF NOT FOUND OR (t.role,t.tenant_id) IS DISTINCT FROM (r.result->>'target_role',r.target_tenant) THEN RAISE EXCEPTION 'Target role or bank changed' USING ERRCODE='42501';END IF;
 SELECT * INTO u FROM auth.users WHERE id=r.target_id;
 IF NOT FOUND OR u.raw_app_meta_data->>'role' IS DISTINCT FROM t.role OR nullif(u.raw_app_meta_data->>'tenant_id','') IS DISTINCT FROM t.tenant_id THEN RAISE EXCEPTION 'Auth and trusted profile mismatch' USING ERRCODE='42501';END IF;
 IF r.action='DEACTIVATE' AND (u.banned_until IS NULL OR u.banned_until<=now()) THEN RAISE EXCEPTION 'Auth ban has not been confirmed';END IF;
 IF r.action IN ('RESTORE','INVITE') AND u.banned_until>now() THEN RAISE EXCEPTION 'Auth identity remains banned';END IF;
 IF r.action='INVITE' AND r.state<>'AUTH_CREATED' THEN RAISE EXCEPTION 'Invitation has no recorded Auth identity';END IF;
 UPDATE public.user_profiles SET is_active=(r.action<>'DEACTIVATE') WHERE id=t.id;
 answer:=jsonb_build_object('success',true,'request_id',r.request_id,'actor_id',p_actor,'target_id',t.id,'action',r.action,'state','COMPLETED','tenant_id',r.target_tenant,'replayed',false);
 INSERT INTO public.audit_logs(event_type,actor_id,target_id,tenant_id,details) VALUES('ADMIN_'||r.action,p_actor,t.id,CASE WHEN r.target_tenant ~* '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' THEN r.target_tenant::uuid ELSE NULL END,jsonb_build_object('request_id',r.request_id,'actor_role',r.actor_role,'target_role',t.role));
 UPDATE public.coreaml_admin_requests SET state='COMPLETED',result=answer,updated_at=now() WHERE request_id=p_request_id;RETURN answer;
END $$;
CREATE FUNCTION public.coreaml_create_bank(p_name text,p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;r public.coreaml_admin_requests%ROWTYPE;v_id text;answer jsonb;BEGIN
 p:=coreaml_private.dashboard_staff(ARRAY['it_admin']);IF p_request_id IS NULL OR length(btrim(coalesce(p_name,''))) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'A bank name of 3–120 characters is required' USING ERRCODE='22023';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('admin-request:'||p_request_id::text,0));SELECT * INTO r FROM public.coreaml_admin_requests WHERE request_id=p_request_id;
 IF FOUND THEN IF r.actor_id<>p.id OR r.action<>'CREATE_BANK' OR r.payload IS DISTINCT FROM jsonb_build_object('name',p_name) THEN RAISE EXCEPTION 'Request reused with different content' USING ERRCODE='22023';END IF;RETURN r.result||jsonb_build_object('replayed',true);END IF;
 v_id:=gen_random_uuid()::text;INSERT INTO public.banks(id,name) VALUES(v_id,btrim(p_name));answer:=jsonb_build_object('request_id',p_request_id,'actor_id',p.id,'action','CREATE_BANK','tenant_id',v_id,'state','COMPLETED','success',true,'replayed',false);
 INSERT INTO public.coreaml_admin_requests(request_id,actor_id,actor_role,actor_tenant,action,payload,target_tenant,state,result) VALUES(p_request_id,p.id,p.role,p.tenant_id,'CREATE_BANK',jsonb_build_object('name',p_name),v_id,'COMPLETED',answer);
 INSERT INTO public.audit_logs(event_type,actor_id,tenant_id,details) VALUES('ADMIN_CREATE_BANK',p.id,v_id::uuid,jsonb_build_object('request_id',p_request_id));RETURN answer;END $$;
REVOKE ALL ON FUNCTION coreaml_private.dashboard_staff(text[]),coreaml_private.dashboard_business_access() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION coreaml_private.dashboard_business_access() TO anon,authenticated;
REVOKE ALL ON FUNCTION public.coreaml_dashboard_context(),public.coreaml_manager_dashboard(text,integer,text),public.coreaml_admin_directory(text,integer,text),public.coreaml_admin_reserve(text,jsonb,uuid),public.coreaml_create_bank(text,uuid),public.coreaml_admin_auth_checkpoint(uuid,uuid,uuid),public.coreaml_admin_finish(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_dashboard_context(),public.coreaml_manager_dashboard(text,integer,text),public.coreaml_admin_directory(text,integer,text),public.coreaml_admin_reserve(text,jsonb,uuid),public.coreaml_create_bank(text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_admin_auth_checkpoint(uuid,uuid,uuid),public.coreaml_admin_finish(uuid,uuid) TO service_role;
DO $$ DECLARE f text;BEGIN
 FOREACH f IN ARRAY ARRAY['public.update_risk_tier(uuid,integer,text)','public.calculate_dynamic_baselines()'] LOOP
 IF to_regprocedure(f) IS NOT NULL THEN EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f);END IF;END LOOP;
END $$;
NOTIFY pgrst,'reload schema';

DO $$ BEGIN IF to_regclass('storage.objects') IS NOT NULL THEN
 CREATE POLICY coreaml_dashboard_storage_fence ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated USING (coreaml_private.dashboard_business_access()) WITH CHECK(coreaml_private.dashboard_business_access());
END IF;END $$;

DO $install$ BEGIN IF to_regprocedure('public.get_rolling_tx_stats(uuid,integer,text)') IS NOT NULL THEN
 ALTER FUNCTION public.get_rolling_tx_stats(uuid,integer,text) RENAME TO get_rolling_tx_stats_before_dashboard;
 REVOKE ALL ON FUNCTION public.get_rolling_tx_stats_before_dashboard(uuid,integer,text) FROM PUBLIC,anon,authenticated;
 EXECUTE $definition$CREATE FUNCTION public.get_rolling_tx_stats(p_account_id uuid,p_hours integer,p_tx_type text DEFAULT 'CREDIT') RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $body$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF current_setting('role',true)='service_role' OR (session_user='postgres' AND coalesce(current_setting('role',true),'none') IN ('none','postgres')) THEN RETURN public.get_rolling_tx_stats_before_dashboard(p_account_id,p_hours,p_tx_type);END IF;
 p:=coreaml_private.dashboard_staff(ARRAY['head_of_compliance','compliance_officer','branch_manager','bankmanager','teller','sales_rep']);
 IF NOT EXISTS(SELECT 1 FROM public.accounts a JOIN public.customers c ON c.id=a.customer_id WHERE a.id=p_account_id AND c.tenant_id=p.tenant_id) THEN RAISE EXCEPTION 'Account is outside your bank' USING ERRCODE='42501';END IF;
 RETURN public.get_rolling_tx_stats_before_dashboard(p_account_id,p_hours,p_tx_type);END $body$;$definition$;
 REVOKE ALL ON FUNCTION public.get_rolling_tx_stats(uuid,integer,text) FROM PUBLIC,anon,authenticated;
 GRANT EXECUTE ON FUNCTION public.get_rolling_tx_stats(uuid,integer,text) TO authenticated,service_role;
END IF;END $install$;

DO $install$ BEGIN IF to_regprocedure('public.get_rolling_tx_volume(uuid,integer,text)') IS NOT NULL THEN
 ALTER FUNCTION public.get_rolling_tx_volume(uuid,integer,text) RENAME TO get_rolling_tx_volume_before_dashboard;
 REVOKE ALL ON FUNCTION public.get_rolling_tx_volume_before_dashboard(uuid,integer,text) FROM PUBLIC,anon,authenticated;
 EXECUTE $definition$CREATE FUNCTION public.get_rolling_tx_volume(p_account_id uuid,p_hours integer,p_tx_type text DEFAULT 'CREDIT') RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $body$
DECLARE p public.user_profiles%ROWTYPE;BEGIN
 IF current_setting('role',true)='service_role' OR (session_user='postgres' AND coalesce(current_setting('role',true),'none') IN ('none','postgres')) THEN RETURN public.get_rolling_tx_volume_before_dashboard(p_account_id,p_hours,p_tx_type);END IF;
 p:=coreaml_private.dashboard_staff(ARRAY['head_of_compliance','compliance_officer','branch_manager','bankmanager','teller','sales_rep']);
 IF NOT EXISTS(SELECT 1 FROM public.accounts a JOIN public.customers c ON c.id=a.customer_id WHERE a.id=p_account_id AND c.tenant_id=p.tenant_id) THEN RAISE EXCEPTION 'Account is outside your bank' USING ERRCODE='42501';END IF;
 RETURN public.get_rolling_tx_volume_before_dashboard(p_account_id,p_hours,p_tx_type);END $body$;$definition$;
 REVOKE ALL ON FUNCTION public.get_rolling_tx_volume(uuid,integer,text) FROM PUBLIC,anon,authenticated;
 GRANT EXECUTE ON FUNCTION public.get_rolling_tx_volume(uuid,integer,text) TO authenticated,service_role;
END IF;END $install$;

NOTIFY pgrst,'reload schema';
