CREATE FUNCTION public.coreaml_case_worklist_priority(p_kind text DEFAULT 'CASES',p_search text DEFAULT '',p_status text DEFAULT 'ALL',p_owner text DEFAULT 'ALL',p_from timestamptz DEFAULT NULL,p_until timestamptz DEFAULT NULL,p_offset integer DEFAULT 0,p_limit integer DEFAULT 25,p_sort text DEFAULT 'NEWEST',p_severity text DEFAULT 'ALL',p_min_hours integer DEFAULT 0,p_waiting_only boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE staff public.user_profiles%ROWTYPE;result jsonb;pattern text;as_of timestamptz:=transaction_timestamp();
BEGIN
 staff:=coreaml_private.case_workflow_staff(false);
 IF p_kind IS NULL OR p_kind NOT IN ('CASES','QA','EXECUTIVE') OR p_search IS NULL OR length(p_search)>120 OR p_status IS NULL OR p_status NOT IN ('ALL','INVESTIGATING','PENDING_QA_REVIEW','ESCALATED','CLOSED','MIXED') OR p_owner IS NULL OR p_owner NOT IN ('ALL','MINE') OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 OR p_limit IS NULL OR p_limit<1 OR p_limit>50 OR (p_from IS NOT NULL AND p_until IS NOT NULL AND p_from>=p_until) THEN RAISE EXCEPTION 'Invalid worklist filters' USING ERRCODE='22023';END IF;
 IF p_sort IS NULL OR p_sort NOT IN ('NEWEST','OLDEST','SEVERITY') OR p_severity IS NULL OR p_severity NOT IN ('ALL','CRITICAL','HIGH','MEDIUM','LOW','UNRECORDED') OR p_min_hours IS NULL OR p_min_hours<0 OR p_min_hours>87600 OR p_waiting_only IS NULL THEN RAISE EXCEPTION 'Invalid priority filters' USING ERRCODE='22023';END IF;
 IF p_kind<>'CASES' AND staff.role<>'head_of_compliance' THEN RAISE EXCEPTION 'Head-of-compliance review access required' USING ERRCODE='42501';END IF;
 pattern:='%'||replace(replace(replace(btrim(p_search),E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_')||'%';
 WITH managed AS (
 SELECT c.*,a.customer_id,a.rule_triggered,coalesce(nullif(cu.entity_name,''),nullif(btrim(concat_ws(' ',cu.first_name,cu.last_name)),''),'Unlinked case') AS entity_name,
 left(coalesce(p.full_name,''),200) AS owner_name,g.member_count,g.status,g.consistent,g.severity_rank,g.unknown_severity_count
 FROM public.coreaml_case_claims c JOIN public.alerts a ON a.id=c.anchor_alert_id AND a.tenant_id=c.tenant_id
 LEFT JOIN public.customers cu ON cu.id=a.customer_id AND cu.tenant_id=c.tenant_id
 LEFT JOIN public.user_profiles p ON p.id=c.investigator_id AND p.tenant_id=c.tenant_id
 CROSS JOIN LATERAL (SELECT count(*)::integer AS member_count,max(CASE upper(btrim(x.severity)) WHEN 'CRITICAL' THEN 4 WHEN 'HIGH' THEN 3 WHEN 'MEDIUM' THEN 2 WHEN 'LOW' THEN 1 ELSE 0 END) AS severity_rank,count(*) FILTER(WHERE x.severity IS NULL OR upper(btrim(x.severity)) NOT IN ('CRITICAL','HIGH','MEDIUM','LOW'))::integer AS unknown_severity_count,CASE WHEN count(DISTINCT x.status)=1 THEN min(x.status) ELSE 'MIXED' END AS status,
 count(*)=cardinality(c.alert_ids) AND count(DISTINCT x.status)=1 AS consistent
 FROM public.alerts x WHERE x.id=ANY(c.alert_ids) AND x.tenant_id=c.tenant_id AND x.assigned_user_id=c.investigator_id AND x.case_reference=c.case_reference AND x.customer_id IS NOT DISTINCT FROM a.customer_id) g
 WHERE c.tenant_id=staff.tenant_id AND cardinality(c.alert_ids) BETWEEN 1 AND 2000 AND c.anchor_alert_id=ANY(c.alert_ids)
 AND (p_kind='CASES' OR c.investigator_id<>staff.id) AND (staff.role='head_of_compliance' OR c.investigator_id=staff.id) AND (p_owner='ALL' OR c.investigator_id=staff.id)
 AND g.member_count=cardinality(c.alert_ids) AND (a.customer_id IS NULL OR cu.id IS NOT NULL)
 ), candidates AS (
 SELECT c.anchor_alert_id AS id,c.anchor_alert_id AS alert_id,c.case_reference,c.customer_id,c.entity_name,c.rule_triggered,c.severity_rank,c.unknown_severity_count,
 CASE WHEN c.consistent THEN c.status ELSE 'MIXED' END AS status,c.investigator_id AS owner_id,c.owner_name,c.member_count,c.consistent,
 CASE WHEN p_kind='QA' THEN s.created_at ELSE c.claimed_at END AS occurred_at,
 CASE WHEN c.consistent AND c.status='INVESTIGATING' THEN c.claimed_at WHEN c.consistent AND c.status='PENDING_QA_REVIEW' THEN s.created_at WHEN c.consistent AND c.status='ESCALATED' AND r.status='PENDING_APPROVAL' THEN r.created_at ELSE NULL END AS waiting_since,
 CASE WHEN c.consistent AND c.status='INVESTIGATING' THEN 'CLAIM' WHEN c.consistent AND c.status='PENDING_QA_REVIEW' THEN 'QA_SUBMISSION' WHEN c.consistent AND c.status='ESCALATED' AND r.status='PENDING_APPROVAL' THEN 'EXECUTIVE_SUBMISSION' WHEN c.consistent AND c.status='ESCALATED' AND r.status='APPROVED' THEN 'INTERNAL_PREPARATION' WHEN c.consistent AND c.status='ESCALATED' THEN 'REVIEW_TIMESTAMP_MISSING' ELSE 'NOT_WAITING' END AS age_basis,
 c.consistent AND (c.status IN ('INVESTIGATING','PENDING_QA_REVIEW') OR (c.status='ESCALATED' AND coalesce(r.status,'')<>'APPROVED')) AS is_waiting
 FROM managed c LEFT JOIN LATERAL (SELECT s.created_at FROM public.coreaml_review_submissions s JOIN public.investigation_drafts d ON d.id::text=s.result->>'draft_id' AND d.case_reference=s.case_reference AND d.tenant_id=s.tenant_id AND d.investigator_id=s.actor_id AND d.alert_id=c.anchor_alert_id AND d.status='SUBMITTED' AND s.result->>'revision'=d.revision::text WHERE s.case_reference=c.case_reference AND s.tenant_id=staff.tenant_id AND s.kind='QA' ORDER BY expected_revision DESC,s.created_at DESC,s.request_id DESC LIMIT 1) s ON true
 LEFT JOIN LATERAL (SELECT r.status,r.created_at FROM public.suspicious_transaction_reports r JOIN public.investigation_drafts d ON d.id::text=r.report_data->>'draft_id' AND d.revision::text=r.report_data->>'draft_revision' AND d.case_reference=c.case_reference AND d.alert_id=c.anchor_alert_id AND d.tenant_id=staff.tenant_id AND d.investigator_id=c.investigator_id AND d.status='SUBMITTED' WHERE r.alert_id=c.anchor_alert_id AND r.tenant_id=staff.tenant_id AND r.generated_by=c.investigator_id AND r.report_data->>'case_reference'=c.case_reference AND r.report_data->'alert_ids'=to_jsonb(c.alert_ids) ORDER BY r.created_at DESC,r.id DESC LIMIT 1) r ON true
 WHERE p_kind IN ('CASES','QA') AND (p_kind='CASES' OR (c.consistent AND c.status='PENDING_QA_REVIEW'))
 UNION ALL
 SELECT r.id,c.anchor_alert_id,c.case_reference,c.customer_id,c.entity_name,c.rule_triggered,c.severity_rank,c.unknown_severity_count,'PENDING_APPROVAL',c.investigator_id,c.owner_name,c.member_count,c.consistent,r.created_at,r.created_at,'EXECUTIVE_SUBMISSION',true
 FROM public.suspicious_transaction_reports r JOIN managed c ON r.alert_id=c.anchor_alert_id AND r.tenant_id=c.tenant_id AND r.generated_by=c.investigator_id
 WHERE p_kind='EXECUTIVE' AND r.status='PENDING_APPROVAL' AND r.locked_at IS NULL AND r.report_data->'alert_ids'=to_jsonb(c.alert_ids) AND c.consistent AND c.status='ESCALATED' AND r.report_data->>'case_reference'=c.case_reference
 ), aged AS (SELECT *,CASE severity_rank WHEN 4 THEN 'CRITICAL' WHEN 3 THEN 'HIGH' WHEN 2 THEN 'MEDIUM' WHEN 1 THEN 'LOW' ELSE 'UNKNOWN' END AS severity,
 CASE WHEN NOT is_waiting THEN 'NOT_WAITING' WHEN waiting_since IS NULL THEN 'MISSING' WHEN waiting_since>as_of THEN 'FUTURE' ELSE 'RECORDED' END AS age_quality,
 CASE WHEN is_waiting AND waiting_since<=as_of THEN floor(extract(epoch FROM as_of-waiting_since))::bigint ELSE NULL END AS age_seconds FROM candidates), filtered AS (
 SELECT * FROM aged WHERE (NOT p_waiting_only OR is_waiting) AND (p_min_hours=0 OR age_seconds>=p_min_hours::bigint*3600)
 AND (p_severity='ALL' OR (p_severity='UNRECORDED' AND unknown_severity_count>0) OR severity=p_severity) AND (p_status='ALL' OR status=p_status) AND (p_from IS NULL OR occurred_at>=p_from) AND (p_until IS NULL OR occurred_at<p_until)
 AND (case_reference ILIKE pattern ESCAPE E'\\' OR entity_name ILIKE pattern ESCAPE E'\\' OR rule_triggered ILIKE pattern ESCAPE E'\\')
 ), page AS (SELECT * FROM filtered ORDER BY CASE WHEN p_sort='SEVERITY' THEN is_waiting::integer END DESC NULLS LAST,CASE WHEN p_sort='SEVERITY' THEN severity_rank END DESC NULLS LAST,CASE WHEN p_sort='SEVERITY' THEN waiting_since END ASC NULLS LAST,CASE WHEN p_sort='OLDEST' THEN occurred_at END ASC NULLS LAST,CASE WHEN p_sort='NEWEST' THEN occurred_at END DESC NULLS LAST,id DESC OFFSET p_offset LIMIT p_limit)
 SELECT jsonb_build_object('actor_id',staff.id,'tenant_id',staff.tenant_id,'kind',p_kind,'sort',p_sort,'as_of',as_of,'offset',p_offset,'limit',p_limit,'total',(SELECT count(*) FROM filtered),'rows',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY CASE WHEN p_sort='SEVERITY' THEN is_waiting::integer END DESC NULLS LAST,CASE WHEN p_sort='SEVERITY' THEN severity_rank END DESC NULLS LAST,CASE WHEN p_sort='SEVERITY' THEN waiting_since END ASC NULLS LAST,CASE WHEN p_sort='OLDEST' THEN occurred_at END ASC NULLS LAST,CASE WHEN p_sort='NEWEST' THEN occurred_at END DESC NULLS LAST,id DESC) FROM page x),'[]'::jsonb)) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.coreaml_case_worklist_priority(text,text,text,text,timestamptz,timestamptz,integer,integer,text,text,integer,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.coreaml_case_worklist_priority(text,text,text,text,timestamptz,timestamptz,integer,integer,text,text,integer,boolean) TO authenticated;
NOTIFY pgrst,'reload schema';
