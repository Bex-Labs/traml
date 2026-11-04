-- Read-only canonical case history. No alert status or workflow record is changed.
CREATE FUNCTION public.coreaml_case_timeline(p_alert_id uuid,p_limit integer DEFAULT 25,p_before timestamptz DEFAULT NULL,p_before_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;c public.coreaml_case_claims%ROWTYPE;a public.alerts%ROWTYPE;events jsonb;more boolean;cursor jsonb;total integer;result jsonb;
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF p_alert_id IS NULL OR p_limit IS NULL OR p_limit<1 OR p_limit>50 OR (p_before IS NULL)<>(p_before_key IS NULL)
 OR (p_before_key IS NOT NULL AND p_before_key !~ '^(claim|action|submission|review):[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$') THEN RAISE EXCEPTION 'Invalid timeline page' USING ERRCODE='22023';END IF;
 SELECT * INTO c FROM public.coreaml_case_claims WHERE tenant_id=staff.tenant_id AND p_alert_id=ANY(alert_ids);
 IF NOT FOUND OR (staff.role<>'head_of_compliance' AND c.investigator_id<>staff.id) THEN RAISE EXCEPTION 'Case history unavailable' USING ERRCODE='42501';END IF;
 IF cardinality(c.alert_ids)<1 OR cardinality(c.alert_ids)>2000 OR NOT(c.anchor_alert_id=ANY(c.alert_ids))
 OR (SELECT count(DISTINCT id) FROM unnest(c.alert_ids) id)<>cardinality(c.alert_ids) THEN RAISE EXCEPTION 'Case membership unavailable' USING ERRCODE='42501';END IF;
 SELECT * INTO a FROM public.alerts WHERE id=c.anchor_alert_id AND tenant_id=staff.tenant_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Case anchor unavailable' USING ERRCODE='42501';END IF;
 IF a.customer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.customers WHERE id=a.customer_id AND tenant_id=staff.tenant_id) THEN RAISE EXCEPTION 'Case customer unavailable' USING ERRCODE='42501';END IF;
 SELECT count(*) INTO total FROM public.alerts x WHERE x.id=ANY(c.alert_ids) AND x.tenant_id=staff.tenant_id AND x.case_reference=c.case_reference AND x.assigned_user_id=c.investigator_id AND x.customer_id IS NOT DISTINCT FROM a.customer_id;
 IF total<>cardinality(c.alert_ids) THEN RAISE EXCEPTION 'Case membership changed' USING ERRCODE='42501';END IF;
 WITH history AS (
 SELECT 'claim:'||c.id::text AS event_key,c.claimed_at AS occurred_at,'CLAIMED'::text AS kind,c.investigator_id AS actor_id,NULL::uuid AS request_id,NULL::integer AS revision,NULL::text AS notes,'claim'::text AS source
 UNION ALL
 SELECT 'action:'||r.request_id::text,r.created_at,CASE WHEN r.action='SAVE' THEN 'DRAFT_SAVED' ELSE 'CASE_CLOSED' END,r.actor_id,r.request_id,(r.result->>'revision')::integer,NULL,'action_receipt'
 FROM public.coreaml_case_actions r WHERE r.case_reference=c.case_reference AND r.tenant_id=staff.tenant_id AND r.actor_id=c.investigator_id
 UNION ALL
 SELECT 'submission:'||s.request_id::text,s.created_at,CASE WHEN s.kind='QA' THEN 'QA_SUBMITTED' ELSE 'EXECUTIVE_SUBMITTED' END,s.actor_id,s.request_id,(s.result->>'revision')::integer,NULL,'submission_receipt'
 FROM public.coreaml_review_submissions s WHERE s.case_reference=c.case_reference AND s.tenant_id=staff.tenant_id AND s.actor_id=c.investigator_id
 UNION ALL
 SELECT 'review:'||r.request_id::text,r.created_at,r.kind||'_'||CASE WHEN r.decision='APPROVE' THEN 'APPROVED' ELSE 'RETURNED' END,r.actor_id,r.request_id,NULL,r.notes,'review_receipt'
 FROM public.coreaml_review_actions r WHERE r.case_reference=c.case_reference AND r.tenant_id=staff.tenant_id AND r.maker_id=c.investigator_id AND r.actor_id<>c.investigator_id
 ), page AS (
 SELECT h.*,left(nullif(btrim(p.full_name),''),200) AS actor_name FROM history h LEFT JOIN public.user_profiles p ON p.id=h.actor_id AND p.tenant_id=staff.tenant_id
 WHERE p_before IS NULL OR (h.occurred_at,h.event_key)<(p_before,p_before_key)
 ORDER BY h.occurred_at DESC,h.event_key DESC LIMIT p_limit+1
 ), ranked AS (SELECT *,row_number() OVER(ORDER BY occurred_at DESC,event_key DESC) AS rank FROM page)
 SELECT coalesce(jsonb_agg(to_jsonb(r)-'rank' ORDER BY occurred_at DESC,event_key DESC) FILTER(WHERE rank<=p_limit),'[]'::jsonb),coalesce(bool_or(rank>p_limit),false)
 INTO events,more FROM ranked r;
 IF more THEN cursor:=jsonb_build_object('at',events->(jsonb_array_length(events)-1)->>'occurred_at','key',events->(jsonb_array_length(events)-1)->>'event_key');ELSE cursor:=NULL;END IF;
 result:=jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'owner_id',c.investigator_id,'case_reference',c.case_reference,'alert_id',c.anchor_alert_id,'alert_ids',c.alert_ids,'entries',events,'has_more',more,'next_cursor',cursor);
 IF pg_column_size(result)>1048576 THEN RAISE EXCEPTION 'Timeline page exceeds display limit' USING ERRCODE='22023';END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_case_timeline(uuid,integer,timestamptz,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_timeline(uuid,integer,timestamptz,text) TO authenticated;
COMMENT ON FUNCTION public.coreaml_case_timeline(uuid,integer,timestamptz,text) IS 'Authorized read-only case history from claim and immutable workflow receipts; not a regulatory filing history.';
NOTIFY pgrst,'reload schema';
