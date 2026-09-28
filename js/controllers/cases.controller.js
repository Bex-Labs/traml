// ======================================================
// CoreAML Cases Controller
//
// Owns the DOM manipulation, state management, and 
// rendering logic for Case Management, Escalations, and QA.
// ======================================================

import { supabase } from "../config.js";

export async function loadQADismissalQueue() {
    try {
        const tbody = document.getElementById('qa-dismissal-body');
        const badge = document.getElementById('qa-queue-count');
        if (!tbody) return;

        const { data: alerts, error } = await supabase
            .from('alerts')
            .select(`
                id, alert_ref, rule_triggered, details, created_at,
                customers ( entity_name, first_name, last_name )
            `)
            .eq('status', 'PENDING_QA_REVIEW')
            .order('created_at', { ascending: false });

        if (error) throw error;

        if (badge) badge.innerText = `${alerts.length} PENDING`;
        tbody.innerHTML = '';

        if (alerts.length === 0) {
            tbody.innerHTML = '<tr><td colspan="5" class="text-center py-4 text-muted fw-semibold small">No false-positive dismissals awaiting QA verification.</td></tr>';
            return;
        }

        alerts.forEach(a => {
            const row = document.createElement('tr');
            const cust = a.customers || {};
            const entityName = cust.entity_name || (cust.first_name ? `${cust.first_name} ${cust.last_name}` : 'Unknown Entity');
            const noteSnippet = a.details ? (a.details.length > 55 ? a.details.substring(0, 55) + '...' : a.details) : 'No rationale provided.';

            row.innerHTML = `
                <td class="px-4 py-3 fw-bold text-dark small font-monospace">${a.alert_ref}</td>
                <td class="py-3 text-dark fw-medium small">${entityName}</td>
                <td class="py-3 text-muted small">${a.rule_triggered}</td>
                <td class="py-3 text-muted small fst-italic">"${noteSnippet}"</td>
                <td class="px-4 py-3 text-end">
                    <button class="btn btn-sm btn-warning text-dark fw-bold uppercase" onclick="openQAReview('${a.id}', '${a.alert_ref}', \`${a.details || 'No rationale logged.'}\`)" style="font-size: 0.68rem;">Verify Rationale</button>
                </td>
            `;
            tbody.appendChild(row);
        });

    } catch (err) {
        console.error("QA Queue Load Error:", err);
        const tbody = document.getElementById('qa-dismissal-body');
        if (tbody) tbody.innerHTML = '<tr><td colspan="5" class="text-center py-4 text-danger small">Failed to load QA queue.</td></tr>';
    }
}

export async function loadEscalationQueue() {
    try {
        const tbody = document.getElementById('escalation-queue-body');
        if (!tbody) return;
        tbody.innerHTML = '<tr><td colspan="5" class="text-center py-4 text-muted">Fetching STR drafts...</td></tr>';

        const { data: strs, error } = await supabase
            .from('suspicious_transaction_reports')
            .select(`
                id, status, investigator_notes, report_data, created_at,
                alerts ( alert_ref, rule_triggered, customers ( entity_name, first_name, last_name ) )
            `)
            .eq('status', 'PENDING_APPROVAL')
            .order('created_at', { ascending: false });

        if (error) throw error;
        tbody.innerHTML = '';

        if (strs.length === 0) {
            tbody.innerHTML = '<tr><td colspan="5" class="text-center py-4 text-muted">No STRs pending executive approval.</td></tr>';
            return;
        }

        strs.forEach(str => {
            const row = document.createElement('tr');
            const alert = str.alerts || {};
            const cust = alert.customers || {};
            
            const alertRef = alert.alert_ref || 'UNKNOWN';
            const rule = alert.rule_triggered || 'Unknown Rule';
            const entityName = cust.entity_name || (cust.first_name ? `${cust.first_name} ${cust.last_name}` : 'Unknown Entity');
            
            let noteSnippet = str.investigator_notes ? (str.investigator_notes.length > 40 ? str.investigator_notes.substring(0, 40) + '...' : str.investigator_notes) : 'No notes provided.';
            const encodedData = encodeURIComponent(JSON.stringify(str.report_data || {}));

            row.innerHTML = `
                <td class="px-4 py-3 fw-bold text-dark small">${alertRef.replace('ALT', 'STR')}</td>
                <td class="py-3 text-muted small">${entityName}</td>
                <td class="py-3 text-muted small">${rule}</td>
                <td class="py-3 text-muted small fst-italic">"${noteSnippet}"</td>
                <td class="px-4 py-3 text-end">
                    <button class="btn btn-sm btn-danger fw-bold uppercase" onclick="openExecutiveReview('${str.id}', '${alertRef}', \`${str.investigator_notes || 'No notes.'}\`, '${encodedData}')" style="font-size: 0.7rem;">Review STR</button>
                </td>
            `;
            tbody.appendChild(row);
        });
    } catch (err) {
        console.error("Error loading escalation queue:", err);
    }
}

