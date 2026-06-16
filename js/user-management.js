import { supabase } from './config.js';

let globalAccessData = [];

// --- Enterprise Toast Controller ---
function showToast(message, isError = false) {
    const toastEl = document.getElementById('dynamicToast');
    const toastBody = document.getElementById('dynamicToastBody');
    toastEl.classList.remove('bg-success', 'bg-danger');
    toastEl.classList.add(isError ? 'bg-danger' : 'bg-success');
    toastBody.innerHTML = `<strong>${isError ? 'Error:' : 'Success:'}</strong> ${message}`;
    new bootstrap.Toast(toastEl, { delay: 3500 }).show();
}

async function initializeAdminPortal() {
    try {
        // 1. Verify Authentication
        const { data: { session }, error: authError } = await supabase.auth.getSession();
        if (authError || !session) throw new Error("Unauthorized");

        // 2. THE ROUTE GUARD: Read the role directly from the secure JWT
        const jwtPayload = JSON.parse(atob(session.access_token.split('.')[1]));
        const userRole = jwtPayload.app_metadata?.role;

        if (userRole !== 'it_admin') {
            console.error("SECURITY VIOLATION: Non-admin attempted to access IT portal.");
            window.location.replace('dashboard.html');
            return;
        }

        // 3. Clear to proceed: Unhide the page
        document.getElementById('admin-body').style.display = 'block';

        // 4. Fetch the global user list
        loadUsers();

        // 5. Populate the invite dropdown with custom roles
        loadDynamicRoles();

        // 6. Fetch deployed banks for the invite modal
        populateTenantDropdown();

    } catch (error) {
        window.location.replace('index.html');
    }
}

async function loadUsers() {
    const tbody = document.getElementById('user-table-body');
    
    // Because we set up the RLS policy earlier, this will pull ALL users for IT Admins
    const { data: users, error } = await supabase
        .from('user_profiles')
        .select('*')
        .order('created_at', { ascending: false });

    if (error) {
        console.error("Supabase Database Error:", error); // <-- Add this line
        showToast("Failed to load user database.", true);
        tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-danger">Error loading users.</td></tr>`;
        return;
    }

    globalAccessData = users;

    if (users.length === 0) {
        tbody.innerHTML = `<tr><td colspan="5" class="text-center py-4 text-muted">No users found.</td></tr>`;
        return;
    }

    // Render the grid
    tbody.innerHTML = users.map(user => {
        // Format the audit timestamps and actors
        const assignedDate = new Date(user.created_at).toLocaleDateString();
        // Graceful fallback if the specific 'assigned_by' UUID isn't in your schema yet
        const assignedBy = user.assigned_by ? `${user.assigned_by.substring(0,8)}...` : 'SYSTEM ADMIN';

        return `
        <tr>
            <td class="ps-4 fw-medium text-dark font-monospace small">${user.id.substring(0, 8)}...</td>
            <td>
                <span class="badge ${getRoleBadgeColor(user.role)} bg-opacity-10 text-dark border fw-semibold uppercase px-2 py-1">
                    ${user.role.replace(/_/g, ' ')}
                </span>
            </td>
            <td class="font-monospace small text-muted">${user.tenant_id ? user.tenant_id.substring(0, 8) + '...' : 'GLOBAL'}</td>
            <td class="small text-muted">${assignedDate}</td>
            <td class="font-monospace small text-muted">${assignedBy}</td>
            <td>
                <span class="badge ${user.is_active ? 'bg-success' : 'bg-danger'} rounded-pill">
                    ${user.is_active ? 'Active' : 'Deactivated'}
                </span>
            </td>
            <td class="pe-4 text-end">
                ${user.is_active 
                    ? `<button class="btn btn-sm btn-outline-danger fw-medium me-1" onclick="openConfirmModal('deactivate', '${user.id}')">Ban</button>`
                    : `<button class="btn btn-sm btn-outline-success fw-medium me-1" onclick="openConfirmModal('restore', '${user.id}')">Restore</button>`
                }
                <button class="btn btn-sm btn-outline-primary fw-medium" onclick="triggerAction('reset', '${user.id}')">
                    Reset Pwd
                </button>
            </td>
        </tr>
    `}).join('');
}

// UI Helper for Badge Colors
function getRoleBadgeColor(role) {
    const colors = {
        'it_admin': 'bg-dark text-white',
        'head_of_compliance': 'bg-primary',
        'compliance_officer': 'bg-info',
        'bank_manager': 'bg-warning'
    };
    return colors[role] || 'bg-secondary';
}

// --- Modal State Variables ---
let pendingAction = null;
let pendingUserId = null;

// 1. Open the UI Modal instead of a native alert
window.openConfirmModal = (action, userId) => {
    pendingAction = action;
    pendingUserId = userId;

    const icon = document.getElementById('action-icon');
    const title = document.getElementById('action-title');
    const message = document.getElementById('action-message');
    const confirmBtn = document.getElementById('action-confirm-btn');

    if (action === 'deactivate') {
        icon.innerText = 'gavel';
        icon.className = 'material-symbols-outlined fs-1 text-danger mb-2';
        title.innerText = 'Suspend User';
        message.innerText = 'This user will be immediately locked out of the system.';
        confirmBtn.className = 'btn btn-danger btn-sm fw-medium w-50';
        confirmBtn.innerText = 'Suspend';
    } else if (action === 'restore') {
        icon.innerText = 'health_and_safety';
        icon.className = 'material-symbols-outlined fs-1 text-success mb-2';
        title.innerText = 'Restore User';
        message.innerText = 'This user will regain full access to the platform.';
        confirmBtn.className = 'btn btn-success btn-sm fw-medium w-50';
        confirmBtn.innerText = 'Restore';
    }

    const modal = new bootstrap.Modal(document.getElementById('actionConfirmModal'));
    modal.show();
};

