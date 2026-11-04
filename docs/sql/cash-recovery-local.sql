-- Local draft. Apply through the bounded local installer, never as a migration replay.
DO $pre$ BEGIN
 IF to_regprocedure('coreaml_private.post_cash_transaction_once(uuid,uuid,numeric,text,text,text)') IS NOT NULL
 OR to_regclass('coreaml_private.cash_request_results') IS NOT NULL THEN
  RAISE EXCEPTION 'Cash recovery is already installed or partial; refusing overwrite';
 END IF;
 IF to_regprocedure('coreaml_private.post_cash_transaction(uuid,uuid,numeric,text,text,text)') IS NULL
 OR to_regprocedure('coreaml_private.review_cash_transaction(uuid,boolean)') IS NULL THEN
  RAISE EXCEPTION 'Verified private cash foundation required';
 END IF;
END $pre$;
CREATE TABLE coreaml_private.cash_request_results(
 request_reference text PRIMARY KEY,
 actor_id uuid NOT NULL REFERENCES auth.users(id),
 tenant_id text NOT NULL,
 payload jsonb NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE coreaml_private.cash_request_results ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON coreaml_private.cash_request_results FROM PUBLIC,anon,authenticated;
ALTER FUNCTION coreaml_private.post_cash_transaction(uuid,uuid,numeric,text,text,text) RENAME TO post_cash_transaction_once;
REVOKE ALL ON FUNCTION coreaml_private.post_cash_transaction_once(uuid,uuid,numeric,text,text,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION coreaml_private.post_cash_transaction(p_account_id uuid,p_till_id uuid,p_amount numeric,p_direction text,p_narration text,p_request_reference text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid:=auth.uid();v_tenant text;v_role text;v_payload jsonb;v_saved coreaml_private.cash_request_results%rowtype;v_result jsonb;v_approval public.cash_transaction_approvals%rowtype;
BEGIN
 SELECT tenant_id,role INTO v_tenant,v_role FROM public.user_profiles WHERE id=v_actor AND is_active;
 IF v_actor IS NULL OR v_tenant IS NULL OR v_role NOT IN ('teller','sales_rep') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Cash posting is restricted to active tellers';END IF;
 IF p_account_id IS NULL OR p_till_id IS NULL OR p_amount IS NULL OR p_amount::text IN ('NaN','Infinity','-Infinity') OR p_amount<=0 OR p_amount>9999999999999.99 OR p_amount<>round(p_amount,2)
 OR p_direction IS NULL OR p_direction NOT IN ('DEPOSIT','WITHDRAWAL') OR p_request_reference IS NULL OR length(p_request_reference)<8 OR length(p_request_reference)>160 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Invalid cash transaction';END IF;
 v_payload:=jsonb_build_object('account_id',p_account_id,'till_id',p_till_id,'amount',p_amount,'direction',p_direction,'narration',p_narration);
 -- The reference lock precedes the existing account/till locks; all retries share it.
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('coreaml-cash:'||p_request_reference,0));
 SELECT * INTO v_saved FROM coreaml_private.cash_request_results WHERE request_reference=p_request_reference;
 IF FOUND THEN
  IF v_saved.actor_id<>v_actor OR v_saved.tenant_id<>v_tenant THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Cash reference unavailable';END IF;
  IF v_saved.payload IS DISTINCT FROM v_payload THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Cash reference already used with different details';END IF;
  v_result:=v_saved.result;
 ELSE
  v_result:=coreaml_private.post_cash_transaction_once(p_account_id,p_till_id,p_amount,p_direction,p_narration,p_request_reference);
  v_result:=v_result||jsonb_build_object('request_reference',p_request_reference);
  INSERT INTO coreaml_private.cash_request_results(request_reference,actor_id,tenant_id,payload,result) VALUES(p_request_reference,v_actor,v_tenant,v_payload,v_result);
 END IF;
 -- Confirmation never performs another posting, even if the till has since closed.
 IF v_result->>'status'='PENDING' THEN
  SELECT * INTO v_approval FROM public.cash_transaction_approvals WHERE id=(v_result->>'approval_id')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cash approval evidence missing';END IF;
  v_result:=v_result||jsonb_build_object('approval_status',v_approval.status,'transaction_id',v_approval.transaction_id);
 END IF;
 RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION coreaml_private.post_cash_transaction(uuid,uuid,numeric,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION coreaml_private.post_cash_transaction(uuid,uuid,numeric,text,text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.post_cash_transaction(p_account_id uuid,p_till_id uuid,p_amount numeric,p_direction text,p_narration text,p_request_reference text)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT coreaml_private.post_cash_transaction(p_account_id,p_till_id,p_amount,p_direction,p_narration,p_request_reference); $$;
REVOKE ALL ON FUNCTION public.post_cash_transaction(uuid,uuid,numeric,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.post_cash_transaction(uuid,uuid,numeric,text,text,text) TO authenticated;

ALTER FUNCTION coreaml_private.review_cash_transaction(uuid,boolean) RENAME TO review_cash_transaction_once;
REVOKE ALL ON FUNCTION coreaml_private.review_cash_transaction_once(uuid,boolean) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION coreaml_private.review_cash_transaction(p_approval_id uuid,p_approve boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_actor uuid:=auth.uid();v_tenant text;v_role text;v_request public.cash_transaction_approvals%rowtype;v_result jsonb;
BEGIN
 SELECT tenant_id,role INTO v_tenant,v_role FROM public.user_profiles WHERE id=v_actor AND is_active;
 IF v_actor IS NULL OR v_tenant IS NULL OR v_role<>'branch_manager' THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Branch manager approval required';END IF;
 IF p_approve IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Decision required';END IF;
 SELECT * INTO v_request FROM public.cash_transaction_approvals WHERE id=p_approval_id FOR UPDATE;
 IF NOT FOUND OR v_request.tenant_id<>v_tenant OR v_request.requested_by=v_actor THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Approval unavailable';END IF;
 IF v_request.status<>'PENDING' THEN
  IF v_request.reviewed_by IS DISTINCT FROM v_actor THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Approval unavailable';END IF;
  IF (p_approve AND v_request.status<>'APPROVED') OR (NOT p_approve AND v_request.status<>'REJECTED') THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Approval already reviewed with different decision';END IF;
  v_result:=CASE WHEN p_approve THEN jsonb_build_object('status','POSTED','transaction_id',v_request.transaction_id) ELSE jsonb_build_object('status','REJECTED') END;
 ELSE
  v_result:=coreaml_private.review_cash_transaction_once(p_approval_id,p_approve);
 END IF;
 RETURN v_result||jsonb_build_object('approval_id',p_approval_id,'decision',p_approve);
END $$;
REVOKE ALL ON FUNCTION coreaml_private.review_cash_transaction(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION coreaml_private.review_cash_transaction(uuid,boolean) TO authenticated;
CREATE OR REPLACE FUNCTION public.review_cash_transaction(p_approval_id uuid,p_approve boolean)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT coreaml_private.review_cash_transaction(p_approval_id,p_approve); $$;
REVOKE ALL ON FUNCTION public.review_cash_transaction(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.review_cash_transaction(uuid,boolean) TO authenticated;
