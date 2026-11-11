-- Restore the same-bank invitation roles shown in the compliance dashboard.
CREATE OR REPLACE FUNCTION public.coreaml_admin_directory(p_section text DEFAULT 'USERS'::text, p_offset integer DEFAULT 0, p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE p public.user_profiles%ROWTYPE;rows jsonb;total bigint;BEGIN p:=coreaml_private.dashboard_staff(ARRAY['it_admin','head_of_compliance']);
 IF p_section IS NULL OR p_section NOT IN ('USERS','BANKS','ROLES','AUDIT','REQUESTS') OR p_offset IS NULL OR p_offset NOT BETWEEN 0 AND 100000 OR p_search IS NULL OR length(p_search)>120 THEN RAISE EXCEPTION 'Invalid directory query' USING ERRCODE='22023';END IF;
 IF p_section='USERS' THEN
 SELECT count(*) INTO total FROM public.user_profiles u WHERE (p.role='it_admin' OR u.tenant_id=p.tenant_id AND u.role IN ('compliance_officer','head_of_compliance','bank_manager')) AND (p_search='' OR position(lower(p_search) in lower(coalesce(u.full_name,'')||' '||u.role||' '||coalesce(u.tenant_id,'')))>0);
 SELECT coalesce(jsonb_agg(to_jsonb(q)),'[]') INTO rows FROM (SELECT u.id,u.full_name,u.role,u.tenant_id,u.is_active,u.created_at,b.name AS bank_name,(u.id<>p.id AND (p.role='it_admin' OR u.role='compliance_officer')) AS can_manage FROM public.user_profiles u LEFT JOIN public.banks b ON b.id=u.tenant_id WHERE (p.role='it_admin' OR u.tenant_id=p.tenant_id AND u.role IN ('compliance_officer','head_of_compliance','bank_manager')) AND (p_search='' OR position(lower(p_search) in lower(coalesce(u.full_name,'')||' '||u.role||' '||coalesce(u.tenant_id,'')))>0) ORDER BY u.created_at DESC,u.id OFFSET p_offset LIMIT 25) q;
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
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'role',p.role,'section',p_section,'offset',p_offset,'total',total,'rows',rows,'server_time',now());END $function$;

CREATE OR REPLACE FUNCTION public.coreaml_admin_reserve(p_action text, p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 IF (v_role='it_admin' AND (p.role<>'it_admin' OR bank IS NOT NULL)) OR (v_role<>'it_admin' AND (bank IS NULL OR NOT EXISTS(SELECT 1 FROM public.banks WHERE id=bank))) OR (p.role='head_of_compliance' AND (v_role NOT IN ('compliance_officer','head_of_compliance','bank_manager') OR bank IS DISTINCT FROM p.tenant_id)) THEN RAISE EXCEPTION 'Invitation exceeds your bank or role authority' USING ERRCODE='42501';END IF;
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
END $function$;

NOTIFY pgrst, 'reload schema';
