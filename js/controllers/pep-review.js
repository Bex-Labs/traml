const outcomes = {
    DECLARED_NO_EXPOSURE: 'Declared no exposure',
    POSSIBLE_EXPOSURE: 'Possible exposure',
    INFORMATION_NEEDED: 'More information needed',
    FALSE_POSITIVE: 'False positive',
    CONFIRMED_EXPOSURE: 'Confirmed exposure',
    EDD_REVIEWED: 'EDD reviewed'
};
const eddStages = {
    NOT_STARTED: 'EDD not started',
    DRAFT: 'EDD draft',
    SUBMITTED: 'Awaiting Head review',
    RETURNED: 'Returned to officer',
    APPROVED: 'EDD approved'
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
    CUSTOMER_DECLARATION: 'Customer declaration',
    OFFICER_RESEARCH: 'Officer research',
    POSSIBLE_MATCH: 'Officeholder name match',
    ROSTER_RESCREEN: 'Roster rescreening match',
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

export function mountPepReview(client) {
    const directory = document.getElementById('kyc-directory-content');
    const workspace = document.getElementById('kyc-pep-workspace');
    const title = document.getElementById('pep-review-title');
    const status = document.getElementById('pep-review-status');
    const results = document.getElementById('pep-review-content');
    let generation = 0;
    let saving = false;
    let queueStatus = 'ALL';
    let monitoringDue = 'ALL';
    let origin;

    function close({restoreFocus = false} = {}) {
        if (saving) return false;
        if (workspace.classList.contains('d-none')) return true;
        generation++;
        workspace.classList.add('d-none');
        directory.classList.remove('d-none');
        results.replaceChildren();
        status.textContent = '';
        if (restoreFocus && origin?.isConnected) origin.focus();
        origin = null;
        return true;
    }

    window.addEventListener('beforeunload', event => {
        if (saving) event.preventDefault();
    });

    async function read(name, args, heading, render) {
        if (saving) return;
        const ticket = ++generation;
        title.textContent = heading;
        results.replaceChildren();
        const detail = ['coreaml_pep_subjects','coreaml_pep_edd_workspace'].includes(name) || args.p_edd;
        results.className = detail ? 'card border-0 shadow-sm p-3 p-md-4' : '';
        status.textContent = 'Loading…';
        if (workspace.classList.contains('d-none')) origin = document.activeElement;
        workspace.classList.remove('d-none');
        directory.classList.add('d-none');
        title.focus();
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

    function renderWorklist({columns, rows, empty, offset, load, otherLabel, openOther}) {
        const toolbar = element('div', '', 'd-flex gap-2 flex-wrap mb-3');
        toolbar.append(button(otherLabel, openOther), button('Refresh', () => void load(offset)));
        const card = element('div', '', 'card border-0 shadow-sm overflow-hidden');
        const wrap = element('div', '', 'table-responsive');
        const table = element('table', '', 'table table-hover align-middle mb-0');
        const head = element('thead', '', 'table-light text-muted small text-uppercase');
        const header = element('tr');
        for (const label of [...columns, 'Action']) {
            const cell = element('th', label, 'py-3 px-3 fw-semibold text-nowrap');
            cell.scope = 'col';
            header.append(cell);
        }
        head.append(header);
        const body = element('tbody', '', 'bg-white');
        for (const {values, action} of rows.slice(0, 25)) {
            const row = element('tr');
            values.forEach((value, index) => row.append(element('td', value,
                index === 0 ? 'small fw-semibold px-3 py-3' : 'small px-3 py-3')));
            const cell = element('td', '', 'px-3 py-3 text-nowrap');
            cell.append(action);
            row.append(cell);
            body.append(row);
        }
        if (!rows.length) {
            const row = element('tr');
            const cell = element('td', empty, 'small text-muted text-center py-4');
            cell.colSpan = columns.length + 1;
            row.append(cell);
            body.append(row);
        }
        table.append(head, body);
        wrap.append(table);
        const footer = element('div', '', 'card-footer bg-white d-flex justify-content-end gap-2');
        const previous = button('Previous', () => void load(Math.max(0, offset - 25)));
        const next = button('Next', () => void load(offset + 25));
        previous.disabled = offset === 0;
        next.disabled = rows.length <= 25;
        footer.append(previous, next);
        card.append(wrap, footer);
        results.append(toolbar, card);
    }

    function renderQueueTabs(label, choices, selected, select) {
        const tabs = element('div', '', 'btn-group shadow-sm flex-wrap mb-3');
        tabs.setAttribute('aria-label', label);
        for (const [value, text] of choices) {
            const tab = button(text, () => select(value));
            const active = selected === value;
            tab.className = `btn btn-sm fw-bold px-3 ${active ? 'btn-dark active' : 'btn-outline-dark'}`;
            tab.setAttribute('aria-pressed', String(active));
            tabs.append(tab);
        }
        results.append(tabs);
    }

    function showQueue(offset = 0) {
        return read('coreaml_pep_queue', {p_offset: offset, p_status: queueStatus}, 'PEP review queue', rows => {
            renderQueueTabs('PEP review status', [
                ['ALL','All'], ['POSSIBLE_EXPOSURE','Possible exposure'], ['CONFIRMED_EXPOSURE','Confirmed exposure'],
                ['EDD_REVIEWED','EDD reviewed'], ['NEEDS_MY_ACTION','Needs my action']
            ], queueStatus, value => {
                queueStatus = value;
                void showQueue();
            });
            renderWorklist({
                columns: ['Person', 'Customer', 'Status', 'EDD stage', 'Referral', 'Assignment'],
                rows: rows.map(row => ({
                    values: [row.subject_name, row.customer_name, outcomes[row.status], eddStages[row.edd_stage], triggers[row.reason],
                        row.reason ? assignment(row) : '—'].map(value => value ?? '—'),
                    action: row.edd_stage
                        ? button('Open EDD', () => void showEdd(row.id, row.customer_id, row.subject_id))
                        : button('Open review', () => void showCustomer(row.customer_id, row.subject_id))
                })),
                empty: queueStatus === 'NEEDS_MY_ACTION' ? 'No EDD cases need your action on this page.' : 'No PEP reviews on this page.',
                offset, load: showQueue,
                otherLabel: 'Enhanced monitoring', openOther: () => void showMonitoring()
            });
        });
    }

    function showCustomer(customer, focusSubject) {
        return read('coreaml_pep_subjects', {p_customer: customer}, 'PEP review', ({role, subjects}) => {
            const navigation = element('div', '', 'mb-3');
            navigation.append(button('PEP review queue', () => void showQueue()));
            results.append(navigation);
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
                    if (selected) renderEditor(editor, subject, customer, selected, role);
                };
                subject.addEventListener('change', update);
                results.append(field('Person', subject), editor);
                update();
            }
        });
    }

    function renderEditor(editor, selector, customer, subject, role, editing = false) {
        const prior = subject.latest;
        editor.append(element('p', prior ? outcomes[prior.status] : 'No review recorded', 'fw-semibold mb-1'));
        if (prior && !subject.referrals?.some(referral => referral.event_id === prior.id)) {
            editor.append(element('p', prior.evidence, 'small text-break'));
        }
        const onboarding = subject.onboarding;
        const evidenceGroups = [
            onboarding,
            subject.rescreening?.length && { reason: 'ROSTER_RESCREEN', source_evidence: subject.rescreening }
        ].filter(Boolean);
        for (const group of evidenceGroups) {
            const details = element('section', '', 'border rounded p-3 mb-3');
            details.append(element('h3', triggers[group.reason], 'fs-6'));
            if (group === onboarding) details.append(element('p', assignment(group), 'small mb-2'));
            for (const match of group.source_evidence) {
                const item = element('div', '', 'border-top py-2 small');
                const reference = element('div', match.source_reference, 'text-break');
                const executive = /^https:\/\/statehouse\.gov\.ng\/(?:the-cabinet|people)\/#:~:text=[A-Za-z0-9%._~!-]+$/.test(match.source_reference);
                const governor = /^https:\/\/www\.ngf\.org\.ng\/index\.php\/the-ngf\/governors\/[1-9]\d{0,11}-[a-z]+(?:-[a-z]+)*-state-governor$/.test(match.source_reference);
                if (governor || executive || /^https:\/\/www\.nass\.gov\.ng\/mps\/single\/[1-9]\d{0,11}$/.test(match.source_reference)) {
                    const label = governor ? 'Nigeria Governors’ Forum profile'
                        : executive ? 'State House source' : 'National Assembly profile';
                    const link = element('a', label);
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
        renderManualReferrals(editor, subject.referrals ?? [], prior?.id);
        if (prior?.status === 'EDD_REVIEWED') {
            const actions = element('div', '', 'd-flex gap-2 flex-wrap');
            actions.append(button('Relationship decision and monitoring', () => void showPlan(prior.id, customer, subject.subject_id)),
                button('View EDD evidence', () => void showEdd(prior.id, customer, subject.subject_id)));
            editor.append(actions);
            return;
        }
        if (prior?.status === 'CONFIRMED_EXPOSURE') {
            editor.append(button('Open EDD workspace', () => void showEdd(prior.id, customer, subject.subject_id)));
            return;
        }
        const actions = element('div', '', 'd-flex gap-2 flex-wrap mb-3');
        if (!editing && prior?.status !== 'POSSIBLE_EXPOSURE' && role === 'compliance_officer') {
            actions.append(button('Refer possible exposure', () => showManualReferral(customer, subject)));
        }
        if (prior && !editing) {
            actions.append(button('Record follow-up decision', () => {
                editor.replaceChildren();
                renderEditor(editor, selector, customer, subject, role, true);
                editor.querySelector('form select')?.focus();
            }));
            editor.append(actions);
            return;
        }
        if (actions.childElementCount) editor.append(actions);
        const form = element('form');
        const optionsForReview = Object.keys(outcomes).filter(key =>
            key !== 'EDD_REVIEWED' && (key !== 'POSSIBLE_EXPOSURE' || (prior?.status !== 'POSSIBLE_EXPOSURE' && role !== 'compliance_officer')));
        const outcome = options(outcomes, optionsForReview, 'Select an outcome');
        const exposure = options(exposures, Object.keys(exposures), 'Select a category where applicable');
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
            if (saving || !form.isConnected) return;
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
                if (saved) form.remove();
                else for (const input of [save, outcome, exposure, evidence]) input.disabled = false;
                selector.disabled = false;
            }
            if (saved) {
                await showCustomer(customer, subject.subject_id);
                status.textContent = status.textContent ? `PEP decision saved. ${status.textContent}` : 'PEP decision saved.';
            }
        });
    }

    function renderManualReferrals(parent, referrals = [], activeId) {
        for (const referral of referrals) {
            const details = element('details', '', 'border rounded p-3 mb-3');
            details.open = referral.event_id === activeId;
            details.append(element('summary', `${triggers[referral.source]} · ${referral.pep_name}`, 'fw-semibold'));
            const facts = element('dl', '', 'row small mb-0 mt-3');
            for (const [label,value] of [['Exposure category', exposures[referral.category]],
                ['Public role', referral.public_role], ['Connection', referral.relationship],
                ['Evidence reference', referral.evidence_reference], ['Referral reason', referral.reason],
                ['Recorded', new Date(referral.created_at).toLocaleString()]]) {
                facts.append(element('dt', label, 'col-sm-4'), element('dd', value, 'col-sm-8 text-break'));
            }
            details.append(facts);
            parent.append(details);
        }
    }

    function showManualReferral(customer, subject) {
        title.textContent = 'Refer possible PEP exposure';
        title.focus();
        status.textContent = '';
        results.replaceChildren();
        const nav = element('div', '', 'mb-3');
        nav.append(button('Back to PEP review', () => void showCustomer(customer, subject.subject_id)));
        results.append(nav, element('h5', subject.full_name, 'fs-6 mb-3'));
        const form = element('form');
        const source = options(triggers, ['CUSTOMER_DECLARATION','OFFICER_RESEARCH'], 'Select a source');
        const category = options(exposures, Object.keys(exposures), 'Select an exposure category');
        source.required = category.required = true;
        form.append(field('Referral source', source), field('Exposure category', category));
        const values = {};
        for (const [key,label,min,max] of [
            ['p_pep_name','Name of the politically exposed person',2,200],
            ['p_public_role','Public role and institution',3,250],
            ['p_relationship','Connection to the customer or linked person',3,500],
            ['p_reference','Evidence reference or source URL',3,500],
            ['p_reason','Reason for referral',10,1000]
        ]) {
            const input = key === 'p_reason' ? monitoringNotes() : element('input', '', 'form-control');
            input.required = true;
            input.minLength = min;
            input.maxLength = max;
            values[key] = input;
            form.append(field(label, input));
        }
        let pending;
        submitMonitoring(form, 'Save referral', 'coreaml_refer_pep', () => {
            const args = {
                p_customer: customer, p_subject: subject.subject_id, p_prior: subject.latest?.id ?? null,
                p_category: category.value, p_source: source.value,
                ...Object.fromEntries(Object.entries(values).map(([key,input]) => [key,input.value.trim()]))
            };
            const signature = JSON.stringify(args);
            if (pending?.signature !== signature) pending = {signature,id:crypto.randomUUID()};
            return {...args,p_request:pending.id};
        }, () => showCustomer(customer, subject.subject_id), 'Referral saved as possible exposure.');
    }

    function showEdd(exposure, customer, subject) {
        return read('coreaml_pep_edd_workspace', {p_exposure: exposure}, 'Enhanced due diligence', data => {
            const latest = data.events[0];
            const nav = element('div', '', 'mb-3');
            nav.append(button('Back to PEP review', () => void showCustomer(customer, subject)));
            if (latest?.action === 'APPROVED') {
                nav.append(button('Relationship decision and monitoring', () => void showPlan(latest.id, customer, subject)));
            }
            results.append(nav, element('h5', data.subject, 'mb-1'),
                element('p', [data.customer.name, exposures[data.category], data.customer.kyc_status].filter(Boolean).join(' · '), 'text-muted small'),
                element('h6', 'Confirmed exposure'), element('p', data.finding, 'text-break'));
            renderManualReferrals(results, data.referrals ?? []);
            const linked = data.people.filter(person => person.person_role !== 'CUSTOMER');
            if (linked.length) {
                results.append(element('h6', 'Linked people'));
                const list = element('ul', '', 'small');
                for (const person of linked) list.append(element('li', `${person.full_name} · ${roles[person.person_role] ?? person.person_role}`));
                results.append(list);
            }
            const evidence = latest?.evidence ?? data.customer;
            const documents = element('div', '', 'd-flex gap-2 flex-wrap mb-3');
            for (const [label, path] of [['Identity document', evidence.identity_path], ['Address document', evidence.address_path]]) {
                if (!path) continue;
                const control = button(`Load ${label.toLowerCase()}`, async () => {
                    control.disabled = true;
                    try {
                        const {data: signed, error} = await client.storage.from('kyc-vault').createSignedUrl(path, 120);
                        if (error || !signed?.signedUrl) throw Error(`${label} could not be opened.`);
                        const link = element('a', `Open ${label.toLowerCase()}`, 'btn btn-sm btn-outline-secondary');
                        link.href = signed.signedUrl;
                        link.target = '_blank';
                        link.rel = 'noopener noreferrer';
                        link.addEventListener('click', () => link.replaceWith(control));
                        control.replaceWith(link);
                    } catch (error) {
                        status.textContent = error.message;
                    } finally {
                        control.disabled = false;
                    }
                });
                documents.append(control);
            }
            if (documents.childElementCount) results.append(documents);

            const checks = latest?.evidence?.checks ?? {};
            const labels = {
                identity: 'Identity checks',
                connection: 'Public role and connection to customer',
                funds: 'Source of funds',
                wealth: 'Source of wealth',
                expected_activity: 'Expected account activity',
                references: 'Evidence references',
                open_items: 'Outstanding items'
            };
            const editable = data.role === 'compliance_officer' && !data.superseded && (!latest || ['DRAFT', 'RETURNED'].includes(latest.action))
                && (!data.preparer || data.preparer === data.staff_id);
            const awaitingOfficer = latest?.action === 'SUBMITTED' && !data.preparer;
            const canReview = !data.superseded && latest?.action === 'SUBMITTED'
                && data.role === 'head_of_compliance'
                && (awaitingOfficer || ![data.preparer, data.actor_id].includes(data.staff_id));
            const stateLabels = eddStages;
            if (latest) results.append(element('h6', stateLabels[latest.action]));
            if (data.preparer) results.append(element('p', `Preparing officer: ${data.preparer_label ?? data.preparer}`, 'small'));
            if (awaitingOfficer && !data.superseded) {
                results.append(element('p', 'Return this submission so a compliance officer can take over and submit it.', 'small text-muted'));
            } else if (!latest && !editable && !data.superseded) {
                results.append(element('p', 'Awaiting preparation by a compliance officer.', 'small text-muted'));
            }
            const history = element('details', '', 'my-3');
            history.append(element('summary', 'EDD history'));
            for (const entry of data.events) {
                history.append(element('p', [stateLabels[entry.action], new Date(entry.created_at).toLocaleString(), entry.note].filter(Boolean).join(' · '),
                    'small text-break mt-2'));
            }
            if (data.events.length) results.append(history);
            if (latest?.action === 'RETURNED') results.append(element('p', latest.note, 'alert alert-warning'));
            if (!editable && latest) {
                const summary = element('dl', '', 'row mb-3');
                for (const [key, label] of Object.entries(labels)) {
                    summary.append(element('dt', label, 'col-sm-4'), element('dd', checks[key] || '—', 'col-sm-8 text-break'));
                }
                results.append(summary);
            }
            const assignments = data.reassignments ?? [];
            if (assignments.length) {
                const history = element('details', '', 'my-3');
                history.append(element('summary', 'Reassignment history'));
                for (const entry of assignments) {
                    const row = element('div', '', 'border-bottom py-2 small');
                    row.append(element('p', `${entry.previous_officer ?? 'Unassigned'} → ${entry.officer}`, 'fw-semibold mb-1'),
                        element('p', `${entry.actor} · ${new Date(entry.created_at).toLocaleString()}`, 'text-muted mb-1'),
                        element('p', entry.reason, 'text-break mb-1'));
                    history.append(row);
                }
                results.append(history);
            }
            if (data.role === 'head_of_compliance' && !data.superseded
                && ['DRAFT','RETURNED'].includes(latest?.action)) {
                showReassignment(data, latest, customer, subject);
                return;
            }
            if (!editable && !canReview) return;

            const form = element('form');
            const inputs = {};
            let action;
            let note;
            if (editable) {
                for (const [key, label] of Object.entries(labels)) {
                    const input = monitoringNotes();
                    input.required = false;
                    input.maxLength = 2000;
                    input.value = checks[key] ?? '';
                    inputs[key] = input;
                    form.append(field(label, input));
                }
                form.append(element('p', 'For submission, complete each field. Explain any inapplicable check and record any outstanding items.', 'small text-muted'));
                action = options({DRAFT:'Save draft',SUBMITTED:'Submit to Head of Compliance'}, ['DRAFT','SUBMITTED'], 'Select an action');
            } else {
                note = monitoringNotes();
                form.append(field('Review rationale or information needed', note));
                action = options({RETURNED:awaitingOfficer ? 'Return to compliance officer' : 'Return for more information',
                    APPROVED:'Approve EDD'}, awaitingOfficer ? ['RETURNED'] : ['RETURNED','APPROVED'], 'Select a decision');
            }
            action.required = true;
            form.append(field(editable ? 'EDD action' : 'Head of Compliance decision', action));
            let pending;
            submitMonitoring(form, editable ? 'Save EDD' : 'Save EDD decision', 'coreaml_record_pep_edd', () => {
                const args = {
                    p_exposure: data.id, p_prior: latest?.id ?? null, p_action: action.value,
                    p_evidence: editable ? Object.fromEntries(Object.entries(inputs).map(([key,input]) => [key,input.value.trim()])) : null,
                    p_note: note?.value.trim() ?? null
                };
                const signature = JSON.stringify(args);
                if (pending?.signature !== signature) pending = {signature,id:crypto.randomUUID()};
                return {...args,p_request:pending.id};
            }, () => showEdd(data.id, customer, subject), 'EDD update saved.');
        });
    }

    function showReassignment(data, latest, customer, subject) {
        if (!data.officers?.length) {
            results.append(element('p', 'No other active compliance officer is available.', 'small text-muted'));
            return;
        }
        const control = button('Reassign EDD', () => {
            control.remove();
            const form = element('form');
            const officer = options(Object.fromEntries(data.officers.map(person => [person.id,person.label])),
                data.officers.map(person => person.id), 'Select an officer');
            officer.required = true;
            const reason = monitoringNotes();
            form.append(field('New preparing officer', officer), field('Reassignment reason', reason));
            let pending;
            submitMonitoring(form, 'Save reassignment', 'coreaml_reassign_pep_edd', () => {
                const args = {
                    p_exposure: data.id, p_edd_event: latest.id, p_prior_assignment: data.reassignments[0]?.id ?? null,
                    p_officer: officer.value, p_reason: reason.value.trim()
                };
                const signature = JSON.stringify(args);
                if (pending?.signature !== signature) pending = {signature,id:crypto.randomUUID()};
                return {...args,p_request:pending.id};
            }, () => showEdd(data.id, customer, subject), 'EDD reassigned.');
        });
        results.append(control);
    }

    function showMonitoring(offset = 0) {
        return read('coreaml_pep_monitoring', {p_edd: null, p_offset: offset, p_due_filter: monitoringDue},
            'Enhanced monitoring', ({items, today}) => {
            renderQueueTabs('Monitoring due date', [
                ['ALL','All'], ['OVERDUE','Overdue'], ['DUE_TODAY','Due today'], ['UPCOMING','Upcoming']
            ], monitoringDue, value => {
                monitoringDue = value;
                void showMonitoring();
            });
            renderWorklist({
                columns: ['Person', 'Owner', 'Next review', 'Status'],
                rows: items.map(plan => ({
                    values: [plan.subject_name, plan.owner_name ?? plan.owner_id, plan.due,
                        plan.due < today ? 'Overdue' : plan.due === today ? 'Due today' : 'Upcoming'],
                    action: button('Open monitoring plan', () => void showPlan(plan.edd_id))
                })),
                empty: 'No monitoring plans match this filter.', offset, load: showMonitoring,
                otherLabel: 'PEP review queue', openOther: () => void showQueue()
            });
        });
    }

    function showPlan(edd, customer, subject, recording = false) {
        return read('coreaml_pep_monitoring', {p_edd: edd}, 'PEP relationship decision', ({items, owners, role, staff_id, today}) => {
            const navigation = element('div', '', 'd-flex gap-2 flex-wrap mb-3');
            navigation.append(button('Enhanced monitoring', () => void showMonitoring()));
            if (customer) navigation.append(button('Back to PEP review', () => void showCustomer(customer, subject)));
            results.append(navigation);
            const plan = items[0];
            if (plan) {
                results.append(element('h3', plan.subject_name, 'fs-6 mt-3'),
                    element('p', plan.approved ? 'Relationship approved' : 'Relationship declined', 'fw-semibold'),
                    element('p', plan.rationale, 'text-break'));
                if (!plan.owner_id) return;
                results.append(element('p', `Owner: ${plan.owner_name ?? plan.owner_id} · Next review: ${plan.due}`),
                    element('p', plan.checks, 'text-break'));
                if (plan.expected_activity) {
                    results.append(element('h3', 'Expected account activity from EDD', 'fs-6'),
                        element('p', plan.expected_activity, 'text-break'));
                }
                results.append(element('h3', 'Review history', 'fs-6'));
                if (!plan.history?.length) results.append(element('p', 'No monitoring reviews recorded.'));
                for (const review of plan.history ?? []) {
                    const row = element('article', '', 'border-bottom mb-3');
                    row.append(element('p', `${new Date(review.reviewed_at).toLocaleString()} · ${review.reviewer} · Next review: ${review.next_due}`, 'small'),
                        element('p', review.findings, 'text-break'));
                    if (review.ledger_evidence) {
                        const ledger = review.ledger_evidence;
                        row.append(element('p', `Review period (WAT): ${ledger.from} to ${ledger.to}`, 'small'));
                        const links = element('ul', '', 'small');
                        for (const tx of ledger.transactions) {
                            links.append(element('li', [tx.reference,tx.direction,tx.amount,tx.currency].filter(Boolean).join(' · ')));
                        }
                        row.append(ledger.transactions.length ? links : element('p', 'No transactions linked.', 'small text-muted'));
                    }
                    results.append(row);
                }
                if (role !== 'head_of_compliance' && staff_id !== plan.owner_id) return;
                if (!recording) {
                    results.append(button(plan.last_review ? 'Start next monitoring review' : 'Start monitoring review',
                        () => void showPlan(edd, customer, subject, true)));
                    return;
                }
                const findings = monitoringNotes();
                const tomorrow = new Date(`${today}T00:00:00Z`);
                tomorrow.setUTCDate(tomorrow.getUTCDate() + 1);
                const due = monitoringDate(tomorrow.toISOString().slice(0, 10));
                const form = element('form');
                const ledger = monitoringLedger(edd, today);
                form.append(ledger.panel, field('Monitoring findings', findings), field('Next review date', due));
                let pending;
                submitMonitoring(form, 'Save monitoring review', 'coreaml_complete_pep_monitoring_with_evidence', () => {
                    if (!ledger.validate()) return null;
                    const evidence = ledger.payload();
                    const signature = JSON.stringify([findings.value.trim(), due.value, evidence]);
                    if (pending?.signature !== signature) pending = {signature, id: crypto.randomUUID()};
                    return {
                        p_request: pending.id, p_edd: edd, p_prior: plan.last_review,
                        p_findings: findings.value.trim(), p_due: due.value, ...evidence
                    };
                }, () => showPlan(edd, customer, subject), 'Monitoring review saved.');
                return;
            }
            if (role !== 'head_of_compliance' || !customer) {
                results.append(element('p', 'Awaiting the Head of Compliance’s relationship decision.', 'mt-3'));
                return;
            }

            const form = element('form', '', 'mt-3');
            const decision = options({PLAN: 'Approve with enhanced monitoring', APPROVE: 'Approve without enhanced monitoring',
                DECLINE: 'Decline relationship'}, ['PLAN', 'APPROVE', 'DECLINE'], 'Select the bank’s decision');
            decision.required = true;
            const rationale = monitoringNotes();
            const details = element('fieldset');
            const owner = options(Object.fromEntries(owners.map(person => [person.id, person.label])),
                owners.map(person => person.id), 'Select a compliance team member');
            owner.required = true;
            const checks = monitoringNotes();
            const due = monitoringDate(today);
            details.append(field('Monitoring owner', owner), field('Activity to monitor', checks), field('First review date', due));
            function update() {
                details.hidden = decision.value !== 'PLAN';
                details.disabled = details.hidden;
            }
            decision.addEventListener('change', update);
            update();
            form.append(field('Relationship decision', decision), field('Decision rationale and evidence reference', rationale), details);
            submitMonitoring(form, 'Save relationship decision', 'coreaml_decide_pep_relationship', () => ({
                p_edd: edd, p_approved: decision.value !== 'DECLINE', p_rationale: rationale.value.trim(),
                p_owner: details.hidden ? null : owner.value, p_checks: details.hidden ? null : checks.value.trim(),
                p_due: details.hidden ? null : due.value
            }), () => showPlan(edd, customer, subject), 'Relationship decision saved.');
        });
    }

    function monitoringLedger(edd, today) {
        const panel = element('fieldset', '', 'border rounded p-3 mb-3');
        panel.append(element('legend', 'Ledger activity', 'fs-6 fw-semibold float-none w-auto'));
        const from = monitoringDate('');
        const to = monitoringDate('');
        from.max = to.max = today;
        const dates = element('div', '', 'd-flex gap-3 flex-wrap');
        dates.append(field('Period from (WAT)', from), field('Period to (WAT)', to));
        const report = element('p', '', 'small text-muted mt-2 mb-2');
        report.setAttribute('role', 'status');
        const rows = element('div');
        const selected = new Set();
        let ticket = 0;
        let loaded = false;
        const fetchPage = async offset => {
            if (saving || !from.reportValidity() || !to.reportValidity()) return;
            const current = ++ticket;
            rows.replaceChildren();
            report.textContent = 'Loading transactions…';
            try {
                const {data, error} = await client.rpc('coreaml_pep_monitoring_ledger',
                    {p_edd: edd, p_from: from.value, p_to: to.value, p_offset: offset});
                if (current !== ticket || !panel.isConnected) return;
                if (error) throw error;
                loaded = true;
                from.setCustomValidity('');
                report.textContent = data.length ? `${selected.size} selected` : 'No ledger transactions in this period.';
                for (const tx of data.slice(0, 25)) {
                    const checkbox = element('input', '', 'form-check-input me-2');
                    checkbox.type = 'checkbox';
                    checkbox.checked = selected.has(tx.id);
                    checkbox.addEventListener('change', () => {
                        if (checkbox.checked && selected.size >= 25) {
                            checkbox.checked = false;
                            report.textContent = 'Select up to 25 transactions.';
                            return;
                        }
                        if (checkbox.checked) selected.add(tx.id);
                        else selected.delete(tx.id);
                        report.textContent = `${selected.size} selected`;
                    });
                    const when = new Intl.DateTimeFormat('en-NG', {dateStyle:'medium',timeStyle:'short',
                        timeZone:'Africa/Lagos'}).format(new Date(tx.posted_at));
                    const label = element('label', '', 'd-flex align-items-start border-bottom py-2 small');
                    label.append(checkbox, element('span', [tx.reference, when, tx.direction, tx.amount, tx.currency].filter(Boolean).join(' · ')));
                    rows.append(label);
                }
                const pages = element('div', '', 'd-flex gap-2 mt-2');
                if (offset) pages.append(button('Previous transactions', () => void fetchPage(offset - 25)));
                if (data.length > 25) pages.append(button('Next transactions', () => void fetchPage(offset + 25)));
                rows.append(pages);
            } catch (error) {
                if (current === ticket && panel.isConnected) report.textContent = error.message || 'Could not load ledger activity.';
            }
        };
        for (const input of [from,to]) input.addEventListener('input', () => {
            ticket++;
            loaded = false;
            selected.clear();
            rows.replaceChildren();
            from.setCustomValidity('');
            report.textContent = '';
        });
        panel.append(dates, button('Load transactions', () => void fetchPage(0)), report, rows);
        return {
            panel,
            validate() {
                from.setCustomValidity(loaded ? '' : 'Load transactions for this review period first.');
                const valid = from.reportValidity();
                from.setCustomValidity('');
                return valid;
            },
            payload: () => ({p_from: from.value,p_to: to.value,p_transactions: [...selected].sort()})
        };
    }

    function monitoringNotes() {
        const input = element('textarea', '', 'form-control');
        input.required = true;
        input.minLength = 10;
        input.maxLength = 1000;
        input.rows = 3;
        return input;
    }

    function monitoringDate(minimum) {
        const input = element('input', '', 'form-control');
        input.type = 'date';
        input.min = minimum;
        input.required = true;
        return input;
    }

    function submitMonitoring(form, label, rpc, args, reload, confirmation) {
        const save = element('button', label, 'btn btn-sm btn-primary');
        save.type = 'submit';
        form.append(save);
        results.append(form);
        form.addEventListener('submit', async event => {
            event.preventDefault();
            if (saving || !form.isConnected) return;
            const payload = args();
            if (!payload) return;
            const controls = [...form.querySelectorAll('button,input,select,textarea')];
            saving = true;
            controls.forEach(control => { control.disabled = true; });
            status.textContent = 'Saving…';
            let saved = false;
            try {
                const {data, error} = await client.rpc(rpc, payload);
                if (error) throw error;
                if (data !== (payload.p_request ?? payload.p_edd)) throw Error('Save could not be confirmed. Retry.');
                saved = true;
            } catch (error) {
                status.textContent = error.message || 'Unable to save monitoring details.';
                return;
            } finally {
                saving = false;
                if (saved) form.remove();
                else controls.forEach(control => { control.disabled = false; });
            }
            await reload();
            status.textContent = status.textContent ? `${confirmation} ${status.textContent}` : confirmation;
        });
    }

    document.getElementById('kyc-pep-queue').addEventListener('click', () => void showQueue());
    document.getElementById('kyc-pep-monitoring').addEventListener('click', () => void showMonitoring());
    document.getElementById('kyc-pep-back').addEventListener('click', () => close({restoreFocus: true}));
    window.addEventListener('coreaml:pep-review', event => void showCustomer(event.detail));
    return {close};
}
