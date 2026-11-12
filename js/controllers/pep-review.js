const outcomes = {
    DECLARED_NO_EXPOSURE: 'Declared no exposure',
    POSSIBLE_EXPOSURE: 'Possible exposure',
    INFORMATION_NEEDED: 'More information needed',
    FALSE_POSITIVE: 'False positive',
    CONFIRMED_EXPOSURE: 'Confirmed exposure',
    EDD_REVIEWED: 'EDD reviewed'
};
const exposures = {
    DOMESTIC: 'Domestic', FOREIGN: 'Foreign',
    INTERNATIONAL_ORGANISATION: 'International organisation',
    FAMILY: 'Family member', CLOSE_ASSOCIATE: 'Close associate', UNKNOWN: 'Unknown'
};
const roles = {
    CUSTOMER: 'Customer', DIRECTOR: 'Director',
    BENEFICIAL_OWNER: 'Beneficial owner', SIGNATORY: 'Authorised signatory'
};

const triggers = {
    DECLARATION: 'Onboarding declaration',
    POSSIBLE_MATCH: 'Officeholder name match',
    SCREENING_INCOMPLETE: 'Incomplete screening'
};

function assignment(task) {
    return task.assigned_to_me ? 'Assigned to you' : task.assigned ? 'Assigned to a compliance officer' : 'Unassigned';
}

function element(tag, label = '', classes = '') {
    const node = document.createElement(tag);
    node.textContent = label;
    node.className = classes;
    return node;
}

function button(label, handler) {
    const node = element('button', label, 'btn btn-sm btn-outline-secondary');
    node.type = 'button';
    node.addEventListener('click', handler);
    return node;
}

function field(label, input) {
    const node = element('label', label, 'form-label d-block');
    node.append(input);
    return node;
}

function options(values, keys, placeholder) {
    const select = element('select', '', 'form-select form-select-sm');
    for (const [key, name] of [['', placeholder], ...keys.map(key => [key, values[key]])]) {
        const option = element('option', name);
        option.value = key;
        select.append(option);
    }
    return select;
}

