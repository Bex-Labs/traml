import { supabase } from './config.js';

let currentAuditData = []; 
const isBranchLedger = window.location.pathname.includes('compliance-audit');

// --- Enterprise Toast Controller ---
function showToast(message, isError = false) {
    const toastEl = document.getElementById('dynamicToast');
    const toastBody = document.getElementById('dynamicToastBody');
    toastEl.classList.remove('bg-success', 'bg-danger');
    toastEl.classList.add(isError ? 'bg-danger' : 'bg-success');
    toastBody.innerHTML = `<strong>${isError ? 'Error:' : 'Success:'}</strong> ${message}`;
    new bootstrap.Toast(toastEl, { delay: 3500 }).show();
}

async function initializeAuditPortal() {
    try {
        const { data: { session }, error: authError } = await supabase.auth.getSession();
        if (authError || !session) throw new Error("Unauthorized");

        const jwtPayload = JSON.parse(atob(session.access_token.split('.')[1]));
        const userRole = jwtPayload.app_metadata?.role;

        if (userRole !== 'it_admin' && userRole !== 'head_of_compliance') {
            console.error("SECURITY VIOLATION: Unauthorized access.");
            window.location.replace('dashboard.html');
            return;
        }

        document.getElementById('audit-body').style.display = 'block';

        document.getElementById('filter-start').addEventListener('change', loadLogs);
        document.getElementById('filter-end').addEventListener('change', loadLogs);
        document.getElementById('filter-type').addEventListener('change', loadLogs);

        document.getElementById('export-csv-btn').addEventListener('click', exportToCSV);
        document.getElementById('export-pdf-btn').addEventListener('click', exportToPDF);

        loadLogs();

    } catch (error) {
        window.location.replace('index.html');
    }
}

async function loadLogs() {
    const tbody = document.getElementById('audit-table-body');
    tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-muted"><span class="spinner-border spinner-border-sm me-2" role="status"></span> Compiling unified ledger...</td></tr>`;

    const typeFilter = document.getElementById('filter-type')?.value;
    const startFilter = document.getElementById('filter-start')?.value;
    const endFilter = document.getElementById('filter-end')?.value;

    try {
        let combinedLogs = [];

        // Dual-Fetch Engine for Head of Compliance
        if (isBranchLedger) {
            let sysQuery = supabase.from('system_events').select('*');
            let authQuery = supabase.from('audit_logs').select('*');

            if (typeFilter && typeFilter !== 'all' && typeFilter !== 'All Events') {
                sysQuery = sysQuery.ilike('event_type', `%${typeFilter}%`);
                authQuery = authQuery.ilike('event_type', `%${typeFilter}%`);
            }
            if (startFilter) {
                sysQuery = sysQuery.gte('created_at', `${startFilter}T00:00:00Z`);
                authQuery = authQuery.gte('created_at', `${startFilter}T00:00:00Z`);
            }
            if (endFilter) {
                sysQuery = sysQuery.lte('created_at', `${endFilter}T23:59:59.999Z`);
                authQuery = authQuery.lte('created_at', `${endFilter}T23:59:59.999Z`);
            }

            // Run both queries at the exact same time for speed
            const [sysRes, authRes] = await Promise.all([sysQuery, authQuery]);

            if (sysRes.error) throw sysRes.error;
            if (authRes.error) throw authRes.error;

            // Tag where they came from and merge
            const sysData = sysRes.data.map(d => ({ ...d, _source: 'system_events' }));
            const authData = authRes.data.map(d => ({ ...d, _source: 'audit_logs' }));
            
            combinedLogs = [...sysData, ...authData];

        } else {
            // IT Admin only needs the global audit_logs table
            let query = supabase.from('audit_logs').select('*');

            if (typeFilter && typeFilter !== 'all' && typeFilter !== 'All Events') {
                query = query.ilike('event_type', `%${typeFilter}%`);
            }
            if (startFilter) {
                query = query.gte('created_at', `${startFilter}T00:00:00Z`);
            }
            if (endFilter) {
                query = query.lte('created_at', `${endFilter}T23:59:59.999Z`);
            }

            const { data, error } = await query;
            if (error) throw error;
            combinedLogs = data.map(d => ({ ...d, _source: 'audit_logs' }));
        }

        // Sort the merged list chronologically (newest first)
        combinedLogs.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
        currentAuditData = combinedLogs; 

        if (combinedLogs.length === 0) {
            tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-muted">No audit events found for this criteria.</td></tr>`;
            return;
        }

        // Render the combined data
        tbody.innerHTML = combinedLogs.map(log => {
            const date = new Date(log.created_at).toLocaleString();
            
            let actor = 'SYSTEM';
            let target = 'N/A';
            let payload = log.details || log.metadata || {};
            let messageHtml = '';

            // Handle the different column structures cleanly
            if (log._source === 'system_events') {
                if (payload.assigned_to) actor = payload.assigned_to.substring(0, 8) + '...';
                if (payload.alert_id) target = payload.alert_id;
                if (payload.target) target = payload.target.substring(0, 8) + '...';
                if (log.message) messageHtml = `<div class="text-dark fw-bold mb-1" style="font-size: 0.85rem;">${log.message}</div>`;
            } else {
                if (log.actor_id) actor = log.actor_id.substring(0, 8) + '...';
                if (log.target_id) target = log.target_id.substring(0, 8) + '...';
            }
            
            let formattedDetails = '<span class="text-muted fst-italic">No additional metadata</span>';
            if (Object.keys(payload).length > 0) {
                formattedDetails = Object.entries(payload).map(([key, value]) => {
                    const cleanKey = key.replace(/_/g, ' ').toUpperCase();
                    return `<div class="mb-1" style="font-size: 0.8rem;"><span class="fw-bold text-secondary">${cleanKey}:</span> <span class="text-muted">${value}</span></div>`;
                }).join('');
            }
            
            return `
            <tr>
                <td class="ps-4 py-3 fw-medium text-dark font-monospace" style="font-size: 0.85rem;">${date}</td>
                <td class="py-3">
                    <span class="badge bg-secondary bg-opacity-10 text-dark border fw-semibold uppercase px-2 py-1">
                        ${log.event_type.replace(/_/g, ' ')}
                    </span>
                </td>
                <td class="py-3 font-monospace text-muted" style="font-size: 0.85rem;">${actor}</td>
                <td class="py-3 font-monospace text-muted" style="font-size: 0.85rem;">${target}</td>
                <td class="pe-4 py-3">
                    ${messageHtml}
                    ${formattedDetails}
                </td>
            </tr>
        `}).join('');

    } catch (error) {
        console.error("Ledger Compilation Error:", error);
        showToast("Failed to compile unified ledger.", true);
        tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-danger">Database error. Check console.</td></tr>`;
    }
}

