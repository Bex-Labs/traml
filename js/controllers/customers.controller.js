// One canonical Customer 360 panel for every entry point.
import {supabase} from '../config.js';
import {getVerifiedSession} from '../services/auth.service.js';
import {createIntelligenceService} from '../services/intelligence.service.js';
import {customerName,isUUID} from '../services/intelligence.model.js';
import {renderCustomerConnections,escapeRecord as e} from './customer-records.controller.js';
const records=createIntelligenceService(supabase,getVerifiedSession);
let generation=0,historyGeneration=0,bound=false;
const text=(id,value)=>{document.getElementById(id).innerText=value;};
const fields=['panel-entity-name','panel-entity-id','panel-total-alerts','panel-industry','panel-geography','panel-account-type','panel-onboarded','panel-bvn','panel-phone','panel-ubo'];
function reset(){window.currentViewedCustomer=null;window.currentRawUBO=null;window.currentMaskedUBO=null;fields.forEach(id=>text(id,'—'));for(const id of ['panel-risk-badge','panel-iei','panel-pep','panel-sanctions','customer-related-records'])document.getElementById(id).replaceChildren();const sar=document.getElementById('btn-manual-sar');sar.classList.add('disabled');sar.removeAttribute('data-customer-id');}
function badge(id,label,kind='secondary'){document.getElementById(id).innerHTML=`<span class="badge bg-${kind}">${e(label)}</span>`;}
export async function loadCustomerProfile(customerId,caseStatus='NONE'){
    const ticket=++generation;historyGeneration++;reset();
    const panel=document.getElementById('customer360Panel');
    if(!bound){panel.addEventListener('hide.bs.offcanvas',()=>{generation++;historyGeneration++;reset();});bound=true;}
    let bs=bootstrap.Offcanvas.getInstance(panel);if(!bs)bs=new bootstrap.Offcanvas(panel);bs.show();text('panel-entity-name','Loading customer…');
    try{
        if(!isUUID(customerId))throw Error('A valid linked customer reference is required.');
        const data=await records.customer(customerId);if(ticket!==generation)return;const c=data.customer;window.currentViewedCustomer=c;
        text('panel-entity-name',customerName(c));text('panel-entity-id','Customer Ref: '+c.id.slice(0,8));
        const tier=c.risk_tier||'UNKNOWN';badge('panel-risk-badge',`${tier} RISK (${c.risk_score??'unavailable'}/100)`,['HIGH','VERY_HIGH'].includes(tier)?'danger':tier==='MEDIUM'?'warning text-dark':tier==='LOW'?'success':'secondary');
        text('panel-total-alerts',data.alerts.error?'Unavailable':String(data.alerts.total??data.alerts.rows.length));
        text('panel-industry',c.industry||'Not recorded');text('panel-geography',c.geography||c.country||'Not recorded');
        text('panel-account-type',data.accounts.error?'Unavailable':[...new Set(data.accounts.rows.map(a=>a.account_type).filter(Boolean))].join(', ')||'Not recorded');
        text('panel-onboarded',c.created_at&&Number.isFinite(Date.parse(c.created_at))?new Date(c.created_at).toLocaleDateString('en-GB'):'Not recorded');
        text('panel-bvn',c.registration_number||c.bvn||'Not recorded');text('panel-phone',c.phone_number||'Not recorded');
        const ubo=c.ubo_name||'Not recorded',masked=c.ubo_name?c.ubo_name.slice(0,3)+'***':'Not recorded';window.currentRawUBO=ubo;window.currentMaskedUBO=masked;text('panel-ubo',masked);document.getElementById('panel-ubo').setAttribute('data-masked','true');text('icon-panel-ubo','visibility');
        badge('panel-iei',c.iei_exposure===true?'IEI RECORDED':c.iei_exposure===false?'NOT FLAGGED':'NOT RECORDED',c.iei_exposure===true?'danger':'secondary');
        badge('panel-pep',c.is_pep===true?'RECORDED PEP':c.is_pep===false?'NOT FLAGGED':'NOT RECORDED',c.is_pep===true?'danger':'secondary');
        badge('panel-sanctions','NOT VERIFIED IN THIS VIEW');
        renderCustomerConnections(document.getElementById('customer-related-records'),data);
        const sar=document.getElementById('btn-manual-sar');sar.disabled=true;sar.className='btn btn-outline-secondary w-100 mt-2';sar.innerText='Report preparation unavailable';sar.title='Report preparation and regulatory submission require a separately verified workflow.';
    }catch(error){if(ticket!==generation)return;reset();text('panel-entity-name','Customer unavailable');document.getElementById('customer-related-records').innerHTML=`<p class="text-danger small" role="alert">${e(error.message)}</p>`;}
}
export function openRiskOverrideModal(){if(!window.currentViewedCustomer)return;document.getElementById('override-customer-id').value=window.currentViewedCustomer.id;document.getElementById('override-tier').value=window.currentViewedCustomer.risk_tier||'LOW';new bootstrap.Modal(document.getElementById('riskOverrideModal')).show();}
export async function viewRiskHistory(){
    if(!window.currentViewedCustomer)return;const id=window.currentViewedCustomer.id,ticket=++historyGeneration,profileTicket=generation,tbody=document.getElementById('risk-history-body');
    tbody.innerHTML='<tr><td colspan="4">Loading recorded risk movements…</td></tr>';new bootstrap.Modal(document.getElementById('riskHistoryModal')).show();
    try{const data=await records.customer(id);if(ticket!==historyGeneration||profileTicket!==generation||window.currentViewedCustomer?.id!==id)return;if(data.risk.error)throw Error(data.risk.error);
        tbody.innerHTML=data.risk.rows.length?data.risk.rows.map(r=>`<tr><td class="small">ID ${e(r.id)}<br>Chronology unavailable</td><td class="small">${e(r.previous_score??'—')} → ${e(r.new_score??'—')}<br>${e(r.previous_tier)} → ${e(r.new_tier)}</td><td class="small">${e(r.change_reason||'Not recorded')}</td><td class="small">Not recorded</td></tr>`).join(''):'<tr><td colspan="4">No visible risk-change records.</td></tr>';
    }catch(error){if(ticket===historyGeneration&&profileTicket===generation)tbody.innerHTML=`<tr><td colspan="4" class="text-danger" role="alert">Risk history unavailable: ${e(error.message)}</td></tr>`;}
}
