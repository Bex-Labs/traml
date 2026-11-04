'use strict';
const {query,assertLocal,lit}=require('./aml-compatible-db.cjs'),{evaluate,VERSION}=require('./aml-compatibility/evaluate.cjs');
const uuid=s=>typeof s==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
function calculate(snapshot){if(snapshot.engine_version!==VERSION)throw Error('Installed set engine version differs from worker');return snapshot.rules.map(rule=>evaluate(rule,snapshot.current,snapshot.history));}
function processSet(setId,{retryFailed=false,limit=100}={}){assertLocal();if(!uuid(setId)||!Number.isInteger(limit)||limit<1||limit>100)throw Error('Explicit valid set ID and bounded limit required');
 if(!retryFailed&&query(`SELECT EXISTS(SELECT 1 FROM public.transaction_evaluation_outbox o JOIN public.transactions t ON t.id=o.transaction_id JOIN public.coreaml_compatible_sets s ON s.account_id=t.account_id WHERE s.id=${lit(setId)}::uuid AND o.status='FAILED');`)==='t')throw Error('Earlier failed receipt requires --retry-failed before pending work');
 const rows=JSON.parse(query(`SELECT coalesce(json_agg(x),'[]') FROM(SELECT o.transaction_id,o.status FROM public.transaction_evaluation_outbox o JOIN public.transactions t ON t.id=o.transaction_id JOIN public.coreaml_compatible_sets s ON s.account_id=t.account_id AND s.tenant_id=o.tenant_id WHERE s.id=${lit(setId)}::uuid AND (o.status='PENDING' OR (${retryFailed} AND o.status='FAILED' AND o.attempts<3)) ORDER BY t.transaction_timestamp,t.id LIMIT ${limit})x;`));
 const report={processed:0,replayed:0,policy_blocked:0,failed:0,items:[]};
 for(const row of rows){const snap=JSON.parse(query(`SELECT coreaml_private.compatible_snapshot(${lit(setId)}::uuid,${lit(row.transaction_id)}::uuid);`));const outcomes=calculate(snap);
  const r=JSON.parse(query(`SELECT coreaml_private.compatible_commit(${lit(setId)}::uuid,${lit(row.transaction_id)}::uuid,${lit(JSON.stringify(snap))}::jsonb,${lit(JSON.stringify(outcomes))}::jsonb,${retryFailed});`));
  report.items.push({transaction_id:row.transaction_id,...r});if(r.status==='PROCESSED')report.processed++;else if(r.status==='REPLAY')report.replayed++;else report.failed++;if(r.state==='POLICY_BLOCKED')report.policy_blocked++;
  // Do not evaluate later transactions after an earlier failure; preserve causal ordering.
  if(r.status==='FAILED')break;
 }return report;
}
module.exports={calculate,processSet,uuid};
if(require.main===module){try{const args=process.argv.slice(2),pos=args.indexOf('--set-id');if(pos<0||args.some((v,i)=>v!=='--set-id'&&i!==pos+1&&v!=='--retry-failed'))throw Error('Usage: node scripts/process-aml-compatible-local.cjs --set-id UUID [--retry-failed]');const r=processSet(args[pos+1],{retryFailed:args.includes('--retry-failed')});console.log(JSON.stringify(r,null,2));console.log('POLICY_BLOCKED is unresolved CTR policy; no filing performed.');if(r.failed)process.exitCode=1;}catch(e){console.error(e.message);process.exitCode=1;}}