// --- EXPORT ENGINES ---
function exportToCSV() {
    if (currentAuditData.length === 0) return showToast("No data to export.", true);

    const headers = ['Timestamp', 'Event Type', 'Actor ID', 'Target ID', 'Details'];
    const csvRows = [headers.join(',')];

    currentAuditData.forEach(log => {
        const payload = log.details || log.metadata || {};
        const actor = log.actor_id || payload.assigned_to || 'SYSTEM';
        const target = log.target_id || payload.alert_id || payload.target || 'N/A';
        
        const row = [
            `"${new Date(log.created_at).toISOString()}"`,
            `"${log.event_type}"`,
            `"${actor}"`,
            `"${target}"`,
            `"${JSON.stringify(payload).replace(/"/g, '""')}"` 
        ];
        csvRows.push(row.join(','));
    });

    const blob = new Blob([csvRows.join('\n')], { type: 'text/csv' });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.setAttribute('hidden', '');
    a.setAttribute('href', url);
    a.setAttribute('download', `BexAML_Audit_Log_${new Date().toISOString().split('T')[0]}.csv`);
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    
    showToast("CSV Export generated successfully.");
}

function exportToPDF() {
    if (currentAuditData.length === 0) return showToast("No data to export.", true);

    const { jsPDF } = window.jspdf;
    const doc = new jsPDF();

    doc.setFontSize(16);
    doc.setTextColor(14, 165, 233); 
    doc.text("BexAML", 14, 15);
    
    doc.setFontSize(10);
    doc.setTextColor(100);
    doc.text(`Official Audit Ledger | Exported: ${new Date().toLocaleString()}`, 14, 22);

    const tableHeaders = [['Timestamp', 'Event Type', 'Actor/Target', 'Details']];
    const tableData = currentAuditData.map(log => {
        const payload = log.details || log.metadata || {};
        const actor = log.actor_id ? log.actor_id.substring(0, 8) : (payload.assigned_to ? payload.assigned_to.substring(0, 8) : 'SYS');
        const target = log.target_id ? log.target_id.substring(0, 8) : (payload.alert_id ? payload.alert_id : (payload.target ? payload.target.substring(0, 8) : 'N/A'));
        
        return [
            new Date(log.created_at).toLocaleString(),
            log.event_type.replace(/_/g, ' ').toUpperCase(),
            `Actor: ${actor}\nTarget: ${target}`,
            (log.message ? log.message + '\n' : '') + JSON.stringify(payload)
        ]
    });

    doc.autoTable({
        head: tableHeaders,
        body: tableData,
        startY: 30,
        styles: { fontSize: 8, font: 'helvetica' },
        headStyles: { fillColor: [14, 165, 233] },
        columnStyles: { 3: { cellWidth: 70 } } 
    });

    doc.save(`BexAML_Audit_Log_${new Date().toISOString().split('T')[0]}.pdf`);
    showToast("PDF Export generated successfully.");
}

initializeAuditPortal();