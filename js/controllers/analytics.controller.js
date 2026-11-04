import {supabase} from '../config.js';
import {getVerifiedSession} from '../services/auth.service.js';
import {createAnalyticsService} from '../services/analytics.service.js';
import {alertMetrics,customerMetrics,caseGroups} from '../services/analytics.model.js';
import {escapeRecord as e} from './customer-records.controller.js';
import * as casesController from './cases.controller.js';
const service=createAnalyticsService(supabase,getVerifiedSession),generations={compliance:0,manager:0,officer:0,activity:0};
const set=(id,text,title='')=>{const el=document.getElementById(id);if(el){el.innerText=text;el.title=title;}};
const percent=value=>value===null?'—':value.toFixed(1)+'%';
function reset(ids){for(const id of ids)set(id,'—','Unavailable until a complete measured read succeeds.');}
function chartUnavailable(el){el.setAttribute('aria-label','Chart unavailable; measured totals remain available.');el.title='Chart unavailable; measured totals remain available.';}
function clearCharts(ids){for(const id of ids){const el=document.getElementById(id);if(!el)continue;try{if(typeof Chart!=='undefined')Chart.getChart(el)?.destroy();}catch{chartUnavailable(el);}}}
function chart(id,type,labels,datasets){const el=document.getElementById(id);if(!el)return;try{if(typeof Chart==='undefined'){chartUnavailable(el);return;}Chart.getChart(el)?.destroy();new Chart(el.getContext('2d'),{type,data:{labels,datasets},options:{responsive:true,maintainAspectRatio:false}});}catch{chartUnavailable(el);}}
const notes=m=>`${m.ungrouped} investigating alerts have no case reference; ${m.inconsistent} groups have inconsistent status or ownership. These are excluded from case totals. Filing rate, resolution time and confirmed false-positive rate are unavailable without authoritative outcome records.`;
const complianceIds=['kpi-total-alerts','kpi-conversion','kpi-sar-rate','kpi-resolution'];
export async function renderComplianceCharts(){const ticket=++generations.compliance;reset(complianceIds);clearCharts(['caseStatusChart','alertTrendChart','workloadChart']);set('analytics-compliance-status','Loading measured dashboard data…');const body=document.getElementById('rule-performance-body');if(body)body.innerHTML='';
 try{const result=await service.alerts();if(ticket!==generations.compliance)return;const m=alertMetrics(result.rows,result.user);
  set('kpi-total-alerts',String(m.total));set('kpi-conversion',percent(m.linkedPercent),'Share of alerts created in the displayed UTC period that have a recorded case reference.');
  set('kpi-sar-rate','—','Confirmed regulatory submission receipts are not available to this metric.');set('kpi-resolution','—','A verified closure duration is not available to this metric.');
  set('analytics-compliance-status',`Period: ${m.period.from.slice(0,10)} through ${m.period.days.at(-1)} (UTC). Current workload uses all visible alert records. ${notes(m)}`);
  chart('caseStatusChart','doughnut',m.statuses.map(x=>x[0]),[{data:m.statuses.map(x=>x[1]),backgroundColor:['#64748b','#f59e0b','#dc2626','#0f172a','#16a34a']}]);
  chart('alertTrendChart','line',m.trend.map(x=>x[0]),[{label:'Alerts created (UTC)',data:m.trend.map(x=>x[1]),borderColor:'#dc2626',fill:false}]);
  chart('workloadChart','bar',m.workload.map(x=>x[0]==='Unassigned'?'Unassigned owner':'Officer '+x[0]),[{label:'Grouped investigating cases',data:m.workload.map(x=>x[1]),backgroundColor:'#0f172a'}]);
  if(body)body.innerHTML=m.rules.length?m.rules.map(r=>`<tr><td class="small px-4">${e(r.name)}</td><td>${r.triggers}</td><td title="Confirmed reviewed outcomes are not available">Unavailable</td><td>${percent(100*r.linked/r.triggers)}</td></tr>`).join(''):'<tr><td colspan="4">No alerts created in this UTC period.</td></tr>';
 }catch{if(ticket===generations.compliance){reset(complianceIds);set('analytics-compliance-status','Dashboard data unavailable. Totals have not been estimated. Use Refresh to retry.');if(body)body.innerHTML='<tr><td colspan="4">Rule metrics unavailable.</td></tr>';}}
 // Existing queue reads remain independent from chart availability.
 void casesController.loadEscalationQueue();void casesController.loadQADismissalQueue();
}
export async function renderManagerCharts(){const ticket=++generations.manager,ids=['kpi-comp-health','kpi-high-risk','kpi-open-cases','kpi-sars-filed'];reset(ids);clearCharts(['riskTierChart','industryRiskChart']);set('analytics-manager-status','Loading measured dashboard data…');
 try{const [c,a]=await Promise.all([service.customers(),service.alerts()]);if(ticket!==generations.manager)return;if(c.bank!==a.bank||c.user!==a.user)throw Error('Session changed.');const m=customerMetrics(c.rows),cases=alertMetrics(a.rows,a.user);
  set('kpi-comp-health',percent(m.recordedPercent),'Share of customers with LOW, MEDIUM, HIGH or VERY_HIGH recorded risk. This is data completeness, not compliance certification.');set('kpi-high-risk',String(m.high),'HIGH and VERY_HIGH customers.');set('kpi-open-cases',String(cases.openCases));set('kpi-sars-filed','—','Closed or escalated alerts are not confirmed regulatory submissions.');
  set('analytics-manager-status',`Recorded risk across ${c.rows.length} visible customers; ${m.tiers.UNKNOWN} unknown. ${notes(cases)}`);
  chart('riskTierChart','doughnut',Object.keys(m.tiers),[{data:Object.values(m.tiers),backgroundColor:['#16a34a','#f59e0b','#dc2626','#991b1b','#64748b']}]);
  chart('industryRiskChart','bar',m.industries.map(x=>x[0]),[{label:'HIGH + VERY_HIGH',data:m.industries.map(x=>x[1].high),backgroundColor:'#dc2626'},{label:'LOW + MEDIUM',data:m.industries.map(x=>x[1].other),backgroundColor:'#cbd5e1'},{label:'UNKNOWN',data:m.industries.map(x=>x[1].unknown),backgroundColor:'#64748b'}]);
 }catch{if(ticket===generations.manager){reset(ids);set('analytics-manager-status','Risk and case metrics unavailable. No compliance score or filing total has been inferred. Use Refresh to retry.');}}
}
export async function renderOfficerKPIs(){const ticket=++generations.officer,ids=['kpi-my-cases','kpi-critical-pool','kpi-sla-breach','kpi-my-conversion'];reset(ids);set('analytics-officer-status','Loading measured dashboard data…');
 try{const r=await service.alerts();if(ticket!==generations.officer)return;const m=alertMetrics(r.rows,r.user);set('kpi-my-cases',String(m.myCases));set('kpi-critical-pool',String(m.critical));set('kpi-sla-breach',String(m.agedCases),'Grouped cases containing an alert detected more than 48 hours ago; not a contractual SLA calculation.');set('kpi-my-conversion',String(m.myClosed),'Grouped cases recorded CLOSED; this is not a SAR submission count.');set('analytics-officer-status',notes(m));}
 catch{if(ticket===generations.officer){reset(ids);set('analytics-officer-status','Case metrics unavailable. Use Refresh to retry; unknown is not zero.');}}
}
export async function getRecordedCaseWorkload(){const result=await service.alerts();return caseGroups(result.rows).filter(g=>g.consistent);}

