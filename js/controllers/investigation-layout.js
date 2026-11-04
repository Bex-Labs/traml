// Reorganize existing elements only. Workflow authority stays in the original handlers.
export function captureWorkspaceOrigin(document){
 let origin={view:'case-management',nav:'nav-case-management',label:'Back to Case Management'};
 document.addEventListener('click',event=>{if(!event.target.closest('button,a'))return;const cases=document.getElementById('view-case-management'),workspace=document.getElementById('view-investigation-workspace');if(workspace&&!workspace.classList.contains('d-none'))return;
 if(cases&&!cases.classList.contains('d-none')){const page=cases.dataset.casePage;origin={view:'case-management',nav:'nav-case-management',label:page==='managed'?'Back to Managed Cases':page==='reviews'?'Back to Submitted Reviews':'Back to Case Management'};}
 else if(['view-compliance-officer','view-head-compliance'].some(id=>{const n=document.getElementById(id);return n&&!n.classList.contains('d-none');}))origin={view:'dashboard',nav:'nav-command-center',label:'Back to Command Center'};
 },true);return ()=>({...origin});
}
export function enhanceInvestigationWorkspace(document,host=window){
 const root=document.getElementById('view-investigation-workspace');if(!root||root.dataset.layoutReady)return;
 const ids=['inv-header-customer','inv-header-type','inv-narrative-box','case-draft-status','network-graph-container','inv-timeline','inv-tx-list','inv-entity-list'];if(ids.some(id=>!document.getElementById(id)))return;
 const node=(tag,text='',cls='')=>{const n=document.createElement(tag);n.textContent=text;n.className=cls;return n;};
 const entity=document.getElementById('inv-header-customer'),type=document.getElementById('inv-header-type'),narrative=document.getElementById('inv-narrative-box'),status=document.getElementById('case-draft-status'),graph=document.getElementById('network-graph-container').closest('.card'),history=document.getElementById('inv-timeline').closest('.card'),header=entity.closest('.card'),footer=header.querySelector('.card-footer'),title=header.querySelector('h4'),column=entity.parentElement,facts=column.parentElement;
 if(!header||!footer||!graph||!history)return;
 const getOrigin=captureWorkspaceOrigin(document),toolbar=node('div','','iw-toolbar'),back=node('button','← Back to Case Management','btn btn-sm btn-outline-secondary');back.id='btn-investigation-back';back.type='button';back.addEventListener('click',()=>{const target=getOrigin();if(typeof host.leaveInvestigationWorkspace==='function')void host.leaveInvestigationWorkspace(target.view,target.nav);});toolbar.append(back);root.prepend(toolbar);
 for(const [label,id]of [['Findings','iw-findings'],['Evidence','iw-evidence'],['Relationships','iw-relationships']]){const a=node('a',label,'iw-jump');a.href='#'+id;toolbar.append(a);}
 const identity=node('div','','iw-identity');entity.classList.add('iw-entity-name');type.classList.add('iw-customer-type');identity.append(entity,type);title.after(identity);title.classList.add('iw-eyebrow');column.remove();facts.classList.add('iw-facts');for(const col of facts.children){col.classList.remove('col-lg-3');col.classList.add('col-lg-4');}
 const narrativeCard=narrative.closest('.card'),narrativeRow=narrativeCard.closest('.row');narrativeCard.id='iw-findings';narrativeCard.classList.add('iw-findings');narrative.placeholder='Record the activity reviewed, relevant evidence, your assessment and the reason for the proposed outcome.';narrative.style.resize='vertical';const label=narrativeCard.querySelector('h6');if(label)label.textContent='Investigation findings';const narrativeFooter=narrativeCard.querySelector('.card-footer');narrativeFooter.replaceChildren(status);const hint=node('p','Saved findings must contain at least 15 characters. Confirm the saved revision before relying on the draft.','iw-editor-hint');narrative.after(hint);
 const evidenceCard=document.getElementById('inv-tx-list').closest('.card');evidenceCard.id='iw-evidence';evidenceCard.classList.add('iw-evidence');const evTitle=evidenceCard.querySelector('h6');if(evTitle)evTitle.textContent='Transaction evidence';
 function disclosure(card,id,label,open){const d=node('details','','iw-disclosure');d.id=id;d.open=open;const summary=node('summary',label);card.before(d);d.append(summary,card);return d;}
 const graphDetails=disclosure(graph,'iw-relationships','Relationship graph · expand or collapse',true);graphDetails.addEventListener('toggle',()=>{if(graphDetails.open)host.dispatchEvent(new Event('resize'));});
 const historyDetails=disclosure(history,'iw-history','Case workflow history',false);historyDetails.querySelector('.card-header')?.classList.add('iw-repeated-heading');
 // Independent full-width sections; card height follows its own content.
 const snapshot=document.getElementById('inv-customer-snapshot')?.closest('.card');
 const subjects=document.getElementById('inv-entity-list').closest('.card');
 if(snapshot){snapshot.classList.remove('h-100');snapshot.classList.add('iw-snapshot');root.append(snapshot);}
 root.append(evidenceCard,graphDetails,historyDetails);
 subjects.classList.add('iw-subjects');root.append(subjects);
 narrativeCard.classList.add('iw-final-findings');root.append(narrativeCard);
 footer.classList.add('iw-actions');root.append(footer);
 // Remove empty layout wrappers only after all live cards have moved out.
 for(const row of [...root.children])if(row.classList.contains('row')&&!row.querySelector('.card,textarea,input,button,details'))row.remove();
 const close=document.getElementById('btn-case-close');close?.classList.add('iw-close-action');
 const summaryLink=document.getElementById('btn-case-summary');if(summaryLink)summaryLink.title='Open the confirmed saved internal summary';
 root.classList.add('iw-workspace');root.dataset.layoutReady='true';
 new MutationObserver(()=>{if(!root.classList.contains('d-none')){back.textContent='← '+getOrigin().label;}}).observe(root,{attributes:true,attributeFilter:['class']});
}
if(typeof document!=='undefined')enhanceInvestigationWorkspace(document);
