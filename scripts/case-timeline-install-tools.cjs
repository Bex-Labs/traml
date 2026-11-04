'use strict';
const assert=require('node:assert/strict');const q=v=>"'"+String(v).replace(/'/g,"''")+"'";
function timelineProbes(f){for(const id of Object.values(f))assert(/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id));const {bank,maker,head,peer,foreign,qa,qaMember,executive}=f;
 const role=(id,r,b=bank)=>`PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',${q(id)},'role','authenticated','app_metadata',jsonb_build_object('role',${q(r)},'tenant_id',${q(b)}))::text,true);EXECUTE 'SET LOCAL ROLE authenticated';`;
 return `DO $$ DECLARE first_page jsonb;page jsonb;whole jsonb;keys text[]:='{}';e jsonb;loops integer:=0;BEGIN
 ${role(maker,'compliance_officer')}
 whole:=public.coreaml_case_timeline(${q(qa)},50);
 IF jsonb_array_length(whole->'entries')<>6 OR whole->>'has_more'<>'false' THEN RAISE EXCEPTION 'Retained QA history does not contain its six recorded entries';END IF;
 first_page:=public.coreaml_case_timeline(${q(qaMember)},2);page:=first_page;
 IF page->>'alert_id'<>${q(qa)} OR page->>'actor_id'<>${q(maker)} OR page->>'owner_id'<>${q(maker)} OR page->>'has_more'<>'true' THEN RAISE EXCEPTION 'Canonical member scope failed';END IF;
 LOOP
  FOR e IN SELECT * FROM jsonb_array_elements(page->'entries') LOOP
   IF e->>'event_key'=ANY(keys) THEN RAISE EXCEPTION 'Repeated timeline record';END IF;keys:=array_append(keys,e->>'event_key');
  END LOOP;
  EXIT WHEN page->>'has_more'='false';loops:=loops+1;IF loops>10 THEN RAISE EXCEPTION 'Unbounded timeline pagination';END IF;
  page:=public.coreaml_case_timeline(${q(qa)},2,(page->'next_cursor'->>'at')::timestamptz,page->'next_cursor'->>'key');
 END LOOP;
 IF to_jsonb(keys) IS DISTINCT FROM (SELECT jsonb_agg(x->>'event_key' ORDER BY n) FROM jsonb_array_elements(whole->'entries') WITH ORDINALITY t(x,n)) THEN RAISE EXCEPTION 'Pagination differs from complete recorded history';END IF;
 page:=public.coreaml_case_timeline(${q(executive)},50);IF jsonb_array_length(page->'entries')<>3 OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'entries') x WHERE x->>'kind'='EXECUTIVE_APPROVED') THEN RAISE EXCEPTION 'Approved executive timeline unavailable';END IF;
 BEGIN PERFORM public.coreaml_case_timeline(${q(qa)},51);RAISE EXCEPTION 'Oversized page accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 BEGIN PERFORM public.coreaml_case_timeline(${q(qa)},2,clock_timestamp(),NULL);RAISE EXCEPTION 'Partial cursor accepted';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;
 EXECUTE 'RESET ROLE';
 ${role(head,'head_of_compliance')}
 page:=public.coreaml_case_timeline(${q(qa)},50);IF jsonb_array_length(page->'entries')<>6 OR page->>'actor_id'<>${q(head)} THEN RAISE EXCEPTION 'Head case history denied';END IF;EXECUTE 'RESET ROLE';
 ${role(peer,'compliance_officer')}
 BEGIN PERFORM public.coreaml_case_timeline(${q(qa)});RAISE EXCEPTION 'Peer officer read another case history';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(foreign,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 BEGIN PERFORM public.coreaml_case_timeline(${q(qa)});RAISE EXCEPTION 'Other bank read case history';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(maker,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 BEGIN PERFORM public.coreaml_case_timeline(${q(qa)});RAISE EXCEPTION 'Forged bank read case history';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 IF has_function_privilege('anon','public.coreaml_case_timeline(uuid,integer,timestamptz,text)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous timeline execution granted';END IF;
 END $$;`;
}
module.exports={timelineProbes};
