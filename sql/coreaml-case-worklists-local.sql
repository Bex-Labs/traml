CREATE FUNCTION public.coreaml_case_worklist(p_kind text DEFAULT 'CASES',p_search text DEFAULT '',p_status text DEFAULT 'ALL',p_owner text DEFAULT 'ALL',p_from timestamptz DEFAULT NULL,p_until timestamptz DEFAULT NULL,p_offset integer DEFAULT 0,p_limit integer DEFAULT 25)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;result jsonb;pattern text;
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF p_kind IS NULL OR p_kind NOT IN ('CASES','QA','EXECUTIVE') OR p_search IS NULL OR length(p_search)>120 OR p_status IS NULL OR p_status NOT IN ('ALL','INVESTIGATING','PENDING_QA_REVIEW','ESCALATED','CLOSED','MIXED') OR p_owner IS NULL OR p_owner NOT IN ('ALL','MINE') OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 OR p_limit IS NULL OR p_limit<1 OR p_limit>50 OR (p_from IS NOT NULL AND p_until IS NOT NULL AND p_from>=p_until) THEN RAISE EXCEPTION 'Invalid worklist filters' USING ERRCODE='22023';END IF;
 IF p_kind<>'CASES' AND staff.role<>'head_of_compliance' THEN RAISE EXCEPTION 'Head-of-compliance review access required' USING ERRCODE='42501';END IF;
 pattern:='%'||replace(replace(replace(btrim(p_search),E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_')||'%';
 WITH managed AS (
 SELECT c.*,a.customer_id,a.rule_triggered,a.severity,coalesce(nullif(cu.entity_name,''),nullif(btrim(concat_ws(' ',cu.first_name,cu.last_name)),''),'Unlinked case') AS entity_name,
 left(coalesce(p.full_name,''),200) AS owner_name,g.member_count,g.status,g.consistent
 FROM public.coreaml_case_claims c JOIN public.alerts a ON a.id=c.anchor_alert_id AND a.tenant_id=c.tenant_id
 LEFT JOIN public.customers cu ON cu.id=a.customer_id AND cu.tenant_id=c.tenant_id
 LEFT JOIN public.user_profiles p ON p.id=c.investigator_id AND p.tenant_id=c.tenant_id
 CROSS JOIN LATERAL (SELECT count(*)::integer AS member_count,CASE WHEN count(DISTINCT x.status)=1 THEN min(x.status) ELSE 'MIXED' END AS status,
 count(*)=cardinality(c.alert_ids) AND count(DISTINCT x.status)=1 AS consistent
 FROM public.alerts x WHERE x.id=ANY(c.alert_ids) AND x.tenant_id=c.tenant_id AND x.assigned_user_id=c.investigator_id AND x.case_reference=c.case_reference AND x.customer_id IS NOT DISTINCT FROM a.customer_id) g
 WHERE c.tenant_id=staff.tenant_id AND cardinality(c.alert_ids) BETWEEN 1 AND 2000 AND c.anchor_alert_id=ANY(c.alert_ids)
 AND (p_kind='CASES' OR c.investigator_id<>staff.id) AND (staff.role='head_of_compliance' OR c.investigator_id=staff.id) AND (p_owner='ALL' OR c.investigator_id=staff.id)
 AND g.member_count=cardinality(c.alert_ids) AND (a.customer_id IS NULL OR cu.id IS NOT NULL)
 ), candidates AS (
 SELECT c.anchor_alert_id AS id,c.anchor_alert_id AS alert_id,c.case_reference,c.customer_id,c.entity_name,c.rule_triggered,c.severity,
 CASE WHEN c.consistent THEN c.status ELSE 'MIXED' END AS status,c.investigator_id AS owner_id,c.owner_name,c.member_count,c.consistent,
 CASE WHEN p_kind='QA' THEN s.created_at ELSE c.claimed_at END AS occurred_at
 FROM managed c LEFT JOIN LATERAL (SELECT max(created_at) AS created_at FROM public.coreaml_review_submissions WHERE case_reference=c.case_reference AND tenant_id=staff.tenant_id AND kind='QA') s ON true
 WHERE p_kind IN ('CASES','QA') AND (p_kind='CASES' OR (c.consistent AND c.status='PENDING_QA_REVIEW'))
 UNION ALL
 SELECT r.id,c.anchor_alert_id,c.case_reference,c.customer_id,c.entity_name,c.rule_triggered,c.severity,'PENDING_APPROVAL',c.investigator_id,c.owner_name,c.member_count,c.consistent,r.created_at
 FROM public.suspicious_transaction_reports r JOIN managed c ON r.alert_id=c.anchor_alert_id AND r.tenant_id=c.tenant_id AND r.generated_by=c.investigator_id
 WHERE p_kind='EXECUTIVE' AND r.status='PENDING_APPROVAL' AND r.locked_at IS NULL AND r.report_data->'alert_ids'=to_jsonb(c.alert_ids) AND c.consistent AND c.status='ESCALATED' AND r.report_data->>'case_reference'=c.case_reference
 ), filtered AS (
 SELECT * FROM candidates WHERE (p_status='ALL' OR status=p_status) AND (p_from IS NULL OR occurred_at>=p_from) AND (p_until IS NULL OR occurred_at<p_until)
 AND (case_reference ILIKE pattern ESCAPE E'\\' OR entity_name ILIKE pattern ESCAPE E'\\' OR rule_triggered ILIKE pattern ESCAPE E'\\')
 ), page AS (SELECT * FROM filtered ORDER BY occurred_at DESC NULLS LAST,id DESC OFFSET p_offset LIMIT p_limit)
 SELECT jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'kind',p_kind,'offset',p_offset,'limit',p_limit,'total',(SELECT count(*) FROM filtered),'rows',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY occurred_at DESC NULLS LAST,id DESC) FROM page x),'[]'::jsonb)) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_case_worklist(text,text,text,text,timestamptz,timestamptz,integer,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_worklist(text,text,text,text,timestamptz,timestamptz,integer,integer) TO authenticated;
NOTIFY pgrst,'reload schema';
