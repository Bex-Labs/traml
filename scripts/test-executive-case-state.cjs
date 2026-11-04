const fs=require('fs'),vm=require('vm'),path=require('path'),assert=require('node:assert/strict');const root=path.resolve(__dirname,'..');
class N{constructor(tag,text=''){this.tag=tag;this.textContent=text;this.children=[];this.events={};this.attrs={};this.dataset={};this.classList={add:()=>{}};this.value='';}append(...x){for(const n of x)n.parentElement=this;this.children.push(...x)}replaceChildren(...x){this.children=x}setAttribute(k,v){this.attrs[k]=v}addEventListener(k,v){this.events[k]=v}closest(){return table}querySelector(){return head}get options(){return this.children}get selectedIndex(){return this.children.findIndex(x=>x.value===this.value)}get text(){return this.textContent}}
const table=new N('table'),head=new N('thead'),viewport={scrollTop:0},document={createElement:tag=>new N(tag),getElementById:()=>viewport};const c=vm.createContext({document,Intl,Date,Number,String,Math,formatWaitingAge:()=> '2h waiting'});vm.runInContext(fs.readFileSync(path.join(root,'js/controllers/managed-case-portfolio.js'),'utf8').replace(/^import .*;\r?\n/gm,'').replace(/export /g,''),c);const body=new N('tbody'),controls=new N('div');let requests=[],pending=[],opened=0;const service={load:f=>{requests.push(f);return new Promise((resolve,reject)=>pending.push({resolve,reject}))}};const view=c.createManagedCasePortfolio({body,controls,service,canInvestigate:()=>true,onOpen:()=>opened++});const walk=n=>[n,...n.children.flatMap(walk)],text=n=>[n.textContent,...n.children.map(text)].join(' ');const button=t=>walk(controls).find(n=>n.tag==='button'&&n.textContent===t);const r={id:'id',alert_id:'alert',case_reference:'CASE-ONE',entity_name:'Tunde <Balogun>',member_count:2,status:'INVESTIGATING',consistent:true,severity:'HIGH',unknown_severity_count:0,owner_id:'officer-id',owner_name:'Officer',age_basis:'CLAIM',occurred_at:'2026-11-02T09:00:00Z'};const result=(rows=[r],total=rows.length)=>({rows,total,actor_id:'officer-id',as_of:'2026-11-02T11:00:00Z'});
(async()=>{
 const approved={...r,status:'ESCALATED',age_basis:'INTERNAL_PREPARATION',is_waiting:false,age_quality:'NOT_WAITING'};
 const pendingRow={...r,status:'ESCALATED',age_basis:'EXECUTIVE_SUBMISSION',is_waiting:true,age_quality:'RECORDED'};
 async function show(row){const task=view.load();pending.shift().resolve(result([row]));await task;}
 await show(approved);
 assert(text(body).includes('Executive approved'));assert(!text(body).includes('Awaiting independent review'));
 let links=walk(body).filter(n=>n.tag==='a');assert.equal(links.length,1);assert.equal(links[0].textContent,'View approved package');assert.equal(links[0].href,'./case-summary.html?alert='+encodeURIComponent(r.alert_id));assert(!walk(body).some(n=>n.tag==='button'));assert(text(body).includes('does not confirm regulatory filing'));assert(text(body).includes('The assigned officer prepares'));
 console.log('PASS Approved executive case shows its approval and a role-appropriate reporting/summary destination');
 await show(pendingRow);assert(text(body).includes('Awaiting executive review'));assert(text(body).includes('Head of Compliance decision pending'));assert(!walk(body).some(n=>n.tag==='a'));assert(!text(body).includes('Executive approved'));
 console.log('PASS Pending executive submission remains explicitly assigned to the Head review stage');
 const headBody=new N('tbody'),headControls=new N('div'),headView=c.createManagedCasePortfolio({body:headBody,controls:headControls,canFile:()=>true,service:{load:async()=>result([approved])}});await headView.load();const headLink=walk(headBody).find(n=>n.tag==='a');assert.equal(headLink.href,'./approved-reports.html?case='+encodeURIComponent(r.case_reference));assert.equal(headLink.textContent,'Review / track report');

 for(const changed of [{age_basis:'REVIEW_TIMESTAMP_MISSING'},{is_waiting:true},{age_quality:'MISSING'}]){await show({...approved,...changed});assert(!text(body).includes('Executive approved'));assert(!walk(body).some(n=>n.tag==='a'));}
 console.log('PASS Missing or contradictory approval basis never becomes an approved package');
 await show({...approved,status:'MIXED',consistent:false});assert(text(body).includes('Needs reconciliation'));assert(!walk(body).some(n=>n.tag==='a'));
 await show({...r,status:'PENDING_QA_REVIEW'});assert(text(body).includes('Dismissal decision pending'));
 await show({...r,status:'CLOSED'});assert(text(body).includes('View closed case'));
 console.log('PASS Mixed, dismissal-pending and closed cases retain distinct actions');
 const a=view.load(),b=view.load(),pa=pending.shift(),pb=pending.shift();pb.resolve(result([pendingRow]));await b;pa.resolve(result([approved]));await a;assert(!walk(body).some(n=>n.tag==='a'));
 const task=view.load();pending.shift().reject(Error('Read failed'));await task;assert(!walk(body).some(n=>n.tag==='a'));assert(text(body).includes('Read failed'));
 console.log('PASS Late approved responses and failed reads cannot leave an obsolete approved-package action');
 console.log('5 simulated executive-state checks passed; signed-in local verification remains separate.');
})().catch(e=>{console.error(e);process.exitCode=1});