export async function loadCaseManagement() {
    try {
        const tbody = document.getElementById('case-management-body');
        if (!tbody) return;
        tbody.innerHTML = '<tr><td colspan="6" class="text-center py-4 text-muted">Loading cases...</td></tr>';

        const { data: cases, error } = await supabase
            .from('alerts')
            .select(`
                id, alert_ref, rule_triggered, severity, status, details, created_at, customer_id, 
                customers ( entity_name, first_name, last_name )
            `)
            .neq('status', 'UNASSIGNED')
            .order('created_at', { ascending: false });

        if (error) throw error;
        tbody.innerHTML = '';

        if (cases.length === 0) {
            tbody.innerHTML = '<tr><td colspan="6" class="text-center py-4 text-muted">No active or archived cases found.</td></tr>';
            return;
        }

        const now = new Date(); // Current time for SLA math

        cases.forEach(c => {
            const row = document.createElement('tr');
            let statusBadge = c.status === 'ESCALATED' ? 'bg-warning text-dark' : (c.status === 'CLOSED' ? 'bg-success' : 'bg-dark text-white');
            let noteSnippet = c.details ? (c.details.length > 40 ? c.details.substring(0, 40) + '...' : c.details) : 'No notes provided.';

            const cust = c.customers || {};
            const entityName = cust.entity_name || (cust.first_name ? `${cust.first_name} ${cust.last_name}` : 'Unknown Entity');

            // --- 14-DAY CASE SLA MATH ---
            const dateObj = new Date(c.created_at);
            const hoursElapsed = (now - dateObj) / 36e5;
            let slaHtml = '';

            // Only track SLA if the case is still actively under investigation
            if (c.status !== 'CLOSED') {
                if (hoursElapsed > 336) { // 14 Days = 336 hours
                    slaHtml = `<br><span class="badge bg-danger bg-opacity-10 text-danger border border-danger mt-1" style="font-size: 0.6rem;"><span class="material-symbols-outlined align-middle" style="font-size: 10px;">error</span> OVERDUE (14+ DAYS)</span>`;
                } else {
                    const daysLeft = Math.max(0, 14 - Math.floor(hoursElapsed / 24));
                    slaHtml = `<br><span class="badge bg-success bg-opacity-10 text-success border border-success mt-1" style="font-size: 0.6rem;">${daysLeft} DAYS LEFT</span>`;
                }
            } else {
                slaHtml = `<br><span class="badge bg-success bg-opacity-10 text-success border border-success mt-1" style="font-size: 0.6rem;">RESOLVED</span>`;
            }

            row.innerHTML = `
                <td class="px-4 py-3">
                    <div class="fw-bold text-dark small">${c.alert_ref.replace('ALT', 'CASE')}</div>
                    ${slaHtml}
                </td>
                <td class="py-3 text-muted small">${entityName}</td>
                <td class="py-3 text-muted small">${c.rule_triggered}</td>
                <td class="py-3"><span class="badge ${statusBadge}">${c.status}</span></td>
                <td class="py-3 text-muted small fst-italic">"${noteSnippet}"</td>
                <td class="px-4 py-3 text-end">
                    <button class="btn btn-sm btn-light border text-primary fw-bold uppercase" onclick="loadCustomerProfile('${c.customer_id}', '${c.status}')" style="font-size: 0.7rem;">View Dossier</button>
                </td>
            `;
            tbody.appendChild(row);
        });
    } catch (err) {
        console.error("Error loading cases:", err);
    }
}

export function applyCaseFilters() {
    const filter = document.getElementById('filter-case-status').value;
    const rows = document.querySelectorAll('#case-management-body tr');
    
    rows.forEach(row => {
        if (row.cells.length <= 1) return; // Skip "Loading" messages
        const statusCell = row.cells[3].innerText.toUpperCase();
        
        if (filter === 'ALL' || statusCell.includes(filter)) {
            row.style.display = '';
        } else {
            row.style.display = 'none';
        }
    });
}