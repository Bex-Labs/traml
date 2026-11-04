export function reportingWindow(now=Date.now()){
 const day=new Date(now);if(!Number.isFinite(day.getTime()))throw Error('Invalid reporting date.');
 const through=Date.UTC(day.getUTCFullYear(),day.getUTCMonth(),day.getUTCDate()+1),from=through-30*86400000;
 return {from:new Date(from).toISOString(),through:new Date(through).toISOString(),days:Array.from({length:30},(_,i)=>new Date(from+i*86400000).toISOString().slice(0,10))};
}
export function caseGroups(alerts){
 const groups=new Map();for(const a of alerts){if(!a.case_reference)continue;if(!groups.has(a.case_reference))groups.set(a.case_reference,[]);groups.get(a.case_reference).push(a);}
 return [...groups].map(([reference,rows])=>{const states=new Set(rows.map(a=>a.status)),owners=new Set(rows.map(a=>a.assigned_user_id||null));return {reference,rows,status:states.size===1?rows[0].status:'MIXED',owner:owners.size===1?rows[0].assigned_user_id:null,consistent:states.size===1&&owners.size===1};});
}
export function alertMetrics(alerts,user,now=Date.now()){
 const period=reportingWindow(now),recent=alerts.filter(a=>{const at=Date.parse(a.created_at);return Number.isFinite(at)&&at>=Date.parse(period.from)&&at<Date.parse(period.through)&&at<=Number(now);}),groups=caseGroups(alerts),valid=groups.filter(g=>g.consistent),open=valid.filter(g=>g.status==='INVESTIGATING');
 const trend=new Map(period.days.map(d=>[d,0])),statuses=new Map(),rules=new Map(),workload=new Map();
 for(const a of alerts)statuses.set(a.status||'UNKNOWN',(statuses.get(a.status||'UNKNOWN')||0)+1);
 for(const a of recent){const day=new Date(a.created_at).toISOString().slice(0,10);trend.set(day,(trend.get(day)||0)+1);const rule=a.rule_triggered||'Not recorded';if(!rules.has(rule))rules.set(rule,{name:rule,triggers:0,linked:0});const r=rules.get(rule);r.triggers++;if(a.case_reference)r.linked++;}
 for(const g of open){const key=g.owner||'Unassigned';workload.set(key,(workload.get(key)||0)+1);}
 const mine=open.filter(g=>g.owner===user),closed=valid.filter(g=>g.owner===user&&g.status==='CLOSED');
 return {period,total:recent.length,linkedPercent:recent.length?100*recent.filter(a=>a.case_reference).length/recent.length:null,statuses:[...statuses],trend:[...trend],rules:[...rules.values()].sort((a,b)=>b.triggers-a.triggers),workload:[...workload],openCases:open.length,myCases:mine.length,myClosed:closed.length,critical:alerts.filter(a=>a.status==='UNASSIGNED'&&a.severity==='CRITICAL').length,agedCases:mine.filter(g=>g.rows.some(a=>Number.isFinite(Date.parse(a.created_at))&&now-Date.parse(a.created_at)>48*36e5)).length,ungrouped:alerts.filter(a=>a.status==='INVESTIGATING'&&!a.case_reference).length,inconsistent:groups.filter(g=>!g.consistent).length};
}
export function customerMetrics(rows){
 const tiers={LOW:0,MEDIUM:0,HIGH:0,VERY_HIGH:0,UNKNOWN:0},industries=new Map();
 for(const c of rows){const tier=Object.hasOwn(tiers,c.risk_tier)&&c.risk_tier!=='UNKNOWN'?c.risk_tier:'UNKNOWN';tiers[tier]++;const industry=c.industry||'Not recorded';if(!industries.has(industry))industries.set(industry,{high:0,other:0,unknown:0});industries.get(industry)[['HIGH','VERY_HIGH'].includes(tier)?'high':tier==='UNKNOWN'?'unknown':'other']++;}
 return {tiers,high:tiers.HIGH+tiers.VERY_HIGH,recordedPercent:rows.length?100*(rows.length-tiers.UNKNOWN)/rows.length:null,industries:[...industries]};
}
