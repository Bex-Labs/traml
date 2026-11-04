const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),source=p=>fs.readFileSync(path.join(root,p),'utf8');
class N{constructor(tag,text=''){this.tag=tag;this.textContent=text;this.children=[];this.events={};this.attrs={};this.dataset={};this.classList={add:()=>{}};this.value='';}append(...x){for(const n of x)n.parentElement=this;this.children.push(...x)}replaceChildren(...x){this.children=x}setAttribute(k,v){this.attrs[k]=v}addEventListener(k,v){this.events[k]=v}closest(){return table}querySelector(){return head}get options(){return this.children}get selectedIndex(){return this.children.findIndex(x=>x.value===this.value)}get text(){return this.textContent}}
const table=new N('table'),head=new N('thead'),document={createElement:tag=>new N(tag),getElementById:()=>null};
const context=vm.createContext({document,Intl,Date,Number,String,Math,formatWaitingAge:()=> '2h waiting'});
vm.runInContext(source('js/controllers/managed-case-portfolio.js').replace(/^import .*;\r?\n/gm,'').replace(/export /g,''),context);
const walk=n=>[n,...n.children.flatMap(walk)],text=n=>[n.textContent,...n.children.map(text)].join(' ');
const r={id:'review-id',alert_id:'alert',case_reference:'CASE-ONE',entity_name:'Amara <Nwosu>',member_count:2,status:'PENDING_QA_REVIEW',consistent:true,severity:'HIGH',unknown_severity_count:1,owner_id:'officer',owner_name:'Assigned officer',rule_triggered:'Recorded detection',age_basis:'QA_SUBMISSION',occurred_at:'2026-11-02T09:00:00Z'};
(async()=>{
 for(const kind of ['QA','EXECUTIVE']){
  const body=new N('tbody'),controls=new N('div');let requests=[],pending=[],opened;
  const view=context.createManagedCasePortfolio({kind,body,controls,service:{load:f=>{requests.push(f);return new Promise((resolve,reject)=>pending.push({resolve,reject}))}},onOpen:row=>opened=row.id});
  const data=(rows=[{...r,status:kind==='QA'?'PENDING_QA_REVIEW':'PENDING_APPROVAL'}],total=rows.length)=>({rows,total,actor_id:'head',as_of:'2026-11-02T11:00:00Z'});
  let task=view.load();assert.equal(requests.at(-1).kind,kind);pending.shift().resolve(data());await task;
  assert(text(body).includes('Amara <Nwosu>'));assert(text(body).includes('Assigned officer'));assert(text(body).includes('Recorded detection'));assert(text(body).includes('severity value(s) missing'));
  const action=walk(body).find(n=>n.tag==='button');assert.equal(action.textContent,kind==='QA'?'Review dismissal':'Review executive package');action.events.click();assert.equal(opened,'review-id');
  assert(walk(controls).find(n=>n.tag==='div'&&n.className==='cp-shortcuts').hidden);assert(walk(controls).find(n=>n.tag==='select'&&n.id.endsWith('-status')).disabled);
  assert.equal(walk(controls).find(n=>n.tag==='select'&&n.id.endsWith('-sort')).value,'OLDEST');
  task=view.load();pending.shift().resolve(data([],0));await task;assert(text(body).includes('No pending'));assert(text(controls).includes('0 matching'));
  const older=view.load(),latest=view.load(),a=pending.shift(),b=pending.shift();b.resolve(data([{...r,entity_name:'Latest'}]));await latest;a.resolve(data([{...r,entity_name:'Old'}]));await older;assert(text(body).includes('Latest'));assert(!text(body).includes('Old'));
  task=view.load();pending.shift().reject(Error('Read denied'));await task;assert(text(body).includes('Read denied'));assert(!text(body).includes('Latest'));assert(text(controls).includes('Unavailable'));
  console.log('PASS '+kind+' renders safe entity-first rows, review-only actions, truthful empty/error states and rejects late responses');
 }
 for(const [actor,can,label]of [['head',false,'View investigation'],['officer',false,'View investigation'],['officer',true,'Continue investigation']]){
  const body=new N('tbody'),controls=new N('div'),view=context.createManagedCasePortfolio({body,controls,canInvestigate:()=>can,service:{load:async()=>({rows:[{...r,status:'INVESTIGATING'}],total:1,actor_id:actor,as_of:'2026-11-02T11:00:00Z'})}});await view.load();assert.equal(walk(body).find(n=>n.tag==='button').textContent,label);
 }
 console.log('PASS Continue investigation requires the owning actor and investigator role; supervisory views remain labelled read-only');
 const ownerContext=vm.createContext({AbortController,setTimeout,clearTimeout});vm.runInContext(source('js/controllers/workspace-owner.js').replace(/export /g,''),ownerContext);
 const draft={owner_id:'11111111-1111-4111-8111-111111111111',tenant_id:'22222222-2222-4222-8222-222222222222'};
 let calls=[];function client(result){const q={select:v=>(calls.push(['select',v]),q),eq:(k,v)=>(calls.push([k,v]),q),limit:()=>q,abortSignal:()=>Promise.resolve(result)};return {from:t=>(assert.equal(t,'user_profiles'),q)};}
 let owner=await ownerContext.resolveWorkspaceOwner(client({data:[{id:draft.owner_id,tenant_id:draft.tenant_id,full_name:'Real recorded owner'}]}),draft);assert.equal(owner.label,'Real recorded owner');assert(calls.some(([k,v])=>k==='id'&&v===draft.owner_id));assert(calls.some(([k,v])=>k==='tenant_id'&&v===draft.tenant_id));
 owner=await ownerContext.resolveWorkspaceOwner(client({error:Error('denied')}),draft);assert(owner.label.includes(draft.owner_id));
 owner=await ownerContext.resolveWorkspaceOwner(client({data:[{id:'wrong',tenant_id:draft.tenant_id,full_name:'Wrong person'}]}),draft);assert(!owner.label.includes('Wrong person'));
 owner=await ownerContext.resolveWorkspaceOwner({from:()=>({select(){return this},eq(){return this},limit(){return this},abortSignal:()=>new Promise(()=>{})})},draft,5);assert(owner.label.includes(draft.owner_id));
 console.log('PASS Owner label uses scoped recorded ownership; denied, mismatched and timed-out reads never substitute the signed-in viewer');
 const html=source('dashboard.html');assert(!html.includes("document.getElementById('inv-header-officer').innerText = document.getElementById('ui-user-name')"));assert(html.includes('renderWorkspaceOwner(document, recordedOwner, savedDraft)'));assert(html.includes("document.getElementById('case-review-submission-panel').classList.toggle('d-none', role!=='compliance_officer')"));assert(html.includes("box.readOnly = !!state.readOnly"));
 console.log('PASS Dashboard connects owner rendering and role-specific navigation while retaining server read-only control');
 class H extends N{constructor(tag){super(tag);this.classes=new Set();this.classList={add:x=>this.classes.add(x),contains:x=>this.classes.has(x),toggle:(x,on)=>on?this.classes.add(x):this.classes.delete(x)};}append(...nodes){for(const n of nodes){n.parent=this;this.children.push(n);}}before(n){const a=this.parent.children;a.splice(a.indexOf(this),0,n);n.parent=this.parent;}contains(n){return walk(this).includes(n)}closest(){return this}focus(){this.focused=true}}
 const ids={},hubRoot=new H('div');hubRoot.dataset.caseRole='head_of_compliance';ids['view-case-management']=hubRoot;
 for(const id of ['case-review-submission-panel','case-worklist-card','qa-governance-section','component-escalation-queue']){const n=new H('section');n.id=id;ids[id]=n;hubRoot.append(n);}
 const hubDoc={getElementById:id=>ids[id],createElement:tag=>new H(tag)},hubContext=vm.createContext({});
 vm.runInContext(source('js/controllers/case-management-hub.js').split("if(typeof document!=='undefined')")[0].replace(/export /g,''),hubContext);
 let qaLoads=0,execLoads=0;const hub=hubContext.mountCaseManagementHub(hubDoc,{loadQADismissalQueue:()=>qaLoads++,loadEscalationQueue:()=>execLoads++},class{observe(){}});
 const home=walk(hubRoot).find(n=>n.id==='case-management-home'),entry=key=>home.children.find(n=>n.dataset.cmOpen===key);
 assert(entry('reviews').hidden);assert(!entry('qa').hidden);assert(!entry('executive').hidden);assert(!entry('managed').hidden);
 home.events.click({target:entry('qa')});assert.equal(hub.page,'qa');assert.equal(qaLoads,1);assert(!ids['qa-governance-section'].classList.contains('cm-view-hidden'));assert(ids['component-escalation-queue'].classList.contains('cm-view-hidden'));
 walk(hubRoot).find(n=>n.tag==='button'&&n.textContent==='← Back to Case Management').events.click();assert.equal(hub.page,'home');assert(!home.hidden);
 home.events.click({target:entry('executive')});assert.equal(execLoads,1);assert.equal(hub.page,'executive');
 hubRoot.dataset.caseRole='compliance_officer';hub.sync();assert.equal(hub.page,'home');assert(entry('qa').hidden);assert(entry('executive').hidden);assert(!entry('reviews').hidden);home.events.click({target:entry('qa')});assert.equal(qaLoads,1);
 console.log('PASS Head and investigator hubs expose the appropriate destinations, isolate review pages and retain a working back button');
 console.log('6 simulated regression groups passed; signed-in authorization and visual verification remain separate.');
})().catch(e=>{console.error(e);process.exitCode=1});
