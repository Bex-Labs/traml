'use strict';const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),h=require('./aml-compatible-db.cjs');
const signature='public.coreaml_manager_visual_snapshot()',norm=s=>s.replace(/\r\n/g,'\n');
function plan(sql,stamp){return 'BEGIN;'+sql+`COMMENT ON FUNCTION public.coreaml_manager_visual_snapshot() IS ${h.lit(stamp)};`+probe();}
function probe(){return `DO $$ BEGIN IF has_function_privilege('anon','public.coreaml_manager_visual_snapshot()','EXECUTE') OR has_function_privilege('service_role','public.coreaml_manager_visual_snapshot()','EXECUTE') OR NOT has_function_privilege('authenticated','public.coreaml_manager_visual_snapshot()','EXECUTE') THEN RAISE EXCEPTION 'Unexpected visual projection privileges';END IF;END $$;`;}
function main(){h.assertLocal();const sql=norm(fs.readFileSync(path.join(h.ROOT,'sql/coreaml-dashboard-visuals-local.sql'),'utf8')),stamp='coreaml_visual_restore_v1:'+crypto.createHash('sha256').update(sql).digest('hex'),body=sql.match(/AS \$\$([\s\S]*?)\$\$/)[1],hash=crypto.createHash('md5').update(body).digest('hex');
 assert.equal(h.query("SELECT to_regprocedure('public.coreaml_manager_dashboard(text,integer,text)') IS NOT NULL;"),'t','The admin-manager database upgrade must already be installed.');
 const installed=h.query(`SELECT to_regprocedure(${h.lit(signature)}) IS NOT NULL;`)==='t';
 if(installed)assert.equal(h.query(`SELECT obj_description(${h.lit(signature)}::regprocedure);`),stamp,'A different visual projection exists; it will not be overwritten.');
 else{h.query(plan(sql,stamp)+'ROLLBACK;');h.query(plan(sql,stamp)+'COMMIT;');}
 assert.equal(h.query(`SELECT md5(replace(prosrc,chr(13)||chr(10),chr(10))) FROM pg_proc WHERE oid=${h.lit(signature)}::regprocedure;`),hash,'Visual projection body differs');h.query('BEGIN READ ONLY;'+probe()+'COMMIT;');console.log('PASS Read-only manager chart projection installed and verified. Existing permission functions and bank records were not changed.');console.log('Hard-refresh both dashboards. No Edge Function restart is required.');}
if(require.main===module)try{main();}catch(e){console.error('Dashboard visual installation stopped: '+e.message);process.exitCode=1;}
module.exports={plan,probe};
