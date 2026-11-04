-- Local owner-managed draft and closure foundation. Existing evidence is immutable.
ALTER TABLE public.investigation_drafts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.investigation_drafts FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.investigation_drafts TO authenticated;
REVOKE TRUNCATE,TRIGGER,REFERENCES ON public.alerts FROM PUBLIC,anon,authenticated;
ALTER TABLE public.investigation_drafts ADD COLUMN case_reference text REFERENCES public.coreaml_case_claims(case_reference);
ALTER TABLE public.investigation_drafts ADD COLUMN revision integer NOT NULL DEFAULT 0 CHECK (revision>=0);
ALTER TABLE public.investigation_drafts ADD COLUMN closed_at timestamptz;
ALTER TABLE public.investigation_drafts DROP CONSTRAINT investigation_drafts_status_check;
ALTER TABLE public.investigation_drafts ADD CONSTRAINT investigation_drafts_status_check CHECK (status IN ('IN_PROGRESS','SUBMITTED','DISCARDED','CLOSED'));

CREATE TABLE public.coreaml_case_actions (
 request_id uuid PRIMARY KEY,
 case_reference text NOT NULL REFERENCES public.coreaml_case_claims(case_reference),
 actor_id uuid NOT NULL REFERENCES auth.users(id),
 tenant_id text NOT NULL,
 action text NOT NULL CHECK (action IN ('SAVE','CLOSE')),
 payload jsonb NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.coreaml_case_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.coreaml_case_actions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.coreaml_case_actions TO authenticated;
CREATE POLICY case_action_read ON public.coreaml_case_actions FOR SELECT TO authenticated USING (
 EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.is_active IS TRUE AND p.tenant_id=coreaml_case_actions.tenant_id
 AND ((p.role='compliance_officer' AND p.id=coreaml_case_actions.actor_id) OR p.role='head_of_compliance'))
);
CREATE POLICY case_draft_boundary ON public.investigation_drafts AS RESTRICTIVE FOR ALL TO authenticated USING (
 case_reference IS NOT NULL AND EXISTS(SELECT 1 FROM public.user_profiles p JOIN public.coreaml_case_claims c ON c.case_reference=investigation_drafts.case_reference
 WHERE p.id=auth.uid() AND p.is_active IS TRUE AND p.tenant_id=investigation_drafts.tenant_id AND c.tenant_id=p.tenant_id
 AND c.anchor_alert_id=investigation_drafts.alert_id AND c.investigator_id=investigation_drafts.investigator_id
 AND ((p.role='compliance_officer' AND p.id=c.investigator_id) OR p.role='head_of_compliance'))
) WITH CHECK (false);

CREATE FUNCTION coreaml_private.case_workflow_staff(p_write boolean) RETURNS public.user_profiles
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501';END IF;
 IF p_write THEN SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid() FOR SHARE;
 ELSE SELECT * INTO p FROM public.user_profiles WHERE id=auth.uid();END IF;
 IF NOT FOUND OR p.is_active IS NOT TRUE OR nullif(p.tenant_id,'') IS NULL OR p.role NOT IN ('compliance_officer','head_of_compliance')
 OR (p_write AND p.role<>'compliance_officer') OR (auth.jwt()->'app_metadata'->>'tenant_id') IS DISTINCT FROM p.tenant_id
 OR (auth.jwt()->'app_metadata'->>'role') IS DISTINCT FROM p.role THEN RAISE EXCEPTION 'Active authorized bank profile required' USING ERRCODE='42501';END IF;
 RETURN p;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.case_workflow_staff(boolean) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION coreaml_private.case_workflow_context(p_alert_id uuid,p_write boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;c public.coreaml_case_claims%ROWTYPE;a public.alerts%ROWTYPE;total integer;opened integer;closed integer;
BEGIN
 p:=coreaml_private.case_workflow_staff(p_write);
 SELECT * INTO c FROM public.coreaml_case_claims WHERE tenant_id=p.tenant_id AND p_alert_id=ANY(alert_ids);
 IF NOT FOUND OR (c.investigator_id<>p.id AND (p_write OR p.role<>'head_of_compliance')) THEN RAISE EXCEPTION 'Case unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO a FROM public.alerts WHERE id=c.anchor_alert_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Case anchor unavailable';END IF;
 IF p_write THEN
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p.tenant_id||':'||coalesce(a.customer_id::text,a.id::text),0));
  PERFORM id FROM public.coreaml_case_claims WHERE id=c.id FOR UPDATE;
  PERFORM id FROM public.alerts WHERE id=ANY(c.alert_ids) ORDER BY id FOR UPDATE;
 END IF;
 SELECT count(*),count(*) FILTER(WHERE status='INVESTIGATING'),count(*) FILTER(WHERE status='CLOSED') INTO total,opened,closed
 FROM public.alerts WHERE id=ANY(c.alert_ids) AND tenant_id=p.tenant_id AND assigned_user_id=c.investigator_id AND case_reference=c.case_reference
 AND customer_id IS NOT DISTINCT FROM a.customer_id;
 IF total<>cardinality(c.alert_ids) OR (opened<>total AND closed<>total) THEN RAISE EXCEPTION 'Case membership or state changed';END IF;
 RETURN jsonb_build_object('actor_id',p.id,'tenant_id',p.tenant_id,'case_reference',c.case_reference,'alert_id',c.anchor_alert_id,
 'alert_ids',c.alert_ids,'customer_id',a.customer_id,'owner_id',c.investigator_id,'case_status',CASE WHEN closed=total THEN 'CLOSED' ELSE 'INVESTIGATING' END,
 'read_only',p.id<>c.investigator_id OR p.role<>'compliance_officer' OR closed=total);
