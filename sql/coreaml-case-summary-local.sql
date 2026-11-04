CREATE FUNCTION public.coreaml_case_summary(p_alert_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE scope jsonb;page jsonb;history jsonb:='[]';draft public.investigation_drafts%ROWTYPE;owner_name text;subject jsonb;alerts jsonb;packages jsonb;result jsonb;
BEGIN
 -- Reuse the reviewed timeline boundary: trusted active role/bank, owner or head,
 -- exact complete membership, canonical reference and customer linkage.
 scope:=public.coreaml_case_timeline(p_alert_id,50);page:=scope;
 LOOP
  history:=history||(page->'entries');
  IF jsonb_array_length(history)>500 OR (jsonb_array_length(history)=500 AND (page->>'has_more')::boolean) THEN RAISE EXCEPTION 'Summary exceeds the 500-entry workflow history limit; no partial summary produced' USING ERRCODE='22023';END IF;
  EXIT WHEN NOT(page->>'has_more')::boolean;
  page:=public.coreaml_case_timeline(p_alert_id,50,(page->'next_cursor'->>'at')::timestamptz,page->'next_cursor'->>'key');
 END LOOP;
 SELECT * INTO draft FROM public.investigation_drafts d WHERE d.alert_id=(scope->>'alert_id')::uuid AND d.case_reference=scope->>'case_reference' AND d.tenant_id=scope->>'tenant_id' AND d.investigator_id=(scope->>'owner_id')::uuid;
 IF FOUND AND (jsonb_typeof(draft.evidence_snapshot) IS DISTINCT FROM 'object' OR jsonb_typeof(draft.evidence_snapshot->'entities') IS DISTINCT FROM 'array' OR jsonb_typeof(draft.evidence_snapshot->'txs') IS DISTINCT FROM 'array') THEN RAISE EXCEPTION 'Saved evidence pins are unavailable in a confirmed format' USING ERRCODE='22023';END IF;
 SELECT p.full_name INTO owner_name FROM public.user_profiles p WHERE p.id=(scope->>'owner_id')::uuid AND p.tenant_id=scope->>'tenant_id';
 SELECT jsonb_build_object('id',c.id,'name',coalesce(nullif(c.entity_name,''),nullif(btrim(concat_ws(' ',c.first_name,c.last_name)),''),'Name not recorded')) INTO subject
 FROM public.customers c JOIN public.alerts a ON a.customer_id=c.id WHERE a.id=(scope->>'alert_id')::uuid AND c.tenant_id=scope->>'tenant_id';
 SELECT jsonb_agg(jsonb_build_object('id',a.id,'reference',a.alert_ref,'rule',a.rule_triggered,'severity',a.severity,'status',a.status,'transaction_id',a.transaction_id,'created_at',a.created_at,'recorded_evidence_available',a.evidence IS NOT NULL AND a.evidence<>'{}'::jsonb) ORDER BY a.id) INTO alerts
 FROM public.alerts a WHERE a.id=ANY(ARRAY(SELECT jsonb_array_elements_text(scope->'alert_ids'))::uuid[]) AND a.tenant_id=scope->>'tenant_id';
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',r.id,'status',r.status,'created_at',r.created_at,'reviewed_by',r.reviewed_by,'reviewed_at',r.locked_at,'justification',r.executive_justification) ORDER BY r.created_at,r.id),'[]') INTO packages
 FROM (SELECT * FROM public.suspicious_transaction_reports r WHERE r.alert_id=(scope->>'alert_id')::uuid AND r.tenant_id=scope->>'tenant_id' AND r.generated_by=(scope->>'owner_id')::uuid AND r.report_data->>'case_reference'=scope->>'case_reference' AND r.report_data->'alert_ids'=scope->'alert_ids' ORDER BY r.created_at,r.id LIMIT 51) r;
 IF jsonb_array_length(packages)>50 THEN RAISE EXCEPTION 'Summary exceeds the 50-package limit; no partial summary produced' USING ERRCODE='22023';END IF;
 result:=jsonb_build_object('document_type','INTERNAL_INVESTIGATION_SUMMARY','regulatory_submission',false,'as_of',transaction_timestamp(),'actor_id',scope->>'actor_id','tenant_id',scope->>'tenant_id','case_reference',scope->>'case_reference','alert_id',scope->>'alert_id','alert_ids',scope->'alert_ids','owner_id',scope->>'owner_id','owner_name',owner_name,'subject',subject,
 'draft',CASE WHEN draft.id IS NULL THEN NULL ELSE jsonb_build_object('id',draft.id,'revision',draft.revision,'status',draft.status,'narrative',draft.draft_narrative,'pins',draft.evidence_snapshot,'saved_at',draft.updated_at) END,'alerts',alerts,'history',history,'history_complete',true,'report_packages',packages);
 IF pg_column_size(result)>2097152 THEN RAISE EXCEPTION 'Summary exceeds the 2 MiB display limit; no partial summary produced' USING ERRCODE='22023';END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_case_summary(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_summary(uuid) TO authenticated;
NOTIFY pgrst,'reload schema';
