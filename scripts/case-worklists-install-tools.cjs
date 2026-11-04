'use strict';const assert=require('node:assert/strict');const q=v=>"'"+String(v).replace(/'/g,"''")+"'";
function worklistProbes(f){for(const k of ['bank','maker','head','peer','foreign','qa','executive','run_id'])assert(/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(f[k]));assert.equal(f.qaRef,'CASE-ReviewAcceptance-'+f.run_id+'-QA');const role=(id,r,b=f.bank)=>`PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',${q(id)},'role','authenticated','app_metadata',jsonb_build_object('role',${q(r)},'tenant_id',${q(b)}))::text,true);EXECUTE 'SET LOCAL ROLE authenticated';`;
return `DO $$ DECLARE a jsonb;b jsonb;BEGIN
 ${role(f.maker,'compliance_officer')}
 a:=public.coreaml_case_worklist('CASES',${q(f.qaRef)});IF a->>'total'<>'1' OR a->'rows'->0->>'alert_id'<>${q(f.qa)} OR a->'rows'->0->>'member_count'<>'2' THEN RAISE EXCEPTION 'Case members were not grouped globally';END IF;
 b:=public.coreaml_case_worklist('CASES',${q(f.qaRef+'%')});IF b->>'total'<>'0' THEN RAISE EXCEPTION 'Search wildcard was not literal';END IF;
 a:=public.coreaml_case_worklist('CASES',${q('CASE-ReviewAcceptance-'+f.run_id)},'ALL','ALL',NULL,NULL,0,1);b:=public.coreaml_case_worklist('CASES',${q('CASE-ReviewAcceptance-'+f.run_id)},'ALL','ALL',NULL,NULL,1,1);IF a->>'total'<>'2' OR b->>'total'<>'2' OR a->'rows'->0->>'id'=b->'rows'->0->>'id' THEN RAISE EXCEPTION 'Stable group pagination failed';END IF;
 a:=public.coreaml_case_worklist('CASES',${q(f.qaRef)},'CLOSED');b:=public.coreaml_case_worklist('CASES',${q(f.qaRef)},'INVESTIGATING');IF a->>'total'<>'1' OR b->>'total'<>'0' THEN RAISE EXCEPTION 'Status filter failed';END IF;
 BEGIN PERFORM public.coreaml_case_worklist('QA');RAISE EXCEPTION 'Officer read review worklist';EXCEPTION WHEN insufficient_privilege THEN NULL;END;
 BEGIN PERFORM public.coreaml_case_worklist('CASES','','ALL','ALL',NULL,NULL,0,51);RAISE EXCEPTION 'Unbounded page allowed';EXCEPTION WHEN invalid_parameter_value THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(f.head,'head_of_compliance')}
 a:=public.coreaml_case_worklist('CASES',${q(f.qaRef)});IF a->>'total'<>'1' THEN RAISE EXCEPTION 'Head case read denied';END IF;
 a:=public.coreaml_case_worklist('QA',${q(f.qaRef)});b:=public.coreaml_case_worklist('EXECUTIVE',${q(f.qaRef.replace(/-QA$/,'-EXEC'))});IF a->>'total'<>'0' OR b->>'total'<>'0' THEN RAISE EXCEPTION 'Completed cases remained in pending queues';END IF;EXECUTE 'RESET ROLE';
 ${role(f.peer,'compliance_officer')}
 a:=public.coreaml_case_worklist('CASES',${q(f.qaRef)});IF a->>'total'<>'0' THEN RAISE EXCEPTION 'Peer read another owned case';END IF;EXECUTE 'RESET ROLE';
 ${role(f.foreign,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 a:=public.coreaml_case_worklist('CASES',${q(f.qaRef)});IF a->>'total'<>'0' THEN RAISE EXCEPTION 'Other bank read case worklist';END IF;EXECUTE 'RESET ROLE';
 ${role(f.maker,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 BEGIN PERFORM public.coreaml_case_worklist('CASES');RAISE EXCEPTION 'Forged bank accepted';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 IF has_function_privilege('anon','public.coreaml_case_worklist(text,text,text,text,timestamptz,timestamptz,integer,integer)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous worklist access granted';END IF;
 END $$;`;}
module.exports={worklistProbes};
