'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'setup-case-claim-peer-local.cjs'),'utf8');
const BANK='a1000000-0000-4000-8000-000000000001',API='http://127.0.0.1:55321';
const id='00000000-0000-4000-8000-000000000002',primary='00000000-0000-4000-8000-000000000001',key='sb_secret_TEST_ADMIN_KEY';
function harness(collision=false,fallback=false,jsLauncher=false){
 let account=collision?{id,email:'case_claim_peer@coreaml-local.test',metadata:{fixture:'unrecognized'}}:null,profile=false,posts=0,inspections=0,writes=[];
 const logs=[],files=[],moduleObject={exports:{}};
 const helper={ROOT:'/local/coreaml',DB:'supabase_db_sentinel-aml',API,BANK,assertLocal(){},lit:x=>"'"+String(x).replace(/'/g,"''")+"'",run(command,args){assert.equal(command,'docker');if(args[0]==='exec'){assert(fallback);assert.deepEqual(Array.from(args),['exec','supabase_kong_sentinel-aml','cat','/home/kong/kong.yml']);return 'consumers: []';}assert.deepEqual(Array.from(args),['inspect','supabase_kong_sentinel-aml']);inspections++;return JSON.stringify([{Config:{Env:fallback?[]:['SUPABASE_SERVICE_KEY='+key]}}]);},query(sql){
  if(sql.includes('SELECT coalesce(jsonb_agg(to_jsonb(p))'))return JSON.stringify(profile?[{id:primary,email:'compliance_officer@coreaml-local.test'},{id,email:'case_claim_peer@coreaml-local.test'}]:[{id:primary,email:'compliance_officer@coreaml-local.test'}]);
  if(sql.includes("'metadata',raw_app_meta_data"))return JSON.stringify(account);
  if(sql.includes('SELECT md5'))return 'unchanged';
  assert(sql.includes('INSERT INTO public.user_profiles'));assert(sql.includes(id));assert(sql.includes('raw_app_meta_data'));profile=true;writes.push(sql);return '';
 }};
 const fakeProcess={execPath:'/node/bin/node',env:{APPDATA:'/user/appdata'}};
 const globalJS=path.join(fakeProcess.env.APPDATA,'npm/node_modules/supabase/dist/supabase.js');
 const fakeFs={mkdirSync(){},existsSync(file){return jsLauncher&&file===globalJS;},writeFileSync(file,data){files.push(JSON.parse(data));}};
 const fakeChildProcess={spawnSync(command,args){
  if(jsLauncher){if(command!==fakeProcess.execPath||args[0]!==globalJS)return {error:Error('Unavailable')};args=args.slice(1);}
  else if(command!=='supabase')return {error:Error('Unavailable')};
  return {status:0,stdout:args.length===1?'Supabase: status':args.includes('--help')?'--output [ json | env ]':JSON.stringify({API_URL:API,SECRET_KEY:key})};
 }};
 const req=name=>name==='./aml-compatible-db.cjs'?helper:name==='node:fs'?fakeFs:name==='node:child_process'&&fallback?fakeChildProcess:require(name);
 const fakeFetch=async(url,options)=>{assert.equal(options.redirect,'error');assert(url.startsWith(API+'/auth/v1/'));if(url.endsWith('/health'))return {status:200,body:{async cancel(){}}};
  assert.equal(url,API+'/auth/v1/admin/users');assert.equal(options.method,'POST');assert.equal(options.headers.apikey,key);assert.equal(options.headers.Authorization,'Bearer '+key);
  const body=JSON.parse(options.body);assert.equal(body.email,'case_claim_peer@coreaml-local.test');assert.equal(body.email_confirm,true);assert(body.password.length>30);assert.equal(body.app_metadata.role,'compliance_officer');assert.equal(body.app_metadata.tenant_id,BANK);posts++;account={id,email:body.email,metadata:body.app_metadata};return {ok:true,body:{async cancel(){}}};};
 vm.runInNewContext(source,{require:req,module:moduleObject,Buffer,AbortSignal,fetch:fakeFetch,process:fakeProcess,console:{log:value=>logs.push(value),error:value=>logs.push(value)}});
 return {api:moduleObject.exports,stats:()=>({posts,inspections,writes,logs,files})};
}
(async()=>{
 const h=harness();await h.api.main();let s=h.stats();assert.equal(s.posts,1);assert.equal(s.writes.length,1);assert.equal(s.files[0].ready,true);assert(!JSON.stringify(s.logs).includes(key));assert(!JSON.stringify(s.files).includes(key));console.log('PASS Setup uses only local Auth Admin and exports no credential or password');
 await h.api.main();s=h.stats();assert.equal(s.posts,1);assert.equal(s.writes.length,1);console.log('PASS Repeat setup reuses readiness without another account or profile write');
 const conflict=harness(true);await assert.rejects(()=>conflict.api.main(),/unrecognized/);assert.equal(conflict.stats().posts,0);assert.equal(conflict.stats().inspections,0);console.log('PASS Unrecognized fixture-email collision cannot reassign an existing user');
 const serviceToken='eyJhbGciOiJIUzI1NiJ9.'+Buffer.from(JSON.stringify({role:'service_role'})).toString('base64url')+'.signature';
 const yaml='consumers:\n  - username: anon\n    keyauth_credentials:\n      - key: sb_publishable_PUBLIC\n  - username: service_role\n    keyauth_credentials:\n      - key: '+serviceToken+'\n';
 assert.equal(h.api.extractAdminKey([],yaml),serviceToken);assert.throws(()=>h.api.extractAdminKey(['SUPABASE_SERVICE_KEY=sb_publishable_PUBLIC'],''));console.log('PASS Credential selection rejects public keys and reads only the service-role consumer');
 assert.throws(()=>h.api.profileSQL('invalid-id'));assert(!h.api.accountMatches({id,email:h.api.EMAIL,metadata:{fixture:h.api.MARKER,role:'it_admin',tenant_id:BANK}}));console.log('PASS Profile changes require an exact marked test identity and valid UUID');
 const calls=[];const invoke=args=>{calls.push(Array.from(args));return args.length===1?'Supabase CLI: status':args.includes('--help')?'--output [ json | env ]':JSON.stringify({API_URL:API,SERVICE_ROLE_KEY:serviceToken});};
 assert.equal(h.api.statusAdminKey(invoke),serviceToken);assert.deepEqual(calls,[['--help'],['status','--help'],['status','--output','json']]);console.log('PASS CLI help is checked before reading local status credentials');
 const wrong=args=>args.includes('--help')?invoke(args):JSON.stringify({API_URL:'http://127.0.0.1:54321',SERVICE_ROLE_KEY:serviceToken});assert.throws(()=>h.api.statusAdminKey(wrong),/refusing/);console.log('PASS Credentials reported for the other local stack are rejected');
 assert.throws(()=>h.api.statusAdminKey(args=>args.includes('--help')?invoke(args):JSON.stringify({API_URL:API,ANON_KEY:'sb_publishable_PUBLIC'})),/Admin credential/);console.log('PASS CLI status cannot substitute a public key for an Admin credential');
 const fallback=harness(false,true);await fallback.api.main();assert.equal(fallback.stats().posts,1);assert(!JSON.stringify(fallback.stats().files).includes(key));assert(!JSON.stringify(fallback.stats().logs).includes(key));console.log('PASS Full CLI fallback provisions only the marked peer without exporting credentials');
 const js=harness(false,true,true);await js.api.main();assert.equal(js.stats().posts,1);assert(!JSON.stringify(js.stats().files).includes(key));console.log('PASS Observed Windows npm JS launcher works when no native CLI executable exists');
 console.log('10 peer-setup safety checks passed; live local Auth provisioning still requires execution.');
})().catch(error=>{console.error(error);process.exitCode=1;});
