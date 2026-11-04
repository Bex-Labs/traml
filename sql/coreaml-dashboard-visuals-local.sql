-- Read-only chart projection; reuse the installed role, bank and session boundary.
CREATE FUNCTION public.coreaml_manager_visual_snapshot() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE p public.user_profiles%ROWTYPE;r jsonb;industries jsonb;recorded bigint;high_count bigint;BEGIN
 p:=coreaml_private.dashboard_staff(ARRAY['bank_manager']);
 r:=public.coreaml_manager_dashboard('OVERVIEW',0,'');
 SELECT count(*) FILTER(WHERE risk_tier::text IN ('LOW','MEDIUM','HIGH','VERY_HIGH','CRITICAL')),count(*) FILTER(WHERE risk_tier::text IN ('HIGH','VERY_HIGH','CRITICAL')) INTO recorded,high_count FROM public.customers WHERE tenant_id=p.tenant_id;
 WITH grouped AS (
  SELECT coalesce(nullif(btrim(industry),''),'Not recorded') AS industry,count(*) AS customers,
  count(*) FILTER(WHERE risk_tier::text IN ('HIGH','VERY_HIGH','CRITICAL')) AS high,
  count(*) FILTER(WHERE risk_tier::text IN ('LOW','MEDIUM')) AS other,
  count(*) FILTER(WHERE risk_tier IS NULL OR risk_tier::text NOT IN ('LOW','MEDIUM','HIGH','VERY_HIGH','CRITICAL')) AS unknown
  FROM public.customers WHERE tenant_id=p.tenant_id GROUP BY coalesce(nullif(btrim(industry),''),'Not recorded')
 ),ranked AS (SELECT *,row_number() OVER(ORDER BY customers DESC,industry) AS rank FROM grouped),bounded AS (
 SELECT CASE WHEN rank<=12 THEN industry ELSE 'Other industries' END AS industry,sum(customers)::bigint AS customers,sum(high)::bigint AS high,sum(other)::bigint AS other,sum(unknown)::bigint AS unknown FROM ranked GROUP BY CASE WHEN rank<=12 THEN industry ELSE 'Other industries' END
 ) SELECT coalesce(jsonb_agg(to_jsonb(bounded) ORDER BY customers DESC,industry),'[]') INTO industries FROM bounded;
 RETURN r||jsonb_build_object('risk_recorded_count',recorded,'high_risk_count',high_count,'industry_risks',industries);
END $$;
REVOKE ALL ON FUNCTION public.coreaml_manager_visual_snapshot() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.coreaml_manager_visual_snapshot() TO authenticated;
NOTIFY pgrst,'reload schema';
