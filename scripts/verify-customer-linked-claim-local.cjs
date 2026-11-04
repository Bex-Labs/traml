'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{randomUUID}=require('node:crypto'),{spawn}=require('node:child_process');
const {ROOT,DB,BANK,query,assertLocal,lit}=require('./aml-compatible-db.cjs');
const tools=require('./customer-linked-native-tools.cjs');
const read=sql=>query('BEGIN TRANSACTION READ ONLY;'+sql+'COMMIT;');
const readJSON=sql=>JSON.parse(read(sql));
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const clean=text=>String(text).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g,'[JWT removed]').replace(/sb_secret_[\w-]+/g,'[secret removed]').slice(0,1600);
function session(sql){return new Promise(resolve=>{const start=Date.now(),child=spawn('docker',['exec','-i',DB,'psql','-X','-q','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres','-At'],{stdio:['pipe','pipe','pipe']});let out='',error='',done=false;const finish=result=>{if(done)return;done=true;clearTimeout(timer);resolve({...result,elapsed_ms:Date.now()-start});};const timer=setTimeout(()=>{child.kill();finish({code:124,out,error:'Native race timed out'});},25000);child.stdout.on('data',data=>{out+=data;});child.stderr.on('data',data=>{error+=data;});child.on('error',e=>finish({code:1,out,error:clean(e.message)}));child.on('close',code=>finish({code,out,error}));child.stdin.on('error',()=>{});child.stdin.end(sql);});}
async function main(){
 assertLocal();
 const runId=randomUUID(),f={customer_id:randomUUID(),alert_ids:[randomUUID(),randomUUID()],marker:'GroupClaimTest-'+runId};tools.validateFixture(f);
 const folder=path.join(ROOT,'.coreaml-local/customer-linked-claim',runId);fs.mkdirSync(folder,{recursive:true});
 const report={generated_at:new Date().toISOString(),run_id:runId,scope:'Local customer-linked group claim, risk preservation, rollback and database concurrency',fixture:f,checks:[],states:{},limitations:[
  'Retains one new synthetic PENDING customer, two synthetic alerts, their setup risk history and one successful claim/audit record if setup and race pass.',
  'Refuses before fixture creation if the reviewed identity-screening webhook is configured. It neither disables triggers nor changes Vault settings.',
  'Uses actual authenticated database-role sessions, not signed-in browser group claiming. No cash, accounts, evaluations, drafts or filings are created.',
  'A second-member fault is injected only inside a rolled-back savepoint; no fault trigger or function is committed.'
 ]};
 let before,created=false;const pendingSessions=[];
 async function check(name,fn){try{await fn();report.checks.push({check:name,result:'PASS'});return true;}catch(error){report.checks.push({check:name,result:'FAIL',detail:clean(error.message)});return false;}}
 try{
  let actors;
  const ready=await check('Reviewed customer/risk triggers and two active local officers match',async()=>{
   const expected=JSON.parse(fs.readFileSync(path.join(ROOT,'scripts/fixtures/customer-linked-trigger-contract.json'),'utf8'));
   tools.validateContract(readJSON(tools.contractSQL()),expected);
   actors=readJSON(`SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]'::jsonb) FROM (SELECT p.id,u.email='compliance_officer@coreaml-local.test' AS primary_actor FROM public.user_profiles p JOIN auth.users u ON u.id=p.id WHERE p.tenant_id=${lit(BANK)} AND p.role='compliance_officer' AND p.is_active IS TRUE AND u.email LIKE '%@coreaml-local.test' ORDER BY (u.email='compliance_officer@coreaml-local.test') DESC,p.id LIMIT 2) p;`);
   assert(actors.length===2&&actors[0].primary_actor&&actors.every(a=>/^[0-9a-f-]{36}$/i.test(a.id)),'Two active same-bank synthetic officers required');
  });
  if(!ready)return;
  before=readJSON(tools.snapshotSQL(f));report.states.before=before;
  const prepared=await check('Guarded setup and rollback probes pass; one isolated linked fixture retained',async()=>{
   const state='('+tools.snapshotSQL(f).replace(/;\s*$/,'')+')::jsonb';
   const preserve=`DO $preserve$ BEGIN IF ${state} IS DISTINCT FROM ${lit(JSON.stringify(before))}::jsonb THEN RAISE EXCEPTION 'Setup/probes changed pre-existing state; rolling back';END IF;END $preserve$;`;
   query(tools.setupSQL(f)+tools.probeSQL(f,actors.map(a=>a.id))+preserve+'COMMIT;');created=true;
   const after=readJSON(tools.snapshotSQL(f));report.states.after_setup=after;tools.assertSnapshot(before,after);
  });
  if(!prepared)return;
  let fixtureBefore;
  const baseline=await check('Linked fixture starts at 40/MEDIUM with two unassigned alerts and two risk entries',async()=>{
   fixtureBefore=readJSON(tools.fixtureStateSQL(f));
   assert.equal(Number(fixtureBefore.customer.risk_score),40);assert.equal(fixtureBefore.customer.risk_tier,'MEDIUM');
   assert.equal(fixtureBefore.customer.kyc_status,'PENDING');assert.equal(fixtureBefore.history.length,2);assert.equal(fixtureBefore.alerts.length,2);
   assert(fixtureBefore.alerts.every(a=>a.customer_id===f.customer_id&&a.tenant_id===BANK&&a.status==='UNASSIGNED'&&a.assigned_user_id===null&&a.case_reference===null));
   assert.equal(fixtureBefore.claims.length,0);assert.equal(fixtureBefore.events.length,0);
   report.fixture_risk={score:40,tier:'MEDIUM',history_count:2};
  });
  if(!baseline)return;
  const raced=await check('Different group anchors contend on one customer lock with one winning officer',async()=>{
   const names=[f.marker+'-primary',f.marker+'-peer'];
   const raceSQL=(actor,id,name)=>`BEGIN ISOLATION LEVEL READ COMMITTED;SET LOCAL statement_timeout='15s';SET LOCAL lock_timeout='8s';SET LOCAL application_name=${lit(name)};${tools.claimsSQL(actor)}SELECT public.coreaml_claim_case(${lit(id)}::uuid);SELECT pg_sleep(4);COMMIT;`;
   const first=session(raceSQL(actors[0].id,f.alert_ids[0],names[0]));pendingSessions.push(first);let ownsLock=false;
   for(let attempt=0;attempt<15&&!ownsLock;attempt++){ownsLock=read(`SELECT EXISTS(SELECT 1 FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE l.locktype='advisory' AND l.granted AND a.application_name=${lit(names[0])});`)==='t';if(!ownsLock)await pause(100);}
   if(!ownsLock){const result=await first;report.race=[{actor_id:actors[0].id,code:result.code,error:clean(result.error)}];throw Error('Primary claim lock not observed; peer was not started');}
   const second=session(raceSQL(actors[1].id,f.alert_ids[1],names[1]));pendingSessions.push(second);let waited=false;
   for(let attempt=0;attempt<15&&!waited;attempt++){waited=read(`SELECT EXISTS(SELECT 1 FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE l.locktype='advisory' AND NOT l.granted AND a.application_name=${lit(names[1])});`)==='t';if(!waited)await pause(100);}
   const results=await Promise.all([first,second]);report.race=results.map((r,i)=>({actor_id:actors[i].id,exit_code:r.code,elapsed_ms:r.elapsed_ms,error:r.code?clean(r.error):null}));
   assert(waited,'Peer did not exhibit actual lock contention');assert.equal(results[0].code,0,'Primary claim failed');assert.notEqual(results[1].code,0,'Peer also claimed the group');assert.match(results[1].error,/already claimed|active investigation/i);
   const after=readJSON(tools.fixtureStateSQL(f));tools.assertClaim(after,f,actors[0].id,fixtureBefore);
   report.fixture.owner_id=actors[0].id;report.fixture.case_reference=after.claims[0].case_reference;
  });
  if(!raced)return;
  await check('Group-member retry preserves the same receipt, audit and risk state',async()=>{
   const result=query(`BEGIN;${tools.claimsSQL(actors[0].id)}SELECT public.coreaml_claim_case(${lit(f.alert_ids[1])}::uuid);COMMIT;`);
   const receipt=JSON.parse(result);assert.equal(receipt.replayed,true);assert.equal(receipt.case_reference,report.fixture.case_reference);
   tools.assertClaim(readJSON(tools.fixtureStateSQL(f)),f,actors[0].id,fixtureBefore);
  });
 }catch(error){report.checks.push({check:'Native linked-claim prerequisites/execution',result:'FAIL',detail:clean(error.message)});}
 finally{
  await Promise.all(pendingSessions);
  if(before)await check('Original fixtures, profiles, ledger, risk, evaluations, drafts and archives unchanged',async()=>{const after=readJSON(tools.snapshotSQL(f));report.states.after=after;tools.assertSnapshot(before,after);});
  report.fixture.created=created;report.summary={pass:report.checks.filter(c=>c.result==='PASS').length,fail:report.checks.filter(c=>c.result==='FAIL').length};
  const output=path.join(folder,'results.json');fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');console.table(report.checks);console.log('Summary:',report.summary);console.log('Report:',path.relative(ROOT,output));console.log(created?'One new synthetic customer and two alerts retained. Existing fixtures were not claimed.':'No linked fixture committed.');if(report.summary.fail)process.exitCode=1;
 }
}
if(require.main===module)main().catch(error=>{console.error(clean(error.message));process.exitCode=1;});
module.exports={session};
