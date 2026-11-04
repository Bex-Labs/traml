// Presentation-only navigation. Existing services and backend permissions remain authoritative.
export function mountCaseManagementHub(document,host=window,Observer=MutationObserver){
 const root=document.getElementById('view-case-management');if(!root)return;
 const panels={reviews:document.getElementById('case-review-submission-panel'),managed:document.getElementById('case-worklist-card'),qa:document.getElementById('qa-governance-section'),executive:document.getElementById('component-escalation-queue')};
 if(Object.values(panels).some(p=>!p))return;
 const entries=[
  ['qa','INDEPENDENT REVIEW','Dismissal Review Queue','Assess saved findings and evidence before approving or returning a dismissal.','Pending dismissal submissions'],
  ['executive','INDEPENDENT REVIEW','Early reporting guidance','Optional guidance before preparing a complete report. Final reporting approval remains separate.','Early guidance requests only'],
  ['reviews','REVIEW FOLLOW-UP','Your submitted reviews','Read your saved submissions, feedback and case history.','Latest submission per case'],
  ['managed','CASE PORTFOLIO','Active & archived managed cases','Browse authorized cases, see the assigned investigator and open the appropriate view.','One row per managed case group']
 ];
 const home=document.createElement('div');home.id='case-management-home';home.className='cm-hub';
 const buttons=new Map(),titles=new Map();
 for(const [key,kicker,title,description,note]of entries){
  const button=document.createElement('button');button.type='button';button.className='cm-entry';button.dataset.cmOpen=key;
  for(const [tag,text,cls]of [['span',kicker,'cm-kicker'],['strong',title,''],['span',description,''],['small',note,'']]){const n=document.createElement(tag);n.textContent=text;n.className=cls;button.append(n);}
  home.append(button);buttons.set(key,button);titles.set(key,title);
 }
 const filingEntry=document.createElement('a');filingEntry.className='cm-entry';filingEntry.href='./approved-reports.html';
 for(const [tag,text,cls]of [['span','POST-APPROVAL','cm-kicker'],['strong','Approved reports & filing',''],['span','Prepare report XML and record submission outcomes.',''],['small','Approval, export and filing stay distinct','']]){const n=document.createElement(tag);n.textContent=text;n.className=cls;filingEntry.append(n);}home.append(filingEntry);
 panels.reviews.before(home);
 const back=document.createElement('div');back.className='cm-page-toolbar';back.hidden=true;
 const backButton=document.createElement('button');backButton.type='button';backButton.className='btn btn-outline-secondary btn-sm';backButton.textContent='← Back to Case Management';
 const title=document.createElement('h5');title.id='cm-page-title';title.className='mb-0 fw-bold';title.tabIndex=-1;back.append(backButton,title);home.before(back);
 let page='home',last='managed';
 const allowed=key=>key==='managed'||(key==='reviews'?root.dataset.caseRole==='compliance_officer'&&!panels.reviews.classList.contains('d-none'):root.dataset.caseRole==='head_of_compliance');
 function render(next,focus=true){
  if(next!=='home'&&!allowed(next))next='home';page=next;root.dataset.casePage=next;
  home.hidden=next!=='home';back.hidden=next==='home';
  for(const [key,panel]of Object.entries(panels))panel.classList.toggle('cm-view-hidden',next!==key);
  if(next!=='home'){last=next;title.textContent=titles.get(next);if(focus)title.focus();}
  else if(focus){const target=buttons.get(last);(target&&!target.hidden?target:[...buttons.values()].find(b=>!b.hidden))?.focus();}
 }
 function sync(){filingEntry.hidden=!['head_of_compliance','compliance_officer'].includes(root.dataset.caseRole);const maker=root.dataset.caseRole==='compliance_officer';filingEntry.children[1].textContent=maker?'My report preparation':'Final report review & filing';filingEntry.children[2].textContent=maker?'Prepare sealed findings and report XML for one final approval.':'Approve complete report versions, file them and track external responses.';for(const [key,button]of buttons)button.hidden=!allowed(key);if(page!=='home'&&!allowed(page))render('home',false);}
 home.addEventListener('click',event=>{const button=event.target.closest('[data-cm-open]');if(!button||!home.contains(button)||!allowed(button.dataset.cmOpen))return;const key=button.dataset.cmOpen;render(key);if(key==='reviews')void host.loadMyReviewSubmissions?.();if(key==='qa')void host.loadQADismissalQueue?.();if(key==='executive')void host.loadEscalationQueue?.();});
 backButton.addEventListener('click',()=>render('home'));
 new Observer(sync).observe(root,{attributes:true,attributeFilter:['data-case-role']});
 new Observer(sync).observe(panels.reviews,{attributes:true,attributeFilter:['class']});
 render('home',false);sync();return {render,sync,get page(){return page;}};
}
if(typeof document!=='undefined')mountCaseManagementHub(document);
