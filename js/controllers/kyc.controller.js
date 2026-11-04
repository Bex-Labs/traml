import {getDirectoryPage} from '../services/customers.service.js';
import {customerName} from '../services/intelligence.model.js';
import {escapeRecord as e} from './customer-records.controller.js';
let filter='ALL',offset=0,generation=0,bound=false,timer;
function bind(){if(bound)return;bound=true;
    document.getElementById('kyc-directory-search')?.addEventListener('input',()=>{generation++;clearTimeout(timer);timer=setTimeout(()=>{offset=0;void loadKYCDirectory();},250);});
    document.getElementById('kyc-page-prev')?.addEventListener('click',()=>{offset=Math.max(0,offset-25);void loadKYCDirectory();});
    document.getElementById('kyc-page-next')?.addEventListener('click',()=>{offset+=25;void loadKYCDirectory();});
    document.getElementById('kyc-directory-body')?.addEventListener('click',event=>{const b=event.target.closest('button');if(!b)return;if(b.dataset.profile)void window.loadCustomerProfile(b.dataset.profile);else if(b.dataset.review)void window.openKYCVerification(b.dataset.review);});
}
export async function loadKYCDirectory(){
    bind();const tbody=document.getElementById('kyc-directory-body');if(!tbody)return;const ticket=++generation;
    tbody.innerHTML='<tr><td colspan="5" class="text-muted text-center py-4">Loading customer directory…</td></tr>';document.getElementById('kyc-directory-count').innerText='';for(const id of ['kyc-page-prev','kyc-page-next'])document.getElementById(id).disabled=true;
    try{const data=await getDirectoryPage(filter,document.getElementById('kyc-directory-search')?.value||'',offset);if(ticket!==generation)return;
        tbody.innerHTML=data.rows.length?data.rows.map(c=>{const tier=c.risk_tier||'UNKNOWN',tone=['HIGH','VERY_HIGH'].includes(tier)?'danger':tier==='MEDIUM'?'warning':tier==='LOW'?'success':'secondary';return `<tr><td class="px-4 py-3 small"><strong>${e(customerName(c))}</strong><div class="text-muted">${e(c.registration_number?'RC: '+c.registration_number:c.bvn?'BVN: '+c.bvn:'ID: '+c.id.slice(0,8))}</div></td><td class="small">${e(c.kyc_status||'Not recorded')}</td><td class="small">${e(c.industry||'Not recorded')}<div>${e(c.geography||'Not recorded')}</div></td><td class="small"><span class="badge bg-${tone}">${e(tier)} (${e(c.risk_score??'Unavailable')})</span></td><td class="text-end px-4"><button class="btn btn-sm btn-outline-secondary" data-profile="${e(c.id)}">View Profile</button>${c.kyc_status!=='COMPLETED'?` <button class="btn btn-sm btn-outline-info" data-review="${e(c.id)}">Review KYC</button>`:''}</td></tr>`;}).join(''):'<tr><td colspan="5" class="text-center py-4">No authorized customers match this search.</td></tr>';
        document.getElementById('kyc-directory-count').innerText=`${data.total?data.offset+1:0}–${Math.min(data.offset+data.rows.length,data.total)} of ${data.total} customers`;
        document.getElementById('kyc-page-prev').disabled=offset===0;document.getElementById('kyc-page-next').disabled=offset+25>=data.total;
    }catch(error){if(ticket===generation)tbody.innerHTML=`<tr><td colspan="5" class="text-danger" role="alert">Directory unavailable: ${e(error.message)}</td></tr>`;}
}
export function switchKycTab(next,activeBtn){filter=next;offset=0;for(const id of ['tab-kyc-all','tab-kyc-pending','tab-kyc-completed']){const b=document.getElementById(id);b?.classList.remove('btn-dark','active');b?.classList.add('btn-outline-dark');}activeBtn.classList.remove('btn-outline-dark');activeBtn.classList.add('btn-dark','active');void loadKYCDirectory();}