export function attachPepReview(client, Modal) {
    const modal = element('div', '', 'modal fade');
    modal.tabIndex = -1;
    modal.setAttribute('aria-labelledby', 'pep-review-title');
    const dialog = element('div', '', 'modal-dialog modal-lg modal-dialog-scrollable');
    const content = element('div', '', 'modal-content');
    const header = element('div', '', 'modal-header');
    const title = element('h2', 'PEP review', 'modal-title fs-5');
    title.id = 'pep-review-title';
    const close = element('button', '', 'btn-close');
    close.type = 'button';
    close.setAttribute('aria-label', 'Close');
    close.dataset.bsDismiss = 'modal';
    header.append(title, close);
    const body = element('div', '', 'modal-body');
    const status = element('p', '', 'small text-muted mb-2');
    status.setAttribute('role', 'status');
    const results = element('div');
    body.append(status, results);
    content.append(header, body);
    dialog.append(content);
    modal.append(dialog);
    document.body.append(modal);
    const instance = Modal.getOrCreateInstance(modal);
    let generation = 0;
    let saving = false;
    modal.addEventListener('hide.bs.modal', event => {
        if (saving) event.preventDefault();
        else ++generation;
    });

    async function read(name, args, heading, render) {
        if (saving) return;
        const ticket = ++generation;
        title.textContent = heading;
        results.replaceChildren();
        status.textContent = 'Loading…';
        instance.show();
        try {
            const { data, error } = await client.rpc(name, args);
            if (ticket !== generation) return;
            if (error) throw error;
            status.textContent = '';
            render(data);
        } catch (error) {
            if (ticket === generation) status.textContent = error.message || 'Unable to load PEP review.';
        }
    }

    function showQueue(offset = 0) {
        return read('coreaml_pep_queue', {p_offset: offset}, 'PEP review queue', rows => {
            if (!rows.length) results.append(element('p', 'No PEP reviews on this page.'));
            for (const row of rows.slice(0, 25)) {
                const item = element('article', '', 'border-bottom py-3');
                item.append(element('h3', row.subject_name, 'fs-6 mb-1'),
                    element('p', [row.customer_name, outcomes[row.status], triggers[row.reason], row.reason && assignment(row)].filter(Boolean).join(' · '), 'small mb-2'),
                    button('Open review', () => void showCustomer(row.customer_id, row.subject_id)));
                results.append(item);
            }
            const pages = element('div', '', 'd-flex gap-2 mt-3');
            if (offset) pages.append(button('Previous', () => void showQueue(Math.max(0, offset - 25))));
            if (rows.length > 25) pages.append(button('Next', () => void showQueue(offset + 25)));
            results.append(pages);
        });
    }

    function showCustomer(customer, focusSubject) {
        return read('coreaml_pep_subjects', {p_customer: customer}, 'PEP review', ({role, subjects}) => {
            results.append(button('PEP review queue', () => void showQueue()));
            if (!subjects.length) {
                results.append(element('p', 'Incomplete coverage. No people are recorded for this customer.', 'mt-3'));
            } else {
                if (subjects.every(s => s.person_role !== 'CUSTOMER' && s.person_role !== 'BENEFICIAL_OWNER')) {
                    results.append(element('p', 'Incomplete coverage. No beneficial owner is recorded.', 'mt-3 mb-2'));
                }
                const subject = options(Object.fromEntries(subjects.map(s => [
                    s.subject_id, `${s.full_name} · ${roles[s.person_role] || s.person_role}`
                ])), subjects.map(s => s.subject_id), 'Select a person');
                subject.value = focusSubject || subjects[0].subject_id;
                const editor = element('div', '', 'mt-3');
                const update = () => {
                    const selected = subjects.find(s => s.subject_id === subject.value);
                    editor.replaceChildren();
                    if (selected) renderEditor(editor, subject, role, customer, selected);
                };
                subject.addEventListener('change', update);
                results.append(field('Person', subject), editor);
                update();
            }
        });
    }

    function renderEditor(editor, selector, role, customer, subject) {
        const prior = subject.latest;
        const final = ['CONFIRMED_EXPOSURE', 'EDD_REVIEWED'].includes(prior?.status);
        editor.append(element('p', prior ? outcomes[prior.status] : 'No review recorded', 'fw-semibold mb-1'));
        if (prior) editor.append(element('p', prior.evidence, 'small text-break'));
        const onboarding = subject.onboarding;
        if (onboarding) {
            const details = element('section', '', 'border rounded p-3 mb-3');
            details.append(element('h3', triggers[onboarding.reason], 'fs-6'),
                element('p', assignment(onboarding), 'small mb-2'));
            for (const match of onboarding.source_evidence) {
                const item = element('div', '', 'border-top py-2 small');
                const reference = element('div', match.source_reference, 'text-break');
                if (/^https:\/\/www\.nass\.gov\.ng\/mps\/single\/[1-9]\d{0,11}$/.test(match.source_reference)) {
                    const link = element('a', 'National Assembly profile');
                    link.href = match.source_reference;
                    link.target = '_blank';
                    link.rel = 'noopener noreferrer';
                    reference.replaceChildren(link);
                }
                item.append(element('strong', match.full_name),
                    element('div', `${match.public_role} · ${match.jurisdiction}`),
                    element('div', match.source_name), reference,
                    element('div', `Source checked ${new Date(match.checked_at).toLocaleString()}`));
                details.append(item);
            }
            editor.append(details);
        }
        if (final && (role !== 'head_of_compliance' || prior.status === 'EDD_REVIEWED')) return;
        const form = element('form');
        const outcome = options(outcomes, final ? ['EDD_REVIEWED'] :
            Object.keys(outcomes).filter(key => key !== 'EDD_REVIEWED'), 'Select an outcome');
        const exposure = options(exposures, Object.keys(exposures), 'Select a category where applicable');
        if (final) {
            outcome.value = 'EDD_REVIEWED';
            exposure.value = prior.exposure;
        }
        const evidence = element('textarea', '', 'form-control');
        evidence.required = true;
        evidence.minLength = 10;
        evidence.maxLength = 1000;
        evidence.rows = 3;
        evidence.placeholder = 'Evidence reference and reason. Omit BVNs and other identity numbers.';
        const save = element('button', 'Save PEP review', 'btn btn-sm btn-primary');
        save.type = 'submit';
        outcome.required = true;
        form.append(field('Outcome', outcome), field('Exposure category', exposure),
            field('Declaration or evidence reference and review reason', evidence), save);
        editor.append(form);
        let pending;
        form.addEventListener('submit', async event => {
            event.preventDefault();
            if (saving) return;
            const args = {
                p_customer: customer, p_subject: subject.subject_id, p_prior: prior?.id ?? null,
                p_status: outcome.value, p_exposure: exposure.value || null, p_evidence: evidence.value.trim()
            };
            const signature = JSON.stringify(args);
            if (pending?.signature !== signature) pending = {signature, id: crypto.randomUUID()};
            saving = true;
            for (const input of [save, outcome, exposure, evidence, selector]) input.disabled = true;
            status.textContent = 'Saving…';
            let saved = false;
            try {
                const { data, error } = await client.rpc('coreaml_record_pep_review', {p_request: pending.id, ...args});
                if (error) throw error;
                if (data !== pending.id) throw Error('Save could not be confirmed. Retry the same review.');
                saved = true;
            } catch (error) {
                status.textContent = error.message || 'Unable to confirm this review.';
            } finally {
                saving = false;
                for (const input of [save, outcome, exposure, evidence, selector]) input.disabled = false;
            }
            if (saved) await showCustomer(customer, subject.subject_id);
        });
    }

    document.getElementById('kyc-pep-queue').addEventListener('click', () => void showQueue());
    window.addEventListener('coreaml:pep-review', event => void showCustomer(event.detail));
}