END $$;
REVOKE ALL ON FUNCTION coreaml_private.case_workflow_context(uuid,boolean) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION coreaml_private.case_workflow_pins(p_snapshot jsonb,p_tenant text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e jsonb;value text;identifier uuid;seen uuid[]:='{}';refs text[]:='{}';entities jsonb:='[]';label text;
BEGIN
 IF jsonb_typeof(p_snapshot) IS DISTINCT FROM 'object' OR (p_snapshot-'entity_ids'-'transaction_refs')<>'{}'::jsonb
 OR jsonb_typeof(p_snapshot->'entity_ids') IS DISTINCT FROM 'array' OR jsonb_typeof(p_snapshot->'transaction_refs') IS DISTINCT FROM 'array'
 OR jsonb_array_length(p_snapshot->'entity_ids')>100 OR jsonb_array_length(p_snapshot->'transaction_refs')>200 OR pg_column_size(p_snapshot)>131072 THEN RAISE EXCEPTION 'Invalid or oversized evidence pins' USING ERRCODE='22023';END IF;
 FOR e IN SELECT * FROM jsonb_array_elements(p_snapshot->'entity_ids') LOOP
  IF jsonb_typeof(e)<>'string' THEN RAISE EXCEPTION 'Invalid entity pin' USING ERRCODE='22023';END IF;
  identifier:=(e#>>'{}')::uuid;
  IF identifier=ANY(seen) THEN RAISE EXCEPTION 'Duplicate entity pin' USING ERRCODE='22023';END IF;
  SELECT coalesce(nullif(entity_name,''),nullif(concat_ws(' ',first_name,last_name),''),'Unknown entity') INTO label FROM public.customers WHERE id=identifier AND tenant_id=p_tenant;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pinned entity unavailable' USING ERRCODE='42501';END IF;
  seen:=array_append(seen,identifier);entities:=entities||jsonb_build_array(jsonb_build_object('id',identifier,'name',label));
 END LOOP;
 FOR e IN SELECT * FROM jsonb_array_elements(p_snapshot->'transaction_refs') LOOP
  IF jsonb_typeof(e)<>'string' THEN RAISE EXCEPTION 'Invalid transaction pin' USING ERRCODE='22023';END IF;value:=e#>>'{}';
  IF length(value)<1 OR length(value)>512 OR value=ANY(refs) THEN RAISE EXCEPTION 'Invalid or duplicate transaction pin' USING ERRCODE='22023';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id JOIN public.customers c ON c.id=a.customer_id WHERE t.transaction_reference=value AND c.tenant_id=p_tenant) THEN RAISE EXCEPTION 'Pinned transaction unavailable' USING ERRCODE='42501';END IF;
  refs:=array_append(refs,value);
 END LOOP;
 RETURN jsonb_build_object('entities',entities,'txs',to_jsonb(refs));
END $$;
REVOKE ALL ON FUNCTION coreaml_private.case_workflow_pins(jsonb,text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.coreaml_load_case_draft(p_alert_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE ctx jsonb;d public.investigation_drafts%ROWTYPE;
BEGIN
 ctx:=coreaml_private.case_workflow_context(p_alert_id,false);
 SELECT * INTO d FROM public.investigation_drafts WHERE alert_id=(ctx->>'alert_id')::uuid AND investigator_id=(ctx->>'owner_id')::uuid;
 IF FOUND THEN
  IF d.case_reference IS DISTINCT FROM ctx->>'case_reference' OR d.tenant_id IS DISTINCT FROM ctx->>'tenant_id' THEN RAISE EXCEPTION 'Draft linkage unavailable';END IF;
  RETURN to_jsonb(d)||ctx||jsonb_build_object('exists',true);
 END IF;
 RETURN ctx||jsonb_build_object('exists',false,'id',null,'revision',0,'status','IN_PROGRESS','draft_narrative','','evidence_snapshot',jsonb_build_object('entities','[]'::jsonb,'txs','[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.coreaml_load_case_draft(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_load_case_draft(uuid) TO authenticated;

CREATE FUNCTION public.coreaml_case_action(p_alert_id uuid,p_action text,p_expected_revision integer,p_request_id uuid,p_narrative text DEFAULT NULL,p_snapshot jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE ctx jsonb;d public.investigation_drafts%ROWTYPE;r public.coreaml_case_actions%ROWTYPE;payload jsonb;result jsonb;pins jsonb;ids uuid[];changed integer;
BEGIN
 IF p_action NOT IN ('SAVE','CLOSE') OR p_action IS NULL OR p_request_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision<0 THEN RAISE EXCEPTION 'Invalid case action' USING ERRCODE='22023';END IF;
 ctx:=coreaml_private.case_workflow_context(p_alert_id,true);
 IF p_action='SAVE' THEN
  IF p_narrative IS NULL OR length(p_narrative)>20000 OR p_snapshot IS NULL THEN RAISE EXCEPTION 'Invalid draft content' USING ERRCODE='22023';END IF;
  payload:=jsonb_build_object('revision',p_expected_revision,'narrative',p_narrative,'snapshot',p_snapshot);
 ELSE
  IF p_narrative IS NOT NULL OR p_snapshot IS NOT NULL THEN RAISE EXCEPTION 'Close uses the saved draft' USING ERRCODE='22023';END IF;
  payload:=jsonb_build_object('revision',p_expected_revision);
 END IF;
 SELECT * INTO r FROM public.coreaml_case_actions WHERE request_id=p_request_id;
 IF FOUND THEN
  IF r.actor_id IS DISTINCT FROM (ctx->>'actor_id')::uuid OR r.case_reference IS DISTINCT FROM ctx->>'case_reference' OR r.tenant_id IS DISTINCT FROM ctx->>'tenant_id' THEN RAISE EXCEPTION 'Request reference unavailable' USING ERRCODE='42501';END IF;
  IF r.action<>p_action OR r.payload IS DISTINCT FROM payload THEN RAISE EXCEPTION 'Request reference reused with different content' USING ERRCODE='22023';END IF;
  RETURN r.result||jsonb_build_object('replayed',true);
 END IF;
 IF ctx->>'case_status'<>'INVESTIGATING' THEN RAISE EXCEPTION 'Case is no longer open';END IF;
 SELECT * INTO d FROM public.investigation_drafts WHERE alert_id=(ctx->>'alert_id')::uuid AND investigator_id=(ctx->>'owner_id')::uuid FOR UPDATE;
 IF FOUND THEN
  IF d.case_reference IS DISTINCT FROM ctx->>'case_reference' OR d.tenant_id IS DISTINCT FROM ctx->>'tenant_id' OR d.status<>'IN_PROGRESS' THEN RAISE EXCEPTION 'Draft is unavailable for editing';END IF;
  IF d.revision<>p_expected_revision THEN RAISE EXCEPTION 'Draft revision conflict';END IF;
 ELSE
  IF p_expected_revision<>0 OR p_action='CLOSE' THEN RAISE EXCEPTION 'Draft revision conflict or missing draft';END IF;
 END IF;
 IF p_action='SAVE' THEN
  pins:=coreaml_private.case_workflow_pins(p_snapshot,ctx->>'tenant_id');
  IF d.id IS NULL THEN
   INSERT INTO public.investigation_drafts(id,tenant_id,alert_id,investigator_id,case_reference,revision,draft_narrative,evidence_snapshot,status,created_at,updated_at)
   VALUES(gen_random_uuid(),ctx->>'tenant_id',(ctx->>'alert_id')::uuid,(ctx->>'owner_id')::uuid,ctx->>'case_reference',1,p_narrative,pins,'IN_PROGRESS',clock_timestamp(),clock_timestamp()) RETURNING * INTO d;
  ELSE
   UPDATE public.investigation_drafts SET draft_narrative=p_narrative,evidence_snapshot=pins,revision=revision+1,updated_at=clock_timestamp() WHERE id=d.id RETURNING * INTO d;
  END IF;
 ELSE
  IF length(btrim(coalesce(d.draft_narrative,'')))<15 THEN RAISE EXCEPTION 'A saved case narrative of at least 15 characters is required';END IF;
  SELECT array_agg(value::uuid) INTO ids FROM jsonb_array_elements_text(ctx->'alert_ids');
  UPDATE public.alerts SET status='CLOSED' WHERE id=ANY(ids) AND status='INVESTIGATING' AND case_reference=ctx->>'case_reference' AND assigned_user_id=(ctx->>'owner_id')::uuid AND tenant_id=ctx->>'tenant_id';
  GET DIAGNOSTICS changed=ROW_COUNT;
  IF changed<>cardinality(ids) THEN RAISE EXCEPTION 'Incomplete closure; no case changes committed';END IF;
  UPDATE public.investigation_drafts SET status='CLOSED',revision=revision+1,closed_at=clock_timestamp(),updated_at=clock_timestamp() WHERE id=d.id RETURNING * INTO d;
 END IF;
 result:=jsonb_build_object('request_id',p_request_id,'id',d.id,'alert_id',d.alert_id,'case_reference',d.case_reference,'revision',d.revision,'status',d.status,'replayed',false);
 INSERT INTO public.coreaml_case_actions(request_id,case_reference,actor_id,tenant_id,action,payload,result)
 VALUES(p_request_id,ctx->>'case_reference',(ctx->>'actor_id')::uuid,ctx->>'tenant_id',p_action,payload,result);
 INSERT INTO public.system_events(event_type,severity,message,tenant_id,user_id,metadata)
 VALUES(CASE WHEN p_action='SAVE' THEN 'CASE_DRAFT_SAVED' ELSE 'CASE_CLOSED' END,'INFO',CASE WHEN p_action='SAVE' THEN 'Case draft saved' ELSE 'Claimed case closed' END,
 (ctx->>'tenant_id')::uuid,(ctx->>'actor_id')::uuid,jsonb_build_object('case_ref',ctx->>'case_reference','anchor_alert_id',ctx->>'alert_id','request_id',p_request_id,'revision',d.revision));
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_case_action(uuid,text,integer,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_action(uuid,text,integer,uuid,text,jsonb) TO authenticated;

CREATE FUNCTION coreaml_private.guard_managed_draft() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF current_user IN ('authenticated','anon') THEN RAISE EXCEPTION 'Case drafts are server managed' USING ERRCODE='42501';END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.guard_managed_draft() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER coreaml_guard_managed_draft BEFORE INSERT OR UPDATE OR DELETE ON public.investigation_drafts FOR EACH ROW EXECUTE FUNCTION coreaml_private.guard_managed_draft();
CREATE OR REPLACE FUNCTION coreaml_private.guard_case_ownership() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF TG_OP='DELETE' THEN
  IF current_user IN ('authenticated','anon') AND OLD.case_reference IS NOT NULL THEN RAISE EXCEPTION 'Claimed alerts are server managed' USING ERRCODE='42501';END IF;
  RETURN OLD;
 END IF;
 IF current_user IN ('authenticated','anon') AND (
  (OLD.case_reference IS NOT NULL AND to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD))
  OR NEW.assigned_user_id IS DISTINCT FROM OLD.assigned_user_id OR NEW.case_reference IS DISTINCT FROM OLD.case_reference
  OR (NEW.status='INVESTIGATING' AND NEW.status IS DISTINCT FROM OLD.status)
 ) THEN RAISE EXCEPTION 'Claimed alerts are server managed' USING ERRCODE='42501';END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.guard_case_ownership() FROM PUBLIC,anon,authenticated;
DROP TRIGGER coreaml_guard_case_ownership ON public.alerts;
CREATE TRIGGER coreaml_guard_case_ownership BEFORE UPDATE OR DELETE ON public.alerts FOR EACH ROW EXECUTE FUNCTION coreaml_private.guard_case_ownership();
NOTIFY pgrst,'reload schema';
