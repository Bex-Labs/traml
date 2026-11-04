-- Local-only integration of the five configured rule snapshots. No filing policy.
DO $pre$ BEGIN
 IF to_regclass('public.coreaml_rule_sets') IS NOT NULL OR to_regclass('public.coreaml_compatible_sets') IS NOT NULL THEN RAISE EXCEPTION 'Other/partial AML foundation exists; refusing overwrite';END IF;
 IF EXISTS(SELECT 1 FROM public.aml_rules) THEN RAISE EXCEPTION 'Legacy local rules must be reconciled first';END IF;
 IF to_regclass('public.transaction_evaluation_outbox') IS NULL THEN RAISE EXCEPTION 'Cash outbox required';END IF;
END $pre$;
CREATE FUNCTION coreaml_private.compatible_bank_access(p_tenant text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.is_active AND p.tenant_id=p_tenant AND p.role IN ('compliance_officer','head_of_compliance','bank_manager'));
$$;
REVOKE ALL ON FUNCTION coreaml_private.compatible_bank_access(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION coreaml_private.compatible_bank_access(text) TO authenticated;
GRANT USAGE ON SCHEMA coreaml_private TO authenticated;
CREATE FUNCTION coreaml_private.compatible_account_access(p_account uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(SELECT 1 FROM public.accounts a JOIN public.customers c ON c.id=a.customer_id JOIN public.user_profiles p ON p.id=auth.uid() AND p.is_active AND p.tenant_id=c.tenant_id WHERE a.id=p_account);
$$;
REVOKE ALL ON FUNCTION coreaml_private.compatible_account_access(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION coreaml_private.compatible_account_access(uuid) TO authenticated;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY compatible_transaction_bank_boundary ON public.transactions AS RESTRICTIVE FOR ALL TO authenticated USING(coreaml_private.compatible_account_access(account_id)) WITH CHECK(coreaml_private.compatible_account_access(account_id));
REVOKE ALL ON public.transactions FROM PUBLIC,anon;
REVOKE UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.transactions FROM authenticated;
GRANT SELECT ON public.transactions TO authenticated;
CREATE TABLE public.coreaml_compatible_sets(
 id uuid PRIMARY KEY,tenant_id text NOT NULL,account_id uuid NOT NULL UNIQUE REFERENCES public.accounts(id),
 version text NOT NULL CHECK(length(version) BETWEEN 1 AND 100),engine_version text NOT NULL CHECK(engine_version='coreaml-compatibility-preview-v1'),
 source_rules jsonb NOT NULL,tenant_mapping jsonb NOT NULL,rules jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.coreaml_compatible_runs(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),transaction_id uuid NOT NULL UNIQUE REFERENCES public.transactions(id),
 set_id uuid NOT NULL REFERENCES public.coreaml_compatible_sets(id),tenant_id text NOT NULL,
 state text NOT NULL CHECK(state IN ('EVALUATED','POLICY_BLOCKED')),snapshot jsonb NOT NULL,outcomes jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.coreaml_compatible_results(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),run_id uuid NOT NULL REFERENCES public.coreaml_compatible_runs(id),tenant_id text NOT NULL,
 transaction_id uuid NOT NULL REFERENCES public.transactions(id),source_rule_id uuid NOT NULL,outcome text NOT NULL,
 matched boolean,alert_id uuid REFERENCES public.alerts(id),evidence jsonb NOT NULL,UNIQUE(run_id,source_rule_id)
);
ALTER TABLE public.transaction_evaluation_outbox ADD COLUMN compatible_set_id uuid REFERENCES public.coreaml_compatible_sets(id),ADD COLUMN compatible_state text CHECK(compatible_state IN ('EVALUATED','POLICY_BLOCKED','FAILED'));
CREATE INDEX coreaml_compatible_runs_bank ON public.coreaml_compatible_runs(tenant_id,created_at);
CREATE INDEX coreaml_compatible_results_bank ON public.coreaml_compatible_results(tenant_id,transaction_id);
CREATE INDEX coreaml_compatible_tx_history ON public.transactions(account_id,transaction_timestamp,id);
DO $rls$ DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY['coreaml_compatible_sets','coreaml_compatible_runs','coreaml_compatible_results'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);
  EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t);
  EXECUTE format('CREATE POLICY compatible_bank_read ON public.%I FOR SELECT TO authenticated USING(coreaml_private.compatible_bank_access(tenant_id))',t);
 END LOOP;
 FOREACH t IN ARRAY ARRAY['alerts','aml_rules','report_archives'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY compatible_bank_boundary ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING(coreaml_private.compatible_bank_access(tenant_id)) WITH CHECK(coreaml_private.compatible_bank_access(tenant_id))',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon',t);
 END LOOP;
END $rls$;
ALTER TABLE public.risk_score_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY compatible_bank_boundary ON public.risk_score_history AS RESTRICTIVE FOR ALL TO authenticated
 USING(EXISTS(SELECT 1 FROM public.customers c WHERE c.id=risk_score_history.customer_id AND coreaml_private.compatible_bank_access(c.tenant_id)))
 WITH CHECK(EXISTS(SELECT 1 FROM public.customers c WHERE c.id=risk_score_history.customer_id AND coreaml_private.compatible_bank_access(c.tenant_id)));
REVOKE ALL ON public.risk_score_history FROM PUBLIC,anon;
REVOKE UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.risk_score_history FROM authenticated;
CREATE INDEX IF NOT EXISTS coreaml_compatible_risk_customer ON public.risk_score_history(customer_id);
REVOKE INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.aml_rules,public.report_archives FROM authenticated;
REVOKE DELETE,TRUNCATE,REFERENCES,TRIGGER ON public.alerts FROM authenticated;
-- Keep manual entity-review inserts and QA narrative updates; forbid fabricated detections.
GRANT INSERT ON public.alerts TO authenticated;
CREATE FUNCTION coreaml_private.compatible_alert_guard() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_bank text;
BEGIN
 IF current_user='authenticated' THEN
  IF TG_OP='INSERT' THEN
   IF coalesce(NEW.rule_triggered,'')<>'Manual Entity Review' OR coalesce(NEW.status,'')<>'INVESTIGATING' OR NEW.transaction_id IS NOT NULL OR NEW.customer_id IS NULL OR coalesce(NEW.evidence,'{}'::jsonb)<>'{}'::jsonb OR NEW.idempotency_key IS NOT NULL THEN RAISE EXCEPTION 'Automated detections are server managed' USING ERRCODE='42501';END IF;
   SELECT tenant_id INTO v_bank FROM public.customers WHERE id=NEW.customer_id;
   IF NOT coreaml_private.compatible_bank_access(v_bank) OR (NEW.tenant_id IS NOT NULL AND NEW.tenant_id IS DISTINCT FROM v_bank) THEN RAISE EXCEPTION 'Manual customer unavailable' USING ERRCODE='42501';END IF;
   NEW.tenant_id:=v_bank;NEW.severity:='HIGH';NEW.details:='Manual investigation initiated directly from 360° Profile.';
   NEW.evidence:=jsonb_build_object('method','MANUAL_ENTITY_REVIEW','created_by',auth.uid(),'customer_id',NEW.customer_id,'tenant_id',v_bank);
   NEW.idempotency_key:='MANUAL:'||NEW.id::text;
  ELSIF (OLD.id,OLD.tenant_id,OLD.customer_id,OLD.transaction_id,OLD.rule_triggered,OLD.evidence,OLD.idempotency_key) IS DISTINCT FROM (NEW.id,NEW.tenant_id,NEW.customer_id,NEW.transaction_id,NEW.rule_triggered,NEW.evidence,NEW.idempotency_key) THEN RAISE EXCEPTION 'Detection evidence is server managed' USING ERRCODE='42501';END IF;
 END IF;RETURN NEW;
END $$;
CREATE TRIGGER compatible_alert_guard BEFORE INSERT OR UPDATE ON public.alerts FOR EACH ROW EXECUTE FUNCTION coreaml_private.compatible_alert_guard();
CREATE FUNCTION coreaml_private.compatible_immutable() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN RAISE EXCEPTION 'Compatible evaluation evidence is immutable' USING ERRCODE='22023';END $$;
CREATE TRIGGER compatible_immutable_run BEFORE UPDATE OR DELETE ON public.coreaml_compatible_runs FOR EACH ROW EXECUTE FUNCTION coreaml_private.compatible_immutable();
CREATE TRIGGER compatible_immutable_result BEFORE UPDATE OR DELETE ON public.coreaml_compatible_results FOR EACH ROW EXECUTE FUNCTION coreaml_private.compatible_immutable();
CREATE FUNCTION coreaml_private.compatible_seal() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE r jsonb;v_rules jsonb;v_keys integer;
BEGIN
 IF TG_OP<>'INSERT' THEN RAISE EXCEPTION 'Compatible set is immutable' USING ERRCODE='22023';END IF;
 IF current_user<>'postgres' THEN RAISE EXCEPTION 'Local root worker only' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.accounts a JOIN public.customers c ON c.id=a.customer_id WHERE a.id=NEW.account_id AND c.tenant_id=NEW.tenant_id AND a.status::text='ACTIVE' AND a.currency='NGN' AND c.kyc_status='COMPLETED' AND c.first_name='Synthetic' AND c.last_name~'^AmlCompatTest[0-9a-f]{8}$') THEN RAISE EXCEPTION 'Dedicated completed compatible fixture required';END IF;
 IF jsonb_typeof(NEW.source_rules) IS DISTINCT FROM 'array' OR jsonb_array_length(NEW.source_rules) NOT BETWEEN 1 AND 20 THEN RAISE EXCEPTION 'Bounded nonempty source rules required';END IF;
 IF jsonb_typeof(NEW.tenant_mapping) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Explicit tenant mapping required';END IF;
 SELECT count(*) INTO v_keys FROM jsonb_object_keys(NEW.tenant_mapping);
 IF v_keys<>2 OR NEW.tenant_mapping IS DISTINCT FROM jsonb_build_object('bank-alpha',NEW.tenant_id,'SYSTEM_GLOBAL','SYSTEM_GLOBAL') THEN RAISE EXCEPTION 'Explicit bank-alpha and global mapping required';END IF;
 FOR r IN SELECT * FROM jsonb_array_elements(NEW.source_rules) LOOP
  IF coalesce(r->>'tenant_id','') NOT IN ('bank-alpha','SYSTEM_GLOBAL') OR r->>'id' IS NULL OR r->>'rule_name' IS NULL OR r->>'condition_type' IS NULL THEN RAISE EXCEPTION 'Invalid source rule';END IF;
  PERFORM (r->>'id')::uuid;
 END LOOP;
 IF (SELECT count(DISTINCT src->>'id') FROM jsonb_array_elements(NEW.source_rules) src)<>jsonb_array_length(NEW.source_rules) THEN RAISE EXCEPTION 'Duplicate rule id';END IF;
 SELECT jsonb_agg(src||jsonb_build_object('tenant_id',NEW.tenant_mapping->>(src->>'tenant_id')) ORDER BY src->>'id') INTO v_rules FROM jsonb_array_elements(NEW.source_rules) src;
 NEW.rules:=v_rules;RETURN NEW;
END $$;
CREATE TRIGGER compatible_seal BEFORE INSERT OR UPDATE OR DELETE ON public.coreaml_compatible_sets FOR EACH ROW EXECUTE FUNCTION coreaml_private.compatible_seal();
-- Serialize fixture history with cash posting; once evaluated, old history is sealed.
CREATE FUNCTION coreaml_private.compatible_history_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_account uuid;v_old uuid;v_last timestamptz;
BEGIN
 IF current_setting('role',true) IN ('anon','authenticated') AND auth.uid() IS NULL THEN RAISE EXCEPTION 'Authenticated actor required' USING ERRCODE='42501';END IF;
 IF TG_OP<>'INSERT' THEN v_old:=OLD.account_id;END IF;
 IF TG_OP='DELETE' THEN v_account:=OLD.account_id;ELSE v_account:=NEW.account_id;END IF;
 IF EXISTS(SELECT 1 FROM public.coreaml_compatible_sets WHERE account_id IN (v_account,v_old)) THEN
  IF TG_OP='UPDATE' AND (NEW.id IS DISTINCT FROM OLD.id OR NEW.account_id IS DISTINCT FROM OLD.account_id) THEN RAISE EXCEPTION 'Registered transaction identity is sealed';END IF;
  PERFORM 1 FROM public.accounts WHERE id=v_account FOR UPDATE;
  SELECT max(t.transaction_timestamp) INTO v_last FROM public.coreaml_compatible_runs r JOIN public.transactions t ON t.id=r.transaction_id JOIN public.coreaml_compatible_sets s ON s.id=r.set_id WHERE s.account_id=v_account;
  IF v_last IS NOT NULL AND (TG_OP<>'INSERT' OR NEW.transaction_timestamp<=v_last) THEN RAISE EXCEPTION 'Evaluated fixture history is sealed';END IF;
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD;END IF;RETURN NEW;
END $$;
CREATE TRIGGER compatible_history_guard BEFORE INSERT OR UPDATE OR DELETE ON public.transactions FOR EACH ROW EXECUTE FUNCTION coreaml_private.compatible_history_guard();
CREATE FUNCTION coreaml_private.compatible_tx_json(p_id uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT jsonb_build_object('id',t.id,'account_id',t.account_id,'tenant_id',c.tenant_id,'amount',t.amount::numeric(16,2)::text,'currency',t.currency,'transaction_type',t.transaction_type::text,'channel',t.channel::text,'transaction_timestamp',to_char(t.transaction_timestamp AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),'transaction_reference',t.transaction_reference)
 FROM public.transactions t JOIN public.accounts a ON a.id=t.account_id JOIN public.customers c ON c.id=a.customer_id WHERE t.id=p_id;
$$;
CREATE FUNCTION coreaml_private.compatible_snapshot(p_set uuid,p_tx uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE s public.coreaml_compatible_sets%rowtype;v_tx jsonb;v_hist jsonb;v_customer uuid;v_count integer;
BEGIN
 IF current_user<>'postgres' THEN RAISE EXCEPTION 'Local worker only' USING ERRCODE='42501';END IF;
 SELECT * INTO s FROM public.coreaml_compatible_sets WHERE id=p_set;IF NOT FOUND THEN RAISE EXCEPTION 'Set unavailable';END IF;
 SELECT c.id INTO v_customer FROM public.accounts a JOIN public.customers c ON c.id=a.customer_id WHERE a.id=s.account_id AND c.tenant_id=s.tenant_id AND c.first_name='Synthetic' AND c.last_name~'^AmlCompatTest[0-9a-f]{8}$' AND c.kyc_status='COMPLETED';IF NOT FOUND THEN RAISE EXCEPTION 'Fixture scope unavailable';END IF;
 v_tx:=coreaml_private.compatible_tx_json(p_tx);
 IF v_tx IS NULL OR v_tx->>'account_id'<>s.account_id::text OR v_tx->>'tenant_id'<>s.tenant_id THEN RAISE EXCEPTION 'Transaction scope mismatch' USING ERRCODE='42501';END IF;
 IF EXISTS(SELECT 1 FROM public.transactions WHERE account_id=s.account_id AND transaction_timestamp<>date_trunc('milliseconds',transaction_timestamp)) THEN RAISE EXCEPTION 'Fixture requires explicit millisecond timestamps before sealing';END IF;
 SELECT count(*) INTO v_count FROM public.transactions t WHERE t.account_id=s.account_id AND t.transaction_timestamp<=(SELECT transaction_timestamp FROM public.transactions WHERE id=p_tx);
 IF v_count>5000 THEN RAISE EXCEPTION 'Fixture history exceeds bounded worker limit';END IF;
 SELECT coalesce(jsonb_agg(coreaml_private.compatible_tx_json(t.id) ORDER BY t.transaction_timestamp,t.id),'[]'::jsonb) INTO v_hist FROM public.transactions t WHERE t.account_id=s.account_id AND t.transaction_timestamp<=(SELECT transaction_timestamp FROM public.transactions WHERE id=p_tx);
 RETURN jsonb_build_object('set_id',s.id,'tenant_id',s.tenant_id,'account_id',s.account_id,'customer_id',v_customer,'engine_version',s.engine_version,'source_rules',s.source_rules,'tenant_mapping',s.tenant_mapping,'rules',s.rules,'current',v_tx,'history',v_hist);
END $$;
-- Rule ID and immutable snapshot replace the stale/name-only alert factory path.
CREATE FUNCTION coreaml_private.compatible_create_alert(p_snapshot jsonb,p_outcome jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE v_id uuid;v_severity text;v_tier text;v_rule jsonb:=p_outcome->'rule_snapshot';v_key text;
BEGIN
 IF current_user<>'postgres' THEN RAISE EXCEPTION 'Local worker only' USING ERRCODE='42501';END IF;
 IF p_outcome->>'outcome'<>'ALERT_CANDIDATE' OR v_rule->>'mode'<>'ACTIVE' OR v_rule->>'condition_type'='STATIC_THRESHOLD' THEN RAISE EXCEPTION 'Only active non-CTR alerts can persist';END IF;
 SELECT risk_tier::text INTO v_tier FROM public.customers WHERE id=(p_snapshot->>'customer_id')::uuid AND tenant_id=p_snapshot->>'tenant_id';IF NOT FOUND THEN RAISE EXCEPTION 'Alert customer unavailable';END IF;
 v_severity:=CASE v_rule->>'condition_type' WHEN 'VELOCITY_COUNT' THEN 'MEDIUM' WHEN 'AMOUNT_ABOVE' THEN 'CRITICAL' ELSE 'HIGH' END;
 v_severity:=public.calculate_alert_severity(v_severity,coalesce(v_tier,'LOW'));
 v_key:='COMPAT:'||(p_snapshot->>'set_id')||':'||(p_snapshot#>>'{current,id}')||':'||(v_rule->>'id');
 INSERT INTO public.alerts(alert_ref,customer_id,transaction_id,tenant_id,rule_triggered,severity,status,details,evidence,idempotency_key)
 VALUES('ALT-'||upper(substr(gen_random_uuid()::text,1,8)),(p_snapshot->>'customer_id')::uuid,(p_snapshot#>>'{current,id}')::uuid,p_snapshot->>'tenant_id',v_rule->>'rule_name',v_severity,'UNASSIGNED',
 '[LOCAL SYNTHETIC COMPATIBILITY] '||(v_rule->>'rule_name')||': '||coalesce(p_outcome#>>'{evidence,comparison}','dormancy')||'; amount='||(p_snapshot#>>'{current,amount}')||'; currency='||(p_snapshot#>>'{current,currency}')||'; threshold='||coalesce(p_outcome#>>'{evidence,threshold}',p_outcome#>>'{evidence,threshold_count}',p_outcome#>>'{evidence,threshold_days}','n/a')||'; count='||coalesce(p_outcome#>>'{evidence,transaction_count}','n/a')||'; volume_minor_units='||coalesce(p_outcome#>>'{evidence,total_minor_units}','n/a')||'; inactive_days='||coalesce(p_outcome#>>'{evidence,inactive_days}','n/a')||'; window='||coalesce(p_outcome#>>'{evidence,window_start}','n/a')||' to '||coalesce(p_outcome#>>'{evidence,window_end}','n/a'),
 p_outcome||jsonb_build_object('set_id',p_snapshot->>'set_id','tenant_id',p_snapshot->>'tenant_id','customer_id',p_snapshot->>'customer_id','transaction_reference',p_snapshot#>>'{current,transaction_reference}','filing_status','NOT_FILED'),v_key) RETURNING id INTO v_id;
 RETURN v_id;
END $$;
CREATE FUNCTION coreaml_private.compatible_commit(p_set uuid,p_tx uuid,p_snapshot jsonb,p_outcomes jsonb,p_retry boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE s public.coreaml_compatible_sets%rowtype;q public.transaction_evaluation_outbox%rowtype;saved public.coreaml_compatible_runs%rowtype;r jsonb;v_run uuid;v_alert uuid;v_state text;v_fresh jsonb;v_rule jsonb;v_code text;
BEGIN
 IF current_user<>'postgres' THEN RAISE EXCEPTION 'Local worker only' USING ERRCODE='42501';END IF;
 SELECT * INTO s FROM public.coreaml_compatible_sets WHERE id=p_set;IF NOT FOUND THEN RAISE EXCEPTION 'Set unavailable';END IF;
 PERFORM 1 FROM public.accounts WHERE id=s.account_id FOR UPDATE;
 SELECT * INTO q FROM public.transaction_evaluation_outbox WHERE transaction_id=p_tx FOR UPDATE;
 IF NOT FOUND OR q.tenant_id<>s.tenant_id OR NOT EXISTS(SELECT 1 FROM public.transactions WHERE id=p_tx AND account_id=s.account_id) THEN RAISE EXCEPTION 'Receipt scope mismatch' USING ERRCODE='42501';END IF;
 IF q.compatible_set_id IS NOT NULL AND q.compatible_set_id<>p_set THEN RAISE EXCEPTION 'Receipt version mismatch';END IF;
 IF q.status='DONE' THEN
  SELECT * INTO saved FROM public.coreaml_compatible_runs WHERE transaction_id=p_tx AND set_id=p_set;
  IF NOT FOUND OR saved.snapshot IS DISTINCT FROM p_snapshot OR saved.outcomes IS DISTINCT FROM p_outcomes OR coreaml_private.compatible_snapshot(p_set,p_tx) IS DISTINCT FROM saved.snapshot OR (SELECT count(*) FROM public.coreaml_compatible_results WHERE run_id=saved.id)<>jsonb_array_length(s.rules) THEN RAISE EXCEPTION 'Completed evidence mismatch';END IF;
  RETURN jsonb_build_object('status','REPLAY','run_id',saved.id,'state',saved.state);
 END IF;
 IF EXISTS(SELECT 1 FROM public.transaction_evaluation_outbox prev JOIN public.transactions pt ON pt.id=prev.transaction_id JOIN public.transactions cur ON cur.id=p_tx WHERE pt.account_id=s.account_id AND (pt.transaction_timestamp,pt.id)<(cur.transaction_timestamp,cur.id) AND prev.status<>'DONE') THEN RAISE EXCEPTION 'Earlier fixture receipt must be processed first';END IF;
 IF q.status NOT IN ('PENDING','FAILED') OR (q.status='FAILED' AND NOT p_retry) OR q.attempts>=3 THEN RAISE EXCEPTION 'Explicit bounded failed retry required';END IF;
 BEGIN
  v_fresh:=coreaml_private.compatible_snapshot(p_set,p_tx);
  IF v_fresh IS DISTINCT FROM p_snapshot THEN RAISE EXCEPTION 'Stale snapshot; recalculate before retry' USING ERRCODE='40001';END IF;
  IF jsonb_typeof(p_outcomes) IS DISTINCT FROM 'array' OR jsonb_array_length(p_outcomes)<>jsonb_array_length(s.rules) OR (SELECT count(DISTINCT x->>'rule_id') FROM jsonb_array_elements(p_outcomes) x)<>jsonb_array_length(s.rules) THEN RAISE EXCEPTION 'Complete unique rule outcomes required';END IF;
  v_state:=CASE WHEN EXISTS(SELECT 1 FROM jsonb_array_elements(p_outcomes) x WHERE x->>'outcome'='POLICY_REVIEW_REQUIRED') THEN 'POLICY_BLOCKED' ELSE 'EVALUATED' END;
  INSERT INTO public.coreaml_compatible_runs(transaction_id,set_id,tenant_id,state,snapshot,outcomes)VALUES(p_tx,p_set,s.tenant_id,v_state,p_snapshot,p_outcomes)RETURNING id INTO v_run;
  FOR r IN SELECT * FROM jsonb_array_elements(p_outcomes) LOOP
   SELECT x INTO v_rule FROM jsonb_array_elements(s.rules) x WHERE x->>'id'=r->>'rule_id';
   IF NOT FOUND OR v_rule IS DISTINCT FROM r->'rule_snapshot' OR r->>'transaction_id'<>p_tx::text OR r->'transaction_snapshot' IS DISTINCT FROM p_snapshot->'current' OR r->>'engine_version'<>s.engine_version OR coalesce(r->>'outcome','') NOT IN ('NO_MATCH','FILTERED','INACTIVE','OUT_OF_SCOPE','SHADOW_MATCH','ALERT_CANDIDATE','POLICY_REVIEW_REQUIRED') THEN RAISE EXCEPTION 'Invalid rule result or linkage';END IF;
   IF (v_rule->>'condition_type'='STATIC_THRESHOLD') IS DISTINCT FROM (r->>'outcome'='POLICY_REVIEW_REQUIRED') THEN RAISE EXCEPTION 'CTR must remain policy blocked';END IF;
   v_alert:=NULL;
   IF r->>'outcome'='ALERT_CANDIDATE' THEN v_alert:=coreaml_private.compatible_create_alert(p_snapshot,r);END IF;
   INSERT INTO public.coreaml_compatible_results(run_id,tenant_id,transaction_id,source_rule_id,outcome,matched,alert_id,evidence)
   VALUES(v_run,s.tenant_id,p_tx,(r->>'rule_id')::uuid,CASE WHEN v_alert IS NOT NULL THEN 'ALERT' ELSE r->>'outcome' END,(r->>'matched')::boolean,v_alert,r);
  END LOOP;
  UPDATE public.transaction_evaluation_outbox SET status='DONE',attempts=attempts+1,evaluated_at=now(),last_error=NULL,compatible_set_id=p_set,compatible_state=v_state WHERE transaction_id=p_tx;
  RETURN jsonb_build_object('status','PROCESSED','run_id',v_run,'state',v_state);
 EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_code=RETURNED_SQLSTATE;
  UPDATE public.transaction_evaluation_outbox SET status='FAILED',attempts=attempts+1,last_error=v_code||': '||SQLERRM,compatible_set_id=p_set,compatible_state='FAILED' WHERE transaction_id=p_tx;
  RETURN jsonb_build_object('status','FAILED','error_code',v_code);
 END;
END $$;
-- These legacy privileged endpoints have no bank/caller checks. A governed RPC is separate work.
DO $acl$ DECLARE proc record;BEGIN
 FOR proc IN SELECT f.oid::regprocedure sig FROM pg_proc f JOIN pg_namespace n ON n.oid=f.pronamespace WHERE n.nspname='public' AND f.proname IN ('get_rolling_tx_stats','get_rolling_tx_volume','update_risk_tier','create_alert') LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',proc.sig);END LOOP;
 FOR proc IN SELECT f.oid::regprocedure sig FROM pg_proc f JOIN pg_namespace n ON n.oid=f.pronamespace WHERE n.nspname='coreaml_private' AND f.proname LIKE 'compatible_%' LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',proc.sig);END LOOP;
END $acl$;
GRANT EXECUTE ON FUNCTION coreaml_private.compatible_bank_access(text) TO authenticated;

GRANT EXECUTE ON FUNCTION coreaml_private.compatible_account_access(uuid) TO authenticated;
