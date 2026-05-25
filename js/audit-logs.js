import { supabase } from './config.js';

let currentAuditData = []; // Store the data globally so we can export it without re-fetching

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
        // 1. Verify Authentication & Routing
        const { data: { session }, error: authError } = await supabase.auth.getSession();
        if (authError || !session) throw new Error("Unauthorized");

        const jwtPayload = JSON.parse(atob(session.access_token.split('.')[1]));
        const userRole = jwtPayload.app_metadata?.role;

        // Only Admins and Compliance Heads can view this portal
        if (userRole !== 'it_admin' && userRole !== 'head_of_compliance') {
            console.error("SECURITY VIOLATION: Unauthorized access attempt to Audit Logs.");
            window.location.replace('dashboard.html');
            return;
        }

        // 2. Clear to proceed: Unhide the page
        document.getElementById('audit-body').style.display = 'block';

        // 3. Attach Event Listeners to Filters
        document.getElementById('filter-start').addEventListener('change', loadLogs);
        document.getElementById('filter-end').addEventListener('change', loadLogs);
        document.getElementById('filter-type').addEventListener('change', loadLogs);

        // 4. Attach Export Listeners
        document.getElementById('export-csv-btn').addEventListener('click', exportToCSV);
        document.getElementById('export-pdf-btn').addEventListener('click', exportToPDF);

        // 5. Fetch the initial data payload
        loadLogs();

    } catch (error) {
        window.location.replace('login.html');
    }
}

async function loadLogs() {
    const tbody = document.getElementById('audit-table-body');
    tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-muted"><span class="spinner-border spinner-border-sm me-2" role="status"></span> Querying immutable ledger...</td></tr>`;

    // 1. Grab Filter Values
    const startDate = document.getElementById('filter-start').value;
    const endDate = document.getElementById('filter-end').value;
    const eventType = document.getElementById('filter-type').value;

    // 2. Build the Supabase Query
    let query = supabase.from('audit_logs').select('*').order('created_at', { ascending: false });

    // 1. Grab current values from the UI filters
        const typeFilter = document.getElementById('filter-type')?.value;
        const startFilter = document.getElementById('filter-start')?.value;
        const endFilter = document.getElementById('filter-end')?.value;

        // 2. Dynamically modify the Supabase query if filters are active
        if (typeFilter && typeFilter !== 'all' && typeFilter !== 'All Events') {
            // Note: Adjust the value matching depending on how your HTML options are set up
            query = query.ilike('event_type', `%${typeFilter}%`); 
        }
        
        if (startFilter) {
            // Append midnight to catch the very start of the day
            query = query.gte('created_at', `${startFilter}T00:00:00Z`);
        }
        
        if (endFilter) {
            // Append 11:59 PM to catch the very end of the day
            query = query.lte('created_at', `${endFilter}T23:59:59.999Z`);
        }

    // 3. Execute Query
    const { data: logs, error } = await query;

    if (error) {
        console.error("Supabase Database Error:", error);
        showToast("Failed to retrieve audit ledger.", true);
        tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-danger">Database error. Check console.</td></tr>`;
        return;
    }

    currentAuditData = logs; // Save for exports

    if (logs.length === 0) {
        tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-muted">No audit events found for this criteria.</td></tr>`;
        return;
    }

    // 4. Render the Data Grid
    // 4. Render the Data Grid
    tbody.innerHTML = logs.map(log => {
        const date = new Date(log.created_at).toLocaleString();
        
        // Unpack the JSON details into a clean, stacked UI
        let formattedDetails = '<span class="text-muted fst-italic">No details provided</span>';
        if (log.details) {
            formattedDetails = Object.entries(log.details).map(([key, value]) => {
                const cleanKey = key.replace(/_/g, ' ').toUpperCase();
                return `<div class="mb-1" style="font-size: 0.8rem;"><span class="fw-bold text-dark">${cleanKey}:</span> <span class="text-muted">${value}</span></div>`;
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
            <td class="py-3 font-monospace text-muted" style="font-size: 0.85rem;">${log.actor_id ? log.actor_id.substring(0, 8) + '...' : 'SYSTEM'}</td>
            <td class="py-3 font-monospace text-muted" style="font-size: 0.85rem;">${log.target_id ? log.target_id.substring(0, 8) + '...' : 'N/A'}</td>
            <td class="pe-4 py-3">
                ${formattedDetails}
            </td>
        </tr>
    `}).join('');
}

// --- EXPORT ENGINES ---

function exportToCSV() {
    if (currentAuditData.length === 0) return showToast("No data to export.", true);

    const headers = ['Timestamp', 'Event Type', 'Actor ID', 'Target ID', 'Details'];
    const csvRows = [headers.join(',')];

    currentAuditData.forEach(log => {
        const row = [
            `"${new Date(log.created_at).toISOString()}"`,
            `"${log.event_type}"`,
            `"${log.actor_id || 'SYSTEM'}"`,
            `"${log.target_id || 'N/A'}"`,
            `"${log.details ? JSON.stringify(log.details).replace(/"/g, '""') : ''}"` // Escape quotes for CSV
        ];
        csvRows.push(row.join(','));
    });

    const blob = new Blob([csvRows.join('\n')], { type: 'text/csv' });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.setAttribute('hidden', '');
    a.setAttribute('href', url);
    a.setAttribute('download', `Sentinel_Audit_Log_${new Date().toISOString().split('T')[0]}.csv`);
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    
    showToast("CSV Export generated successfully.");
}

function exportToPDF() {
    if (currentAuditData.length === 0) return showToast("No data to export.", true);

    // Initialize jsPDF (The library we included in the HTML head)
    const { jsPDF } = window.jspdf;
    const doc = new jsPDF();

    // Enterprise Header
    doc.setFontSize(16);
    doc.setTextColor(14, 165, 233); // Sentinel Primary Blue
    doc.text("Sentinel AML", 14, 15);
    
    doc.setFontSize(10);
    doc.setTextColor(100);
    doc.text(`Official Audit Ledger | Exported: ${new Date().toLocaleString()}`, 14, 22);

    // Format data for the AutoTable plugin
    const tableHeaders = [['Timestamp', 'Event Type', 'Actor ID', 'Details']];
    const tableData = currentAuditData.map(log => [
        new Date(log.created_at).toLocaleString(),
        log.event_type.replace(/_/g, ' ').toUpperCase(),
        log.actor_id ? log.actor_id.substring(0, 8) + '...' : 'SYSTEM',
        log.details ? JSON.stringify(log.details) : 'N/A'
    ]);

    // Generate Table
    doc.autoTable({
        head: tableHeaders,
        body: tableData,
        startY: 30,
        styles: { fontSize: 8, font: 'helvetica' },
        headStyles: { fillColor: [14, 165, 233] },
        columnStyles: { 3: { cellWidth: 60 } } // Give the details column more room to wrap text
    });

    // Download
    doc.save(`Sentinel_Audit_Log_${new Date().toISOString().split('T')[0]}.pdf`);
    showToast("PDF Export generated successfully.");
}

// Attach real-time listeners to the UI filters
document.getElementById('filter-type')?.addEventListener('change', loadLogs);
document.getElementById('filter-start')?.addEventListener('change', loadLogs);
document.getElementById('filter-end')?.addEventListener('change', loadLogs);

// Start the sequence
initializeAuditPortal();