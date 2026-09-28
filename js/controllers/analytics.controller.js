// ======================================================
// CoreAML Analytics Controller
//
// Owns the DOM manipulation and data aggregation for 
// dashboards, charts, KPIs, and the activity feed.
// ======================================================

import { supabase } from "../config.js";
import * as casesController from "./cases.controller.js";

export async function renderComplianceCharts() {
    try {
        const { data: alerts, error } = await supabase.from('alerts').select('status, severity, rule_triggered, created_at, assigned_user_id').order('created_at', { ascending: true });
        if (error) throw error;

        const totalAlertsElement = document.getElementById('kpi-total-alerts');
        if (totalAlertsElement) totalAlertsElement.innerText = alerts.length.toLocaleString();

        let statusCounts = { unassigned: 0, investigation: 0, escalated: 0 };
        let rulesMap = {};
        let dateMap = {};
        let workloadMap = {}; 

        alerts.forEach(alert => {
            if (alert.status === 'UNASSIGNED') statusCounts.unassigned++;
            else if (alert.status === 'INVESTIGATING') statusCounts.investigation++;
            else if (alert.status === 'ESCALATED' || alert.status === 'CLOSED') statusCounts.escalated++;

            const rule = alert.rule_triggered || 'Unknown Rule';
            if (!rulesMap[rule]) rulesMap[rule] = { triggers: 0, escalations: 0 };
            rulesMap[rule].triggers++;
            if (alert.status === 'ESCALATED') rulesMap[rule].escalations++;

            const dateStr = new Date(alert.created_at).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
            if (!dateMap[dateStr]) dateMap[dateStr] = 0;
            dateMap[dateStr]++;

            if (alert.status === 'INVESTIGATING') {
                let assignee = alert.assigned_user_id ? `Officer ${alert.assigned_user_id.substring(0,4)}` : 'Unassigned';
                if (!workloadMap[assignee]) workloadMap[assignee] = 0;
                workloadMap[assignee]++;
            }
        });

        const totalAlerts = alerts.length;
        const totalCases = statusCounts.investigation + statusCounts.escalated;
        const conversionRate = totalAlerts > 0 ? ((totalCases / totalAlerts) * 100).toFixed(1) : 0;
        const sarRate = totalCases > 0 ? ((statusCounts.escalated / totalCases) * 100).toFixed(1) : 0;

        const conversionEl = document.getElementById('kpi-conversion');
        if (conversionEl) conversionEl.innerText = `${conversionRate}%`;
        
        const sarEl = document.getElementById('kpi-sar-rate');
        if (sarEl) sarEl.innerText = `${sarRate}%`;

        const statusCtx = document.getElementById('caseStatusChart');
        if (Chart.getChart(statusCtx)) Chart.getChart(statusCtx).destroy(); 
        new Chart(statusCtx.getContext('2d'), {
            type: 'doughnut',
            data: {
                labels: ['Unassigned', 'Under Investigation', 'Resolved/Escalated'],
                datasets: [{
                    data: [statusCounts.unassigned, statusCounts.investigation, statusCounts.escalated],
                    backgroundColor: ['#64748b', '#f59e0b', '#ef4444'], borderWidth: 0
                }]
            },
            options: { responsive: true, maintainAspectRatio: false, cutout: '70%' }
        });

        const trendCtx = document.getElementById('alertTrendChart');
        if (Chart.getChart(trendCtx)) Chart.getChart(trendCtx).destroy();
        new Chart(trendCtx.getContext('2d'), {
            type: 'line',
            data: {
                labels: Object.keys(dateMap),
                datasets: [{
                    label: 'Daily Alerts', data: Object.values(dateMap),
                    borderColor: '#0ea5e9', backgroundColor: 'rgba(14, 165, 233, 0.1)', borderWidth: 2, fill: true, tension: 0.3
                }]
            },
            options: { responsive: true, maintainAspectRatio: false }
        });

        const workloadCtx = document.getElementById('workloadChart');
        if (workloadCtx) {
            if (Chart.getChart(workloadCtx)) Chart.getChart(workloadCtx).destroy();
            new Chart(workloadCtx.getContext('2d'), {
                type: 'bar',
                data: {
                    labels: Object.keys(workloadMap).length > 0 ? Object.keys(workloadMap) : ['No Active Cases'],
                    datasets: [{
                        label: 'Active Cases',
                        data: Object.values(workloadMap).length > 0 ? Object.values(workloadMap) : [0],
                        backgroundColor: '#3b82f6'
                    }]
                },
                options: { responsive: true, maintainAspectRatio: false }
            });
        }

        const tbody = document.getElementById('rule-performance-body');
        if (tbody) {
            tbody.innerHTML = '';
            const sortedRules = Object.entries(rulesMap).sort((a, b) => b[1].triggers - a[1].triggers);
            sortedRules.forEach(([ruleName, metrics]) => {
                const row = document.createElement('tr');
                const rate = metrics.triggers > 0 ? Math.round((metrics.escalations / metrics.triggers) * 100) : 0;
                const fpRate = 100 - rate;
                row.innerHTML = `
                    <td class="px-4 fw-semibold small text-dark">${ruleName}</td>
                    <td class="small fw-medium">${metrics.triggers}</td>
                    <td class="small fw-bold ${fpRate > 60 ? 'text-danger' : 'text-success'}">${fpRate}%</td>
                    <td class="small fw-bold">${rate}%</td>
                `;
                tbody.appendChild(row);
            });
        }
        
        // Securely fire the queue refreshes using the imported controller
        casesController.loadEscalationQueue();
        casesController.loadQADismissalQueue();
        
    } catch (err) { console.error("Error loading Compliance charts:", err); }
}

export async function renderManagerCharts() {
    try {
        const { data: customers, error } = await supabase.from('customers').select('risk_tier, industry');
        if (error) throw error;

        let tierCounts = { low: 0, medium: 0, high: 0 };
        let indMap = {};
        
        customers.forEach(c => {
            if (c.risk_tier === 'HIGH') tierCounts.high++;
            else if (c.risk_tier === 'MEDIUM') tierCounts.medium++;
            else tierCounts.low++;

            const ind = c.industry || 'Other';
            if (!indMap[ind]) indMap[ind] = { high: 0, low: 0 };
            if (c.risk_tier === 'HIGH') indMap[ind].high++;
            else indMap[ind].low++;
        });

        const health = customers.length > 0 ? Math.max(0, 100 - Math.round((tierCounts.high / customers.length) * 100)) : 100;
        document.getElementById('kpi-comp-health').innerText = `${health}%`;
        document.getElementById('kpi-high-risk').innerText = tierCounts.high;

        const { data: alerts } = await supabase.from('alerts').select('status');
        if (alerts) {
            document.getElementById('kpi-open-cases').innerText = alerts.filter(a => a.status === 'INVESTIGATING').length;
            document.getElementById('kpi-sars-filed').innerText = alerts.filter(a => a.status === 'ESCALATED' || a.status === 'CLOSED').length;
        }

        const tierCtx = document.getElementById('riskTierChart').getContext('2d');
        if (Chart.getChart(tierCtx)) Chart.getChart(tierCtx).destroy();
        new Chart(tierCtx, {
            type: 'doughnut',
            data: {
                labels: ['Low Risk', 'Medium Risk', 'High Risk'],
                datasets: [{
                    data: [tierCounts.low, tierCounts.medium, tierCounts.high],
                    backgroundColor: ['#10b981', '#f59e0b', '#ef4444'], borderWidth: 0
                }]
            },
            options: { responsive: true, maintainAspectRatio: false, cutout: '65%' }
        });

        const indCtx = document.getElementById('industryRiskChart').getContext('2d');
        if (Chart.getChart(indCtx)) Chart.getChart(indCtx).destroy();
        const indLabels = Object.keys(indMap);
        new Chart(indCtx, {
            type: 'bar',
            data: {
                labels: indLabels,
                datasets: [
                    { label: 'High Risk', data: indLabels.map(l => indMap[l].high), backgroundColor: '#ef4444' },
                    { label: 'Medium/Low Risk', data: indLabels.map(l => indMap[l].low), backgroundColor: '#cbd5e1' }
                ]
            },
            options: { responsive: true, maintainAspectRatio: false, scales: { x: { stacked: true }, y: { stacked: true } } }
        });
    } catch (err) { console.error("Error loading Manager charts:", err); }
}

export async function renderOfficerKPIs(userId) {
    try {
        const { data: alerts } = await supabase.from('alerts').select('status, severity, assigned_user_id, created_at');
        if (!alerts) return;

        let myCases = 0, criticalPool = 0, slaBreaches = 0, myResolved = 0;
        const now = new Date();

        alerts.forEach(a => {
            if (a.status === 'UNASSIGNED' && a.severity === 'CRITICAL') criticalPool++;
            if (a.assigned_user_id === userId) {
                if (a.status === 'INVESTIGATING') {
                    myCases++;
                    if ((now - new Date(a.created_at)) / 36e5 > 48) slaBreaches++;
                } else if (a.status === 'ESCALATED' || a.status === 'CLOSED') {
                    myResolved++;
                }
            }
        });

        const total = myCases + myResolved;
        document.getElementById('kpi-my-cases').innerText = myCases;
        document.getElementById('kpi-critical-pool').innerText = criticalPool;
        document.getElementById('kpi-sla-breach').innerText = slaBreaches;
        document.getElementById('kpi-my-conversion').innerText = total > 0 ? `${((myResolved / total) * 100).toFixed(1)}%` : '0.0%';
    } catch (err) { console.error("Error loading Officer KPIs:", err); }
}

export async function renderActivityFeed() {
    try {
        const { data: { session } } = await supabase.auth.getSession();
        if (!session) return;
        
        const currentUserId = session.user.id;
        const jwtPayload = JSON.parse(atob(session.access_token.split('.')[1]));
        const userRole = jwtPayload.app_metadata?.role || jwtPayload.user_metadata?.role;

        const feedContainers = document.querySelectorAll('.position-relative.border-start.ms-3');
        if (feedContainers.length === 0) return;

        const complianceEventTypes = [
            'CASE_CLAIMED', 'SAR_FILED', 'EXECUTIVE_REVIEW', 'KYC_VERIFIED', 
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
                <p class="text-sm text-dark fw-bold mb-0" style="font-size: 0.85rem; line-height: 1.2;">${ev.event_type.replace(/_/g, ' ')}</p>
                <p class="text-muted small mb-1 mt-1" style="font-size: 0.75rem; line-height: 1.4;">${ev.message}</p>
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