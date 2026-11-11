import { createOversightService } from '../services/oversight.service.js';

const roleLabels = {
    compliance_officer: 'Compliance Officer',
    bank_manager: 'Bank Manager',
    head_of_compliance: 'Head of Compliance',
};

export function createTeamManagement(client, getCaseWorkload) {
    const byId = id => document.getElementById(id);
    const table = byId('team-directory-body');
    const status = byId('team-status');
    const inviteForm = byId('invite-form');
    const inviteStatus = byId('team-invite-status');
    const retry = byId('team-retry');
    const previous = byId('team-prev');
    const next = byId('team-next');
    let service, tenantId, storageKey, pending;
    let busy = false;
    let offset = 0;
    let generation = 0;

    function controls() {
        for (const control of [...inviteForm.elements, byId('team-open-invite'), ...table.querySelectorAll('button')]) {
            control.disabled = busy || Boolean(pending) || !service;
        }
        retry.hidden = !pending;
        retry.disabled = busy || !service;
    }

    function authorize(context) {
        if (context.role !== 'head_of_compliance' || !context.tenantId) return;
        tenantId = context.tenantId;
        storageKey = 'coreaml-admin-request:' + context.user.id + ':' + tenantId;
        try {
            pending = JSON.parse(sessionStorage.getItem(storageKey) || 'null');
            service = createOversightService(client, context);
        } catch {
            status.textContent = 'Team requests are unavailable because saved request data could not be read.';
        }
        controls();
    }

    function cell(row, value, classes = 'py-3 small') {
        const node = row.insertCell();
        node.className = classes;
        node.textContent = value;
        return node;
    }

    function render(rows, workload) {
        table.replaceChildren();
        for (const member of rows) {
            const row = table.insertRow();
            cell(row, member.full_name || 'Name unavailable', 'px-4 py-3 small fw-semibold');
            cell(row, roleLabels[member.role] || member.role);
            const active = workload?.filter(group => group.owner === member.id && group.status === 'INVESTIGATING').length;
            const closed = workload?.filter(group => group.owner === member.id && group.status === 'CLOSED').length;
            cell(row, workload ? active + ' active · ' + closed + ' closed' : 'Unavailable');
            cell(row, member.is_active ? 'Active' : 'Inactive');
            const action = cell(row, '', 'px-4 py-3 text-end');
            if (member.can_manage) {
                const button = document.createElement('button');
                button.type = 'button';
                button.className = 'btn btn-sm btn-outline-secondary';
                button.textContent = member.is_active ? 'Deactivate' : 'Restore';
                button.addEventListener('click', () => {
                    if (window.confirm(button.textContent + ' access for ' + (member.full_name || 'this officer') + '?')) {
                        void submit(member.is_active ? 'DEACTIVATE' : 'RESTORE', { target_id: member.id });
                    }
                });
                action.append(button);
            }
        }
        controls();
    }

    async function load(page = 0) {
        if (!service) return;
        const ticket = ++generation;
        const search = byId('team-search').value.trim();
        status.textContent = 'Loading your team…';
        previous.disabled = next.disabled = true;
        table.replaceChildren();
        try {
            const [directory, workload] = await Promise.all([
                service.load('admin', 'USERS', page, search),
                Promise.resolve().then(getCaseWorkload).catch(() => null),
            ]);
            if (ticket !== generation) return;
            offset = page;
            render(directory.rows, workload);
            previous.disabled = offset === 0;
            next.disabled = offset + directory.rows.length >= Number(directory.total);
            status.textContent = pending ? 'A team request is awaiting confirmation. Retry the saved request.'
                : directory.rows.length ? (offset + 1) + '–' + (offset + directory.rows.length) + ' of ' + directory.total + ' team members'
                : 'No team members match your search.';
        } catch (error) {
            if (ticket === generation) status.textContent = error.message;
        }
    }

    async function submit(action, payload) {
        if (!service || busy || (pending && action)) return;
        if (!pending) {
            const request = { action, payload, requestId: crypto.randomUUID() };
            try {
                sessionStorage.setItem(storageKey, JSON.stringify(request));
                pending = request;
            } catch {
                inviteStatus.textContent = status.textContent = 'Could not save a reference for this request. Try again.';
                return;
            }
        }
        busy = true;
        controls();
        inviteStatus.textContent = status.textContent = 'Waiting for confirmation…';
        try {
            const receipt = await service.act(pending);
            sessionStorage.removeItem(storageKey);
            pending = null;
            if (receipt.action === 'INVITE') {
                inviteForm.reset();
                window.bootstrap.Modal.getInstance(byId('inviteModal'))?.hide();
            }
            await load(offset);
            inviteStatus.textContent = '';
            status.textContent = (receipt.action === 'INVITE' ? 'Invitation confirmed. ' : 'Access update confirmed. ') +
                'Request ' + receipt.request_id;
        } catch (error) {
            if (error.definitive) {
                sessionStorage.removeItem(storageKey);
                pending = null;
            }
            status.textContent = error.message;
            inviteStatus.textContent = pending ? error.message + ' Close this dialog and select Retry saved request.' : error.message;
        } finally {
            busy = false;
            controls();
        }
    }

    inviteForm.addEventListener('submit', event => {
        event.preventDefault();
        const role = byId('role-select').value;
        if (!Object.hasOwn(roleLabels, role)) return;
        void submit('INVITE', { email: byId('invite-email').value.trim().toLowerCase(), role, tenant_id: tenantId });
    });
    byId('team-search-form').addEventListener('submit', event => {
        event.preventDefault();
        void load();
    });
    byId('team-refresh').addEventListener('click', () => void load(offset));
    previous.addEventListener('click', () => void load(Math.max(0, offset - 25)));
    next.addEventListener('click', () => void load(offset + 25));
    retry.addEventListener('click', () => { if (pending) void submit(); });
    return { authorize, load };
}
