// Diagnostic classification regressions; no database or network operations.
'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {SQL,sourceInventory,assess}=require('./diagnose-coreaml-aml-local.cjs');
const current=sourceInventory(fs.readFileSync(path.join(__dirname,'../dashboard.html'),'utf8'));assert.equal(current.browser_ctr_archive_insert,false);assert.equal(current.browser_ctr_filed_event,false);
const source=sourceInventory("function initializeRealtimePulse(){.on('postgres_changes');if(amount >= 5000000){supabase.from('report_archives').insert([]);log('CTR_AUTO_FILED');}} // 2. DYNAMIC AML RULE EVALUATOR");
assert(source.realtime_callback_present);assert(source.browser_ctr_archive_insert);assert(source.browser_ctr_filed_event);assert.equal(source.observed_code_amount_boundary,'5000000');
const data={triggers:[{name:'enqueue_transaction_evaluation',enabled:'O'},{name:'trigger_aml_engine',enabled:'D'}],rules:[],outbox:[{status:'PENDING',count:2}]};
let checks=assess(data,source);assert.equal(checks.find(c=>c.check.startsWith('Active transaction')).result,'BLOCKED');assert.equal(checks.find(c=>c.check.startsWith('Browser does not')).result,'FAIL');assert.equal(checks.find(c=>c.check.startsWith('Regulatory')).result,'BLOCKED');
assert.equal(checks.find(c=>c.check.startsWith('Cash transaction')).result,'PASS');
for(const enabled of ['D','R']){checks=assess({...data,triggers:[{name:'enqueue_transaction_evaluation',enabled}]},source);assert.equal(checks.find(c=>c.check.startsWith('Cash transaction')).result,'FAIL');}
checks=assess({...data,triggers:[],rules:[{status:'DRAFT',target_entity:'TRANSACTION'},{status:'ACTIVE',target_entity:'CUSTOMER'}]},source);assert.equal(checks.find(c=>c.check.startsWith('Active transaction')).result,'BLOCKED');
checks=assess({...data,rules:[{status:'ACTIVE',target_entity:'TRANSACTION'}]},source);assert.equal(checks.find(c=>c.check.startsWith('Active transaction')).result,'PASS');assert.equal(checks.find(c=>c.check.startsWith('Regulatory')).result,'BLOCKED');
const compatibleChecks=assess({...data,compatible_inventory:{sets:[{mapped_rule_count:5}],run_states:[{state:'POLICY_BLOCKED',count:8}]}},source);assert.equal(compatibleChecks.find(c=>c.check.startsWith('Sealed local')).detail.mapped_rules,5);assert.equal(compatibleChecks.find(c=>c.check.startsWith('Regulatory')).result,'BLOCKED');
const empty=sourceInventory('<html></html>');assert.equal(empty.browser_ctr_archive_insert,false);assert.equal(empty.observed_code_amount_boundary,null);
for(const statement of Object.values(SQL)){assert(/^SELECT\b/i.test(statement));assert(!/\b(INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE|CALL)\b/i.test(statement));}
assert(!SQL.cron_jobs.includes('command'));assert(!SQL.functions.includes('AS definition,'));assert(!SQL.rules.includes("j->'description'"));
console.log('PASS: empty rules and unverified filing remain blocked; browser archive/event writes remain findings; disabled triggers fail; inventory statements are SELECT-only and omit function bodies/cron commands.');
