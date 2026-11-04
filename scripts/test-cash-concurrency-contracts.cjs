// Evidence-check regressions only; actual parallel DB sessions run separately.
'use strict';
const assert=require('node:assert/strict'),{assertState,outcomes}=require('./verify-coreaml-cash-concurrency-local.cjs');
const f={initial:100,tillId:'till'};const good={balance:20,till:20,transactions:[{id:'tx',transaction_reference:'ref',amount:80,transaction_type:'DEBIT',channel:'BRANCH_CASH',till_id:'till'}],receipts:[{transaction_id:'tx',status:'PENDING',attempts:0,tenant_id:'a1000000-0000-4000-8000-000000000001'}]};assertState(f,good,20,1);
for(const mutate of [s=>s.balance=100,s=>s.till=100,s=>s.transactions[0].amount=79,s=>s.transactions.push({...s.transactions[0]}),s=>s.transactions[0].till_id='other',s=>s.receipts[0].transaction_id='other',s=>s.receipts=[],s=>s.receipts[0].status='DONE',s=>s.receipts[0].tenant_id='other']){const s=structuredClone(good);mutate(s);assert.throws(()=>assertState(f,s,20,1));}
outcomes([{code:0},{code:1,stderr:'duplicate key'}],/duplicate key/);for(const r of [[{code:0},{code:0}],[{code:1,stderr:'duplicate key'},{code:1,stderr:'duplicate key'}],[{code:0},{code:1,stderr:'unrelated error'}]])assert.throws(()=>outcomes(r,/duplicate key/));
console.log('PASS: concurrency evidence rejects balance, transaction and receipt mismatches, double success, double failure and unrelated SQL errors. Parallel database execution remains separate.');
