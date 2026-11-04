'use strict';const assert=require('node:assert/strict');const q=v=>"'"+String(v).replace(/'/g,"''")+"'";
function ageingProbes(f){for(const k of ['bank','maker','head','peer','foreign','qa','executive','run_id'])assert(/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(f[k]));const prefix='CASE-ReviewAcceptance-'+f.run_id;const role=(id,r,b=f.bank)=>`PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',${q(id)},'role','authenticated','app_metadata',jsonb_build_object('role',${q(r)},'tenant_id',${q(b)}))::text,true);EXECUTE 'SET LOCAL ROLE authenticated';`;
 return `DO $$ DECLARE a jsonb;b jsonb;r jsonb;BEGIN
 ${role(f.maker,'compliance_officer')}
 a:=public.coreaml_case_worklist_priority(p_search=>${q(prefix)});IF a->>'total'<>'2' OR a->>'as_of' IS NULL THEN RAISE EXCEPTION 'Retained group scope or server snapshot is missing';END IF;
 FOR r IN SELECT * FROM jsonb_array_elements(a->'rows') LOOP IF r->>'age_quality'<>'NOT_WAITING' OR r->>'is_waiting'<>'false' OR r->'age_seconds'<>'null'::jsonb OR r->>'severity'<>'MEDIUM' THEN RAISE EXCEPTION 'Completed fixture received active age or invented severity';END IF;END LOOP;
 a:=public.coreaml_case_worklist_priority(p_search=>${q(prefix)},p_waiting_only=>true);b:=public.coreaml_case_worklist_priority(p_search=>${q(prefix)},p_min_hours=>24);IF a->>'total'<>'0' OR b->>'total'<>'0' THEN RAISE EXCEPTION 'Terminal work remained in active age filters';END IF;
 a:=public.coreaml_case_worklist_priority(p_search=>${q(prefix)},p_sort=>'OLDEST',p_limit=>1);b:=public.coreaml_case_worklist_priority(p_search=>${q(prefix)},p_sort=>'OLDEST',p_offset=>1,p_limit=>1);IF a->>'total'<>'2' OR a->'rows'->0->>'id'=b->'rows'->0->>'id' THEN RAISE EXCEPTION 'Priority paging duplicated a group';END IF;
 a:=public.coreaml_case_worklist_priority(p_search=>${q(prefix)},p_sort=>'SEVERITY',p_severity=>'UNRECORDED');IF a->>'total'<>'0' THEN RAISE EXCEPTION 'Recorded severities were marked missing';END IF;
 BEGIN PERFORM public.coreaml_case_worklist_priority(p_sort=>'AUTO_RISK');RAISE EXCEPTION 'Unreviewed priority accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 BEGIN PERFORM public.coreaml_case_worklist_priority(p_min_hours=>-1);RAISE EXCEPTION 'Negative wait filter accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 BEGIN PERFORM public.coreaml_case_worklist_priority(p_kind=>'QA');RAISE EXCEPTION 'Officer read head queue';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(f.head,'head_of_compliance')}
 a:=public.coreaml_case_worklist_priority(p_search=>${q(prefix)},p_sort=>'SEVERITY');IF a->>'total'<>'2' THEN RAISE EXCEPTION 'Head group read denied';END IF;EXECUTE 'RESET ROLE';
 ${role(f.peer,'compliance_officer')}
 a:=public.coreaml_case_worklist_priority(p_search=>${q(prefix)});IF a->>'total'<>'0' THEN RAISE EXCEPTION 'Peer read another case';END IF;EXECUTE 'RESET ROLE';
 ${role(f.foreign,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 a:=public.coreaml_case_worklist_priority(p_search=>${q(prefix)});IF a->>'total'<>'0' THEN RAISE EXCEPTION 'Other bank read case';END IF;EXECUTE 'RESET ROLE';
 ${role(f.maker,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 BEGIN PERFORM public.coreaml_case_worklist_priority();RAISE EXCEPTION 'Forged bank accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 IF has_function_privilege('anon','public.coreaml_case_worklist_priority(text,text,text,text,timestamptz,timestamptz,integer,integer,text,text,integer,boolean)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous priority access granted';END IF;
 END $$;`;
}
module.exports={ageingProbes};