export async function renderActivityFeed() {
    try {
        const { data: { session } } = await supabase.auth.getSession();
        if (!session) return;
        
        const currentUserId = session.user.id;
        const jwtPayload = JSON.parse(atob(session.access_token.split('.')[1]));
        const userRole = jwtPayload.app_metadata?.role;

        const feedContainers = document.querySelectorAll('.position-relative.border-start.ms-3');
        if (feedContainers.length === 0) return;

        const complianceEventTypes = [
            'CASE_CLAIMED', 'CASE_REVIEW_SUBMITTED', 'SAR_FILED', 'EXECUTIVE_REVIEW', 'QA_REVIEW_CONFIRMED', 'EXECUTIVE_REVIEW_CONFIRMED', 'KYC_VERIFIED',
            'RISK_OVERRIDE', 'AML_RULE_DEPLOYED', 'SYSTEM_CONFIG_UPDATED', 
            'ARCHIVE_RETRIEVED', 'CTR_AUTO_FILED'
        ];

        let query = supabase
            .from('system_events')
            .select('*')
            .in('event_type', complianceEventTypes)
            .order('created_at', { ascending: false })
            .limit(4);

        if (userRole === 'compliance_officer') {
            query = query.eq('user_id', currentUserId);
        }

        const { data: events, error } = await query;
        if (error) throw error;

        if (!events || events.length === 0) {
            feedContainers.forEach(c => c.innerHTML = '<div class="text-muted small fst-italic py-2">No recent personal activity recorded.</div>');
            return;
        }

        let html = '';
        events.forEach((ev, i) => {
            const color = ev.severity === 'CRITICAL' ? 'bg-danger' : (ev.severity === 'WARNING' ? 'bg-warning' : 'bg-primary');
            const time = new Date(ev.created_at).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'});
            
            html += `
            <div class="position-relative mb-${i === events.length - 1 ? '0' : '4'}">
                <div class="position-absolute top-0 translate-middle-y p-1 ${color} rounded-circle border border-2 border-white" style="left: -1.3rem; margin-top: 0.4rem;"></div>
                <p class="text-sm text-dark fw-bold mb-0" style="font-size: 0.85rem; line-height: 1.2;">${e(ev.event_type.replace(/_/g, ' '))}</p>
                <p class="text-muted small mb-1 mt-1" style="font-size: 0.75rem; line-height: 1.4;">${e(ev.message)}</p>
                <span class="text-muted fw-semibold font-monospace" style="font-size: 0.65rem;">${time}</span>
            </div>`;
        });

        feedContainers.forEach(container => {
            container.innerHTML = html;
        });
    } catch (err) { 
        console.error("Error loading Compliance Activity Feed:", err); 
    }
}