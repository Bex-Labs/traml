'use strict';
// Catalog-only review of the customer-creation boundary before native fixtures.
const fs=require('node:fs'),path=require('node:path');
const {ROOT,query,assertLocal}=require('./aml-compatible-db.cjs');
function sanitize(value){return String(value).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g,'[JWT removed]').replace(/sb_secret_[\w-]+/g,'[secret removed]');}
const SQL=`BEGIN TRANSACTION READ ONLY;
SELECT jsonb_build_object(
 'customer_triggers',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',t.tgname,'enabled',t.tgenabled,'trigger_definition',pg_get_triggerdef(t.oid),'function_definition',pg_get_functiondef(t.tgfoid)) ORDER BY t.tgname),'[]'::jsonb) FROM pg_trigger t WHERE t.tgrelid='public.customers'::regclass AND NOT t.tgisinternal),
 'required_fields_and_defaults',(SELECT coalesce(jsonb_agg(jsonb_build_object('column',column_name,'type',udt_name,'nullable',is_nullable,'default',column_default) ORDER BY ordinal_position),'[]'::jsonb) FROM information_schema.columns WHERE table_schema='public' AND table_name='customers'),
 'customer_constraints',(SELECT coalesce(jsonb_agg(pg_get_constraintdef(oid)),'[]'::jsonb) FROM pg_constraint WHERE conrelid='public.customers'::regclass),
 'risk_function_definition',pg_get_functiondef('public.unified_risk_scoring()'::regprocedure)
)::text;COMMIT;`;
function main(){assertLocal();const inventory=JSON.parse(sanitize(query(SQL)));const report={generated_at:new Date().toISOString(),scope:'Read-only customer trigger and fixture schema review',inventory,limitations:['No customers, alerts, claims, requests to Auth/Edge/provider endpoints or financial records created.','Function source is inspected to determine whether a rollback-only customer fixture can cause external side effects.']};
 const output=path.join(ROOT,'.coreaml-local/customer-linked-claim-preflight.json');fs.mkdirSync(path.dirname(output),{recursive:true});if(fs.existsSync(output))fs.copyFileSync(output,output.replace(/\.json$/,'-before-'+Date.now()+'.json'));fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.log('Read-only customer preflight saved: .coreaml-local/customer-linked-claim-preflight.json');console.log('No database records changed.');}
if(require.main===module){try{main();}catch{console.error('Read-only customer preflight failed. Confirm local Supabase is running. No write operation was attempted.');process.exitCode=1;}}
module.exports={SQL,sanitize};