// 2. Execute when the modal 'Confirm' button is clicked
document.getElementById('action-confirm-btn')?.addEventListener('click', async () => {
    const modalEl = document.getElementById('actionConfirmModal');
    const modalInstance = bootstrap.Modal.getInstance(modalEl);
    modalInstance.hide();
    
    await window.triggerAction(pendingAction, pendingUserId);
});

// 3. The Actual Backend Call
window.triggerAction = async (action, userId) => {
    try {
        const { data, error } = await supabase.functions.invoke('admin-actions', {
            body: { action: action, targetUserId: userId }
        });

        if (error) throw new Error(error.message);
        if (data && data.error) throw new Error(data.error);

        if (action === 'deactivate') {
            showToast('User has been successfully suspended.', false);
            loadUsers();
        } else if (action === 'restore') {
            showToast('User access has been restored.', false);
            loadUsers();
        } else if (action === 'reset') {
            showToast('Password reset email dispatched.', false);
        }

    } catch (err) {
        console.error(err);
        showToast(err.message, true);
    }
};

// --- IT Admin: Provision New User Logic ---
document.getElementById('admin-invite-form')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const submitBtn = document.getElementById('admin-invite-submit-btn');
    submitBtn.innerHTML = 'Provisioning...';
    submitBtn.disabled = true;

    const email = document.getElementById('admin-invite-email').value;
    const role = document.getElementById('admin-invite-role').value;
    const tenantId = document.getElementById('admin-invite-tenant').value.trim(); // Ensure no accidental spaces

    try {
        // Call our existing invite Edge Function
        const { data, error } = await supabase.functions.invoke('invite-user', {
            body: { email: email, role: role, tenantId: tenantId }
        });

        if (error) throw new Error(error.message);
        if (data && data.error) throw new Error(data.error);

        // Success Handling
        showToast(`Secure invite dispatched to ${email}`, false);
        
        // Close the modal cleanly
        const modalEl = document.getElementById('adminInviteModal');
        const modalInstance = bootstrap.Modal.getInstance(modalEl);
        modalInstance.hide();
        
        // Clear the form
        document.getElementById('admin-invite-form').reset();
        
        // Reload the grid so the new user instantly appears!
        loadUsers();

    } catch (err) {
        console.error(err);
        showToast(err.message, true);
    } finally {
        submitBtn.innerHTML = 'Dispatch Secure Invite';
        submitBtn.disabled = false;
    }
});

// --- Dynamic Role Dropdown Auto-Populator ---
async function loadDynamicRoles() {
    const roleSelect = document.getElementById('admin-invite-role');
    if (!roleSelect) return;

    // Supabase RLS automatically filters this list based on who is logged in!
    const { data: customRoles, error } = await supabase
        .from('custom_roles')
        .select('role_name');

    if (error) {
        console.error("Failed to load custom roles:", error);
        return;
    }

    if (customRoles && customRoles.length > 0) {
        // Create a distinct category header for the custom roles
        const optGroup = document.createElement('optgroup');
        optGroup.label = "Custom Enterprise Roles";
        
        customRoles.forEach(role => {
            const option = document.createElement('option');
            option.value = role.role_name; // Send the exact name to the backend
            option.innerText = role.role_name;
            optGroup.appendChild(option);
        });
        
        roleSelect.appendChild(optGroup);
    }
}

// --- Populate the Tenant Dropdown ---
async function populateTenantDropdown() {
    const select = document.getElementById('admin-invite-tenant');
    if (!select) return;

    const { data: banks, error } = await supabase.from('banks').select('id, name').order('name');
    
    if (error || !banks || banks.length === 0) {
        select.innerHTML = '<option value="">No institutions deployed yet</option>';
        return;
    }

    select.innerHTML = '<option value="" disabled selected>Select an institution...</option>' + 
        banks.map(b => `<option value="${b.id}">${b.name} (${b.id})</option>`).join('');
}

// Start the sequence
initializeAdminPortal();

// --- TAML-73: Export Engine (Audit Requirement) ---
document.getElementById('export-csv-btn')?.addEventListener('click', () => {
    if (globalAccessData.length === 0) return showToast("No matrix data available to export.", true);

    // Added new audit headers
    const headers = ['Profile ID', 'Identity (Email)', 'Platform Role', 'Assigned Node (Tenant ID)', 'Assigned On', 'Assigned By', 'Account Status'];
    const csvRows = [headers.join(',')];

    globalAccessData.forEach(user => {
        const row = [
            `"${user.id}"`,
            `"${user.email}"`,
            `"${user.role.toUpperCase()}"`,
            `"${user.tenant_id || 'GLOBAL_ACCESS'}"`,
            `"${new Date(user.created_at).toISOString()}"`,
            `"${user.assigned_by || 'SYSTEM_ADMIN'}"`,
            `"${user.is_active ? 'ACTIVE' : 'SUSPENDED'}"`
        ];
        csvRows.push(row.join(','));
    });

    const blob = new Blob([csvRows.join('\n')], { type: 'text/csv' });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.setAttribute('hidden', '');
    a.setAttribute('href', url);
    a.setAttribute('download', `BexAML_Access_Review_${new Date().toISOString().split('T')[0]}.csv`);
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    
    showToast("Access Review Log compiled and downloaded securely.");
});