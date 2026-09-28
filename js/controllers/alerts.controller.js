// ======================================================
// CoreAML Alerts Controller
//
// Owns the DOM manipulation, state management, and 
// rendering logic for the Alerts Queue UI.
// ======================================================

import * as alertsService from "../services/alerts.service.js";

// Encapsulated State
let allAlerts = [];
let currentAlertsPage = 1;
const ALERTS_PER_PAGE = 6;
let currentAlertFilter = 'UNASSIGNED';

export async function loadAlertsQueue(filterStatus = 'UNASSIGNED') {
    try {
        currentAlertFilter = filterStatus;
        const tbody = document.getElementById('alerts-table-body');
        if (!tbody) return;

        tbody.innerHTML = `<tr><td colspan="6" class="text-center py-4 text-muted">Fetching ${filterStatus.toLowerCase()} alerts...</td></tr>`;

        // Fetch ALL alerts matching the status
        const alerts = await alertsService.getByStatus(filterStatus);
        
        allAlerts = alerts || [];
        currentAlertsPage = 1; // Reset to page 1 on new filter
        
        renderAlertsTable(); 

    } catch (err) {
        console.error("Critical Error loading alerts:", err);
        document.getElementById('alerts-table-body').innerHTML = 
            '<tr><td colspan="6" class="text-center py-4 text-danger small">Failed to load alerts from database.</td></tr>';
    }
}

function renderAlertsTable() {
    const tbody = document.getElementById('alerts-table-body');
    if (!tbody) return;
    tbody.innerHTML = ''; 

    if (allAlerts.length === 0) {
        tbody.innerHTML = `<tr><td colspan="6" class="text-center py-4 text-muted">No ${currentAlertFilter.toLowerCase()} alerts found.</td></tr>`;
        document.getElementById('alerts-pagination-info').innerText = 'Showing 0 entries';
        document.getElementById('alerts-pagination-controls').innerHTML = '';
        return;
    }

    const now = new Date();
    const startIndex = (currentAlertsPage - 1) * ALERTS_PER_PAGE;
    const endIndex = startIndex + ALERTS_PER_PAGE;
    const paginatedAlerts = allAlerts.slice(startIndex, endIndex);

    paginatedAlerts.forEach(alert => {
        const row = document.createElement('tr');
        row.className = 'main-alert-row';
        row.setAttribute('data-alert-id', alert.id);

        const dateObj = new Date(alert.created_at);
        const formattedDate = dateObj.toLocaleDateString() + ' ' + dateObj.toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'});
        
        const SLA_WINDOW_HOURS = 48;
        const hoursElapsed = (now - dateObj) / 36e5;
        const pctElapsed = Math.min(100, Math.max(0, (hoursElapsed / SLA_WINDOW_HOURS) * 100));
        const hoursLeft = Math.max(0, SLA_WINDOW_HOURS - hoursElapsed);

        let slaBarColor = '#15803d', slaLabel = `${hoursLeft.toFixed(1)}h left`, slaTextClass = 'text-success';
        if (hoursElapsed > SLA_WINDOW_HOURS) {
            slaBarColor = '#dc2626'; slaLabel = 'SLA BREACHED'; slaTextClass = 'text-danger';
        } else if (hoursElapsed > SLA_WINDOW_HOURS * 0.5) {
            slaBarColor = '#d97706'; slaLabel = `${hoursLeft.toFixed(1)}h left`; slaTextClass = 'text-warning';
        }

        const slaHtml = `
            <div class="d-flex flex-column gap-1" style="min-width: 140px;">
                <div class="text-muted" style="font-size: 0.7rem;">${formattedDate}</div>
                <div style="height: 4px; border-radius: 2px; background-color: #e9ecef; overflow: hidden;">
                    <div style="height: 100%; width: ${pctElapsed}%; background-color: ${slaBarColor}; border-radius: 2px;"></div>
                </div>
                <div class="${slaTextClass} fw-bold" style="font-size: 0.65rem; letter-spacing: 0.3px;">${slaLabel}</div>
            </div>`;

        let badgeClass = 'bg-secondary bg-opacity-10 text-secondary border-secondary'; 
        if (alert.severity === 'CRITICAL') badgeClass = 'bg-danger bg-opacity-10 text-danger border-danger';
        if (alert.severity === 'HIGH') badgeClass = 'bg-warning bg-opacity-10 text-warning border-warning';

        const isUnassigned = currentAlertFilter === 'UNASSIGNED';
        const btnText = isUnassigned ? 'Review Case' : 'Resume Case';
        
        const cust = alert.customers || {};
        const entityName = cust.entity_name || (cust.first_name ? `${cust.first_name} ${cust.last_name}` : 'Unknown Entity');
        
        const clickAction = isUnassigned 
            ? `previewUnassignedAlert('${alert.id}', '${alert.alert_ref}', '${entityName.replace(/'/g, "\\'")}', '${alert.rule_triggered}')` 
            : `resumeCase('${alert.id}', '${alert.alert_ref}', '${alert.customer_id}')`;

        row.innerHTML = `
            <td class="px-4 py-3 fw-medium text-dark small">${alert.alert_ref}</td>
            <td class="py-3 text-muted small">${entityName}</td>
            <td class="py-3 text-muted small">${alert.rule_triggered}</td>
            <td class="py-3">
                <span class="badge ${badgeClass} border border-opacity-25 rounded-pill px-2 py-1">${alert.severity}</span>
            </td>
            <td class="py-3 text-muted small text-nowrap">
                ${formattedDate}
                ${slaHtml}
            </td>
            <td class="px-4 py-3 text-end">
                <button class="btn btn-sm btn-outline-primary fw-bold text-uppercase" onclick="${clickAction}" style="font-size: 0.7rem;">${btnText}</button>
            </td>
        `;
        tbody.appendChild(row);
    });

    const totalItems = allAlerts.length;
    const totalPages = Math.ceil(totalItems / ALERTS_PER_PAGE);
    document.getElementById('alerts-pagination-info').innerText = `Showing ${startIndex + 1} to ${Math.min(endIndex, totalItems)} of ${totalItems} entries`;
    
    const paginationControls = document.getElementById('alerts-pagination-controls');
    if (paginationControls) {
        let paginationHtml = `<li class="page-item ${currentAlertsPage === 1 ? 'disabled' : ''}"><a class="page-link" href="#" onclick="changeAlertPage(${currentAlertsPage - 1}); return false;">Prev</a></li>`;
        let startPage = Math.max(1, currentAlertsPage - 2);
        let endPage = Math.min(totalPages, startPage + 4);
        if (endPage - startPage < 4) startPage = Math.max(1, endPage - 4);

        for(let i = startPage; i <= endPage; i++) {
            paginationHtml += `<li class="page-item ${currentAlertsPage === i ? 'active' : ''}"><a class="page-link" href="#" onclick="changeAlertPage(${i}); return false;">${i}</a></li>`;
        }
        paginationHtml += `<li class="page-item ${currentAlertsPage === totalPages || totalPages === 0 ? 'disabled' : ''}"><a class="page-link" href="#" onclick="changeAlertPage(${currentAlertsPage + 1}); return false;">Next</a></li>`;
        paginationControls.innerHTML = paginationHtml;
    }
}

export function changeAlertPage(page) {
    const totalPages = Math.ceil(allAlerts.length / ALERTS_PER_PAGE);
    if (page >= 1 && page <= totalPages) {
        currentAlertsPage = page;
        renderAlertsTable();
    }
}

export function applyAlertFilters() {
    const severityFilter = document.getElementById('filter-severity').value.toUpperCase();
    const dateFilter = document.getElementById('filter-date').value; 
    const mainRows = document.querySelectorAll('#alerts-table-body .main-alert-row');

    mainRows.forEach(row => {
        const severityCell = row.cells[3].innerText.toUpperCase();
        const dateCell = row.cells[4].innerText; 

        let matchesSeverity = severityFilter === 'ALL' || severityCell.includes(severityFilter);
        let matchesDate = true;

        if (dateFilter) {
            const [year, month, day] = dateFilter.split('-');
            if (!dateCell.includes(month) || !dateCell.includes(day)) {
                matchesDate = false;
            }
        }

        const detailsRow = document.querySelector(`.details-alert-row[data-parent-id="${row.getAttribute('data-alert-id')}"]`);

        if (matchesSeverity && matchesDate) {
            row.style.display = '';
            if (detailsRow) detailsRow.style.display = '';
        } else {
            row.style.display = 'none';
            if (detailsRow) detailsRow.style.display = 'none';
        }
    });
}

export function previewUnassignedAlert(alertId, alertRef, entityName, ruleTriggered) {
    document.getElementById('preview-alert-id').value = alertId;
    document.getElementById('preview-alert-ref').value = alertRef;
    document.getElementById('preview-modal-ref').innerText = `Alert Ref: ${alertRef}`;
    document.getElementById('preview-entity').innerText = entityName;
    document.getElementById('preview-rule').innerText = ruleTriggered;
    
    const alertData = allAlerts.find(a => a.id === alertId);
    let coreDetail = alertData?.details || "No contextual details provided by the rules engine.";
    let shapText = null;

    if (coreDetail.includes("[🤖 SHAP Analysis]:")) {
        const splitText = coreDetail.split("[🤖 SHAP Analysis]:");
        coreDetail = splitText[0].trim();
        shapText = splitText[1].trim();
    }

    document.getElementById('preview-engine-context').innerText = coreDetail;
    
    const shapContainer = document.getElementById('preview-shap-container');
    if (shapText) {
        shapContainer.classList.remove('d-none');
        document.getElementById('preview-shap-context').innerText = shapText;
    } else {
        shapContainer.classList.add('d-none');
    }

    new bootstrap.Modal(document.getElementById('alertPreviewModal')).show();
}

export function getAlertById(id) {
    return allAlerts.find(a => a.id === id);
}

window.getAlertById = getAlertById;

window.previewUnassignedAlert = previewUnassignedAlert;

// Expose necessary functions to the global window object for inline HTML event listeners
window.changeAlertPage = changeAlertPage;
window.applyAlertFilters = applyAlertFilters;