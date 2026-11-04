export const customerName = c => c?.entity_name || c?.company_name || [c?.first_name,c?.last_name].filter(Boolean).join(' ') || 'Unnamed customer';
export const isUUID = value => typeof value==='string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
export function groupedCases(alerts) {
    const map=new Map();
    for(const a of alerts){const key=a.case_reference||a.id;if(!map.has(key))map.set(key,{reference:a.case_reference||a.alert_ref,id:a.id,owner:a.assigned_user_id,customer:a.customer_id,alerts:[],opened:a.created_at});map.get(key).alerts.push(a);}
    return [...map.values()];
}
export function workload(alerts) {
    const counts=new Map();
    for(const c of groupedCases(alerts.filter(a=>a.status==='INVESTIGATING'))){const owner=c.owner||'Unassigned';counts.set(owner,(counts.get(owner)||0)+1);}
    return [...counts].sort((a,b)=>b[1]-a[1]).map(([owner,cases])=>({owner,cases}));
}
export function activity(customer,transactions,alerts) {
    return [...transactions.map(t=>({at:t.transaction_timestamp,title:`${t.transaction_type||'Transaction'} • ${t.transaction_reference}`,kind:'transaction',id:t.id})),...alerts.map(a=>({at:a.created_at,title:`${a.rule_triggered||'Alert'} • ${a.status}`,kind:'alert',id:a.id}))].filter(e=>Number.isFinite(Date.parse(e.at))).sort((a,b)=>Date.parse(b.at)-Date.parse(a.at)).slice(0,30);
}
export function numberFilter(value,label) {
    if(value===''||value==null)return null;
    if(!/^\d+(?:\.\d{1,2})?$/.test(String(value))||!Number.isFinite(Number(value)))throw Error(`${label} must be a non-negative amount with up to two decimals.`);
    return Number(value);
}
export function transactionFilters(input={}) {
    const result={...input};result.min=numberFilter(input.min,'Minimum');result.max=numberFilter(input.max,'Maximum');
    if(result.min!==null&&result.max!==null&&result.min>result.max)throw Error('Minimum amount cannot exceed maximum amount.');
    for(const key of ['from','to'])if(input[key]&&(!/^\d{4}-\d{2}-\d{2}$/.test(input[key])||!Number.isFinite(Date.parse(input[key]+'T00:00:00Z'))||new Date(input[key]+'T00:00:00Z').toISOString().slice(0,10)!==input[key]))throw Error('Use a valid date.');
    if(input.from&&input.to&&input.from>input.to)throw Error('Start date cannot follow end date.');
    if(input.from)result.from=new Date(input.from+'T00:00:00Z').toISOString();
    if(input.to)result.to=new Date(Date.parse(input.to+'T00:00:00Z')+86400000).toISOString();
    if(input.type&&!['CREDIT','DEBIT'].includes(input.type))throw Error('Choose credits, debits or all types.');
    if(input.customer&&!isUUID(input.customer))throw Error('Invalid customer reference.');
    if(input.currency&&!/^[A-Z]{3}$/.test(input.currency))throw Error('Currency must be a three-letter code.');
    if(String(input.reference||'').length>100)throw Error('Reference search is too long.');
    return result;
}
