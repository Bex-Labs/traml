// Pure server-side compatibility preview. No database/network/file writes.
'use strict';
const {createHash}=require('node:crypto');
const VERSION='coreaml-compatibility-preview-v1';
function canonical(x){if(x===null||typeof x!=='object')return JSON.stringify(x);if(Array.isArray(x))return '['+x.map(canonical).join(',')+']';return '{'+Object.keys(x).sort().map(k=>JSON.stringify(k)+':'+canonical(x[k])).join(',')+'}';}
const hash=x=>createHash('sha256').update(canonical(x)).digest('hex');
function cents(value){if(typeof value!=='string'&&typeof value!=='number')throw Error('Amount must be a decimal string or number');const s=String(value);if(!/^(0|[1-9]\d{0,12})(\.\d{1,2})?$/.test(s))throw Error('Invalid positive money precision/range');const [a,b='']=s.split('.');const n=BigInt(a)*100n+BigInt(b.padEnd(2,'0'));if(n<=0n)throw Error('Amount must be positive');return n;}
function time(value){if(typeof value!=='string'||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/.test(value))throw Error('Explicit ISO timestamp with timezone required');const n=Date.parse(value);if(!Number.isFinite(n))throw Error('Invalid timestamp');const day=Date.parse(value.slice(0,10)+'T00:00:00Z');if(new Date(day).toISOString().slice(0,10)!==value.slice(0,10))throw Error('Invalid calendar date');return n;}
function required(s,name){if(typeof s!=='string'||!s.trim())throw Error('Missing '+name);return s;}
function tx(x){if(!x||typeof x!=='object'||Array.isArray(x))throw Error('Transaction object required');return {id:required(x.id,'transaction ID'),account_id:required(x.account_id,'account ID'),tenant_id:required(x.tenant_id,'tenant ID'),amount:cents(x.amount),currency:/^[A-Z]{3}$/.test(x.currency)?x.currency:(()=>{throw Error('Invalid currency');})(),transaction_type:['CREDIT','DEBIT'].includes(x.transaction_type)?x.transaction_type:(()=>{throw Error('Invalid direction');})(),channel:required(x.channel,'channel'),at:time(x.transaction_timestamp),raw:structuredClone(x)};}
function evaluate(rule,current,history=[]){
 const warnings=[];
 let result={engine_version:VERSION,rule_id:rule?.id||null,rule_snapshot:structuredClone(rule),rule_snapshot_hash:hash(rule??null),transaction_id:current?.id||null,transaction_snapshot:structuredClone(current),matched:null,outcome:'INVALID_CONFIGURATION',warnings,evidence:null};
 const finish=(outcome,matched=null,evidence=null)=>({...result,outcome,matched,evidence});
 try{
  if(!rule||typeof rule!=='object'||Array.isArray(rule))throw Error('Rule object required');required(rule.id,'rule ID');required(rule.tenant_id,'rule tenant');required(rule.rule_name,'rule name');
  const currentTx=tx(current);
  if(!Array.isArray(history))throw Error('History array required');
  // Duplicate ID with changed fields is an inconsistent snapshot, never two postings.
  const rows=new Map([[currentTx.id,currentTx]]);
  for(const item of history){const row=tx(item),prior=rows.get(row.id);if(prior&&canonical(prior.raw)!==canonical(row.raw))throw Error('Conflicting transaction snapshots');rows.set(row.id,row);}
  if(rule.tenant_id!==currentTx.tenant_id&&rule.tenant_id!=='SYSTEM_GLOBAL')return finish('OUT_OF_SCOPE');
  if(!['TRANSACTION','ALL_TRANSACTIONS'].includes(rule.target_entity))throw Error('Unsupported target_entity');
  if(rule.status!=='ACTIVE')return finish('INACTIVE');
  if(!['ACTIVE','SHADOW'].includes(rule.mode))throw Error('Unsupported rule mode');
  if(rule.action_to_take!=='GENERATE_ALERT')throw Error('Unsupported action_to_take');
  const m=rule.rule_metadata??{};
  if(typeof m!=='object'||Array.isArray(m))throw Error('Metadata must be an object');
  const allowed=new Set(['transaction_type','channels','currencies','threshold_amount','time_window_hours']);for(const k of Object.keys(m))if(!allowed.has(k))throw Error('Unsupported metadata key: '+k);
  const direction=m.transaction_type??'BOTH';if(!['BOTH','CREDIT','DEBIT'].includes(direction))throw Error('Unsupported metadata direction');
  for(const field of ['channels','currencies'])if(m[field]!==undefined&&(!Array.isArray(m[field])||m[field].some(v=>typeof v!=='string'||!v.trim())))throw Error('Invalid '+field+' filter');
  if(direction!=='BOTH'&&currentTx.transaction_type!==direction)return finish('FILTERED');
  if(m.channels?.length&&!m.channels.map(v=>v.toUpperCase()).includes(currentTx.channel.toUpperCase()))return finish('FILTERED');
  if(m.currencies?.length&&!m.currencies.map(v=>v.toUpperCase()).includes(currentTx.currency))return finish('FILTERED');
  const conditions=['AMOUNT_ABOVE','VELOCITY_COUNT','STRUCTURING_PATTERN','DORMANT_ACCOUNT_ACTIVITY','STATIC_THRESHOLD'];if(!conditions.includes(rule.condition_type))throw Error('Unsupported condition_type');
  if(rule.condition_type!=='STATIC_THRESHOLD'&&(m.threshold_amount!==undefined||m.time_window_hours!==undefined))throw Error('Unexpected threshold/window metadata for condition');
  const bankAccountRows=[...rows.values()].filter(r=>r.tenant_id===currentTx.tenant_id&&r.account_id===currentTx.account_id&&r.at<=currentTx.at);
  let matched=false,evidence={transaction_amount:String(current.amount),currency:currentTx.currency,transaction_type:currentTx.transaction_type,channel:currentTx.channel,evaluated_at_transaction_time:new Date(currentTx.at).toISOString(),supporting_transactions:[]};
  if(rule.condition_type==='STATIC_THRESHOLD'){
   const threshold=cents(m.threshold_amount);if(rule.threshold_value!==null&&rule.threshold_value!==undefined&&cents(rule.threshold_value)!==threshold)throw Error('Conflicting static thresholds');
   if(m.time_window_hours!==undefined&&m.time_window_hours!==rule.time_window_hours)throw Error('Conflicting static windows');
   // Configured amount comparison is visible, but cannot become a CTR policy.
   evidence={...evidence,comparison:'GTE_AMOUNT_PREVIEW_ONLY',threshold:String(m.threshold_amount),amount_comparison_matches:currentTx.amount>=threshold,configured_time_window_hours:rule.time_window_hours,filing_status:'NOT_FILED'};
   warnings.push('CTR_POLICY_UNRESOLVED: single/aggregate basis, cash scope, currency and customer type require explicit policy.');
   return finish('POLICY_REVIEW_REQUIRED',null,evidence);
  }
  if(rule.condition_type==='AMOUNT_ABOVE'){
   const threshold=cents(rule.threshold_value);matched=currentTx.amount>threshold;evidence={...evidence,comparison:'GT',threshold:String(rule.threshold_value)};
   if(/outflow/i.test(rule.rule_name)&&direction==='BOTH')warnings.push('NAME_CONFIGURATION_MISMATCH: stored BOTH includes credits and debits.');
  }else if(rule.condition_type==='DORMANT_ACCOUNT_ACTIVITY'){
   const days=Number(rule.threshold_value);if(!Number.isSafeInteger(days)||days<=0||days>36500)throw Error('Invalid dormancy days');
   const previous=bankAccountRows.filter(r=>r.at<currentTx.at).sort((a,b)=>b.at-a.at||a.id.localeCompare(b.id))[0];
   const inactiveDays=previous?Math.floor((currentTx.at-previous.at)/86400000):null;matched=inactiveDays!==null&&inactiveDays>=days;
   evidence={...evidence,threshold_days:days,inactive_days:inactiveDays,previous_activity:previous?new Date(previous.at).toISOString():null,supporting_transactions:previous?[previous.raw]:[]};
   const label=rule.rule_name.match(/\((\d+) Days\)/i);if(label&&Number(label[1])!==days)warnings.push('NAME_CONFIGURATION_MISMATCH: stored threshold is '+days+' days; label says '+label[1]+'.');
   if([...rows.values()].some(r=>r.id!==currentTx.id&&r.account_id===currentTx.account_id&&r.tenant_id===currentTx.tenant_id&&r.at===currentTx.at))warnings.push('SIMULTANEOUS_ACTIVITY: prior activity uses strictly earlier timestamps, matching the existing helper.');
  }else{
   const hours=Number(rule.time_window_hours);if(!Number.isSafeInteger(hours)||hours<=0||hours>8760)throw Error('Invalid rolling window');
   const lower=currentTx.at-hours*3600000;
   // Preserve existing helper CREDIT behavior, but require this trigger to be a credit.
   if(currentTx.transaction_type!=='CREDIT')return finish('FILTERED',null,{...evidence,reason:'Credit-only rolling rule'});
   const included=bankAccountRows.filter(r=>r.at>=lower&&r.currency===currentTx.currency&&r.transaction_type==='CREDIT'&&(!m.channels?.length||m.channels.map(v=>v.toUpperCase()).includes(r.channel.toUpperCase()))).sort((a,b)=>a.at-b.at||a.id.localeCompare(b.id));
   const total=included.reduce((sum,r)=>sum+r.amount,0n);
   evidence={...evidence,window_start:new Date(lower).toISOString(),window_end:new Date(currentTx.at).toISOString(),window_bounds:'INCLUSIVE',transaction_count:included.length,total_minor_units:total.toString(),supporting_transactions:included.map(r=>r.raw)};
   if(rule.condition_type==='VELOCITY_COUNT'){
    const count=Number(rule.threshold_value);if(!Number.isSafeInteger(count)||count<=0)throw Error('Invalid velocity count');matched=included.length>=count;evidence={...evidence,comparison:'COUNT_GTE',threshold_count:count};
   }else{
    const threshold=cents(rule.threshold_value);matched=currentTx.amount<threshold&&total>=threshold&&included.length>=2;evidence={...evidence,comparison:'CURRENT_LT_TOTAL_GTE_COUNT_GTE_2',threshold:String(rule.threshold_value)};
    warnings.push('LEGACY_STRUCTURING_HEURISTIC: prior credits need not each be below threshold; this is not proof of structuring.');
   }
  }
  return finish(!matched?'NO_MATCH':rule.mode==='SHADOW'?'SHADOW_MATCH':'ALERT_CANDIDATE',matched,evidence);
 }catch(e){return {...finish('INVALID_CONFIGURATION'),error:e.message};}
}
module.exports={evaluate,cents,VERSION,hash};
