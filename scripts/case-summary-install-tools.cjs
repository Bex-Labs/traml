'use strict';const assert=require('node:assert/strict');const q=v=>"'"+String(v).replace(/'/g,"''")+"'";
function summaryProbes(f){for(const k of ['bank','maker','head','peer','foreign','qa','qaMember','executive'])assert(/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(f[k]));const role=(id,r,b=f.bank)=>`PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',${q(id)},'role','authenticated','app_metadata',jsonb_build_object('role',${q(r)},'tenant_id',${q(b)}))::text,true);EXECUTE 'SET LOCAL ROLE authenticated';`;
return `DO $$ DECLARE a jsonb;b jsonb;expected text;BEGIN SELECT draft_narrative INTO expected FROM public.investigation_drafts WHERE alert_id=${q(f.qa)};
 ${role(f.maker,'compliance_officer')}
 a:=public.coreaml_case_summary(${q(f.qaMember)});IF a->>'alert_id'<>${q(f.qa)} OR a->>'actor_id'<>${q(f.maker)} OR a->>'owner_id'<>${q(f.maker)} OR a->>'regulatory_submission'<>'false' OR a->>'document_type'<>'INTERNAL_INVESTIGATION_SUMMARY' OR a->>'history_complete'<>'true' THEN RAISE EXCEPTION 'Summary canonical scope failed';END IF;
 IF jsonb_array_length(a->'alerts')<>2 OR jsonb_array_length(a->'history')<>6 OR a->'draft'->>'status'<>'CLOSED' OR a->'draft'->>'revision'<>'6' OR jsonb_array_length(a->'report_packages')<>0 THEN RAISE EXCEPTION 'QA summary is incomplete';END IF;
 IF a->'draft'->>'narrative' IS DISTINCT FROM expected THEN RAISE EXCEPTION 'Saved findings differ';END IF;
 b:=public.coreaml_case_summary(${q(f.executive)});IF jsonb_array_length(b->'history')<>3 OR jsonb_array_length(b->'report_packages')<>1 OR b->'report_packages'->0->>'status'<>'APPROVED' OR b->'draft'->>'status'<>'SUBMITTED' THEN RAISE EXCEPTION 'Executive summary falsely implied filing or lost package state';END IF;EXECUTE 'RESET ROLE';
 ${role(f.head,'head_of_compliance')}
 a:=public.coreaml_case_summary(${q(f.qa)});IF a->>'actor_id'<>${q(f.head)} OR jsonb_array_length(a->'alerts')<>2 THEN RAISE EXCEPTION 'Head summary scope failed';END IF;EXECUTE 'RESET ROLE';
 ${role(f.peer,'compliance_officer')}
 BEGIN PERFORM public.coreaml_case_summary(${q(f.qa)});RAISE EXCEPTION 'Peer exported another case';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(f.foreign,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 BEGIN PERFORM public.coreaml_case_summary(${q(f.qa)});RAISE EXCEPTION 'Other bank exported case';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 ${role(f.maker,'compliance_officer','a1000000-0000-4000-8000-000000000002')}
 BEGIN PERFORM public.coreaml_case_summary(${q(f.qa)});RAISE EXCEPTION 'Forged bank exported case';EXCEPTION WHEN insufficient_privilege THEN NULL;END;EXECUTE 'RESET ROLE';
 IF has_function_privilege('anon','public.coreaml_case_summary(uuid)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous summary access granted';END IF;
 END $$;`;
}
module.exports={summaryProbes};
