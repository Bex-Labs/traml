const sourceLabels = {
    UN: 'UN consolidated list',
    OFAC_SDN: 'OFAC SDN list',
    OFAC_NON_SDN: 'OFAC non-SDN list',
    NIGERIA: 'Nigeria Sanctions Committee',
};

function officialSource(hit) {
    if (hit.source === 'NIGERIA' && /^\/(Ind|Ent)SancDetails\?id=\d+$/.test(hit.reference)) {
        return 'https://nigsac.gov.ng' + hit.reference;
    }
    if (hit.source === 'UN') return 'https://main.un.org/securitycouncil/en/content/un-sc-consolidated-list';
    if (hit.source === 'OFAC_SDN' || hit.source === 'OFAC_NON_SDN') {
        return 'https://ofac.treasury.gov/sanctions-list-service';
    }
    return 'https://nigsac.gov.ng/IndSancList';
}

const element = (tag, text, classes) => {
    const node = document.createElement(tag);
    if (text) node.textContent = text;
    if (classes) node.className = classes;
    return node;
};

export function attachKycSanctionsPilot(client) {
    const localHosts = ['127.0.0.1', 'localhost'];
    if (!client.supabaseUrl) return;
    const backend = new URL(client.supabaseUrl);
    const hosted = location.protocol === 'https:' && backend.protocol === 'https:' &&
        !localHosts.includes(location.hostname) && !localHosts.includes(backend.hostname);
    const local = localHosts.includes(location.hostname) && localHosts.includes(backend.hostname);
    if (!hosted && !local) return;

    const modal = document.getElementById('kycVerificationModal');
    const enable = () => enableReferrals(client, local ? modal : undefined);
    const applicant = document.getElementById('kyc-customer-id');
    const anchor = modal?.querySelector('label[for="kyc-screening-reference"]');
    if (!anchor || !applicant) return hosted ? enable : undefined;

    const panel = element('section', '', 'border rounded p-3 mb-3');
    panel.setAttribute('aria-label', 'Sanctions screening');
    const heading = element('h6', hosted ? 'Sanctions screening' : 'Sanctions screening · Local pilot', 'small fw-bold');
    const description = element('p', hosted
        ? 'Compare the recorded applicant name with the current watchlist. Use the results for manual review and complete PEP review separately.'
        : 'Compare this applicant’s recorded name with the imported sanctions snapshot. Review each candidate before approving KYC. Complete PEP review separately.',
        'small text-muted');
    const run = element('button', hosted ? 'Run sanctions check' : 'Run or reload sanctions check',
        'btn btn-sm btn-outline-primary');
    run.type = 'button';
    const status = element('p', '', 'small mt-2 mb-1');
    status.setAttribute('role', 'status');
    const results = element('div');
    panel.append(heading, description, run, status, results);
    anchor.before(panel);

    let generation = 0;
    let busy = false;
    function reset() {
        generation++;
        busy = false;
        run.disabled = false;
        status.textContent = '';
        results.replaceChildren();
    }
    modal.addEventListener('show.bs.modal', reset);
    modal.addEventListener('hide.bs.modal', reset);

    async function request(rpc, payload, customerId) {
        if (busy) return;
        const ticket = ++generation;
        busy = true;
        run.disabled = true;
        if (hosted) results.replaceChildren();
        results.querySelectorAll('button').forEach(button => { button.disabled = true; });
        status.textContent = 'Waiting for the server…';
        try {
            const { data, error } = await client.rpc(rpc, payload);
            if (ticket !== generation || applicant.value !== customerId) return;
            if (error) throw Error(error.message || 'Screening request failed');
            const validReceipt = hosted
                ? /^[a-f0-9]{64}$/.test(data?.snapshot_sha256) && Number.isFinite(Date.parse(data.last_verified_at))
                : data?.run_id && (!payload.p_run_id || data.run_id === payload.p_run_id);
            if (data?.mode !== (hosted ? 'HOSTED_PREVIEW' : 'LOCAL_PILOT') ||
                data.customer_id !== customerId || !Array.isArray(data.hits) || !validReceipt) {
                throw Error('The server did not confirm this screening result');
            }
            render(data);
        } catch (error) {
            if (ticket === generation && applicant.value === customerId) {
                status.textContent = hosted ? error.message : error.message + ' Reload the screening check to confirm the saved result.';
            }
        } finally {
            if (ticket === generation) {
                busy = false;
                run.disabled = false;
                results.querySelectorAll('button').forEach(button => { button.disabled = false; });
            }
        }
    }

    function render(data) {
        results.replaceChildren();
        const total = data.hits.length;
        status.textContent = total ? `${total} possible match${total === 1 ? '' : 'es'}.`
            : 'No name match in this snapshot.';
        if (!hosted && data.confirmed_hold) {
            status.textContent = 'Confirmed sanctions match referred to Head of Compliance. Account activation is on hold.';
        } else if (!hosted && data.hits.some((_, index) => !data.decisions?.[index])) {
            status.textContent += ' Review all candidates before approving KYC.';
        }
        const reference = hosted ? `Snapshot SHA-256 ${data.snapshot_sha256}.` : `Screening reference ${data.run_id}.`;
        results.append(element('p', `Snapshot last checked ${new Date(data.last_verified_at || data.retrieved_at).toLocaleString()}. ${reference}`,
            'small text-muted text-break'));
        data.hits.forEach((hit, index) => {
            const item = element('article', '', 'border rounded p-2 mb-2');
            const title = element('strong', hit.name, 'small d-block');
            const evidence = element('p', `${sourceLabels[hit.source] || hit.source} · ${hit.designation_reference || hit.reference} · matched name ${hit.matched_name}`,
                'small mb-1');
            const source = element('a', 'Open official source', 'small d-block mb-2');
            source.href = officialSource(hit);
            source.target = '_blank';
            source.rel = 'noopener noreferrer';
            item.append(title, evidence, source);

            if (hosted) {
                results.append(item);
                return;
            }
            const decision = data.decisions?.[index];
            if (decision) {
                const label = decision.outcome === 'CONFIRMED_MATCH' ? 'Confirmed match' : 'False positive';
                item.append(element('p', `${label}. ${decision.rationale}`, 'small mb-0'));
            } else {
                const label = element('label', 'Review reason', 'small d-block');
                const reason = element('textarea', '', 'form-control form-control-sm mb-2');
                reason.rows = 2;
                reason.maxLength = 1000;
                label.append(reason);
                item.append(label);
                for (const [outcome, caption] of [['CONFIRMED_MATCH', 'Confirm match'], ['FALSE_POSITIVE', 'Dismiss as false positive']]) {
                    const button = element('button', caption, 'btn btn-sm btn-outline-secondary me-2');
                    button.type = 'button';
                    button.addEventListener('click', () => {
                        const rationale = reason.value.trim();
                        if (rationale.length < 10) {
                            status.textContent = 'Enter a review reason of at least 10 characters.';
                            reason.focus();
                            return;
                        }
                        void request('coreaml_kyc_review_sanctions', {
                            p_run_id: data.run_id,
                            p_hit_index: index,
                            p_outcome: outcome,
                            p_rationale: rationale,
                        }, data.customer_id);
                    });
                    item.append(button);
                }
            }
            results.append(item);
        });
    }

    run.addEventListener('click', () => {
        if (!applicant.value) return;
        const rpc = hosted ? 'coreaml_kyc_preview_sanctions' : 'coreaml_kyc_screen_sanctions';
        void request(rpc, { p_customer_id: applicant.value }, applicant.value);
    });

    return enable;
}

function enableReferrals(client, modal) {
    const localPilot = Boolean(modal);
    const directory = document.getElementById('view-kyc-directory');
    const profileTabs = ['tab-kyc-all', 'tab-kyc-pending', 'tab-kyc-completed']
        .map(id => document.getElementById(id));
    const filters = profileTabs[2]?.closest('.btn-group');
    const profiles = document.getElementById('kyc-directory-body')?.closest('.card');
    const search = document.getElementById('kyc-directory-search')?.closest('.input-group');
    if (!directory || !filters || !profiles || profileTabs.some(button => !button) ||
        document.getElementById('kyc-sanctions-referrals')) return;

    const launch = element('button', '', 'btn btn-sm btn-outline-dark fw-bold px-3 text-nowrap kyc-referrals-trigger');
    launch.type = 'button';
    launch.setAttribute('aria-controls', 'kyc-sanctions-referrals');
    launch.setAttribute('aria-pressed', 'false');
    const bell = element('span', 'notifications_active', 'material-symbols-outlined kyc-referrals-trigger__bell');
    bell.hidden = true;
    bell.setAttribute('aria-hidden', 'true');
    launch.append(element('span', 'Sanctions referrals'));
    if (localPilot) launch.append(bell);
    filters.classList.add('kyc-referrals-filters');
    filters.append(launch);

    const queue = element('section', '', 'kyc-referrals');
    queue.id = 'kyc-sanctions-referrals';
    queue.hidden = true;
    queue.setAttribute('aria-labelledby', 'kyc-sanctions-referrals-title');
    const heading = element('header', '', 'kyc-referrals__header');
    const title = element('h2', 'Sanctions referrals', 'fs-6 fw-bold mb-0');
    title.id = 'kyc-sanctions-referrals-title';
    const description = localPilot
        ? 'Review activation holds, approved corrections, and rescreening matches.'
        : 'Review possible sanctions matches from hosted rescreening for this bank.';
    heading.append(title, element('p', description, 'kyc-referrals__subtitle mb-0'));
    queue.append(heading);
    profiles.after(queue);
    let indicatorGeneration = 0;

    function showHoldIndicator(hasHolds, ticket) {
        if (ticket !== indicatorGeneration) return;
        bell.hidden = !hasHolds;
        launch.setAttribute('aria-label', hasHolds ? 'Sanctions referrals, open holds' : 'Sanctions referrals');
    }

    async function refreshHoldIndicator() {
        const ticket = ++indicatorGeneration;
        try {
            const { data, error } = await client.rpc('coreaml_kyc_sanctions_referral_page', { p_view: 'OPEN', p_offset: 0 });
            if (!error && Array.isArray(data)) showHoldIndicator(data.length > 0, ticket);
        } catch {
            // Keep the last verified indicator when the read is unavailable.
        }
    }

    const directoryIsVisible = () => !directory.classList.contains('d-none');
    const viewButtons = [];
    if (localPilot) {
        let wasVisible = directoryIsVisible();
        if (wasVisible) void refreshHoldIndicator();
        new MutationObserver(() => {
            const visible = directoryIsVisible();
            if (visible && !wasVisible) void refreshHoldIndicator();
            wasVisible = visible;
        }).observe(directory, { attributes: true, attributeFilter: ['class'] });
        window.addEventListener('focus', () => {
            if (directoryIsVisible()) void refreshHoldIndicator();
        });

        const views = element('div', '', 'kyc-referrals__views');
        views.setAttribute('role', 'group');
        views.setAttribute('aria-label', 'Referral views');
        const openView = element('button', 'Open holds', 'btn btn-sm btn-dark');
        const historyView = element('button', 'Correction history', 'btn btn-sm btn-outline-secondary');
        const rescreenView = element('button', 'Rescreening matches', 'btn btn-sm btn-outline-secondary');
        viewButtons.push([openView, 'OPEN'], [historyView, 'HISTORY'], [rescreenView, 'RESCREEN']);
        for (const [button, key] of viewButtons) {
            button.type = 'button';
            button.setAttribute('aria-pressed', String(key === 'OPEN'));
            button.addEventListener('click', () => selectView(key));
            views.append(button);
        }
        queue.append(views);
    }

    const queueStatus = element('p', '', 'kyc-referrals__status');
    queueStatus.setAttribute('role', 'status');
    const viewport = element('div', '', 'kyc-referrals__viewport');
    viewport.hidden = true;
    viewport.tabIndex = 0;
    viewport.setAttribute('role', 'region');
    viewport.setAttribute('aria-label', 'Sanctions referral results');
    const table = element('table', '', 'kyc-referrals__table');
    const header = element('thead');
    const headings = element('tr');
    for (const title of ['Applicant', 'Sanctions evidence', 'Review reason', 'Action']) {
        const cell = element('th', title);
        cell.scope = 'col';
        headings.append(cell);
    }
    header.append(headings);
    const items = element('tbody');
    table.append(header, items);
    viewport.append(table);

    const footer = element('div', '', 'kyc-referrals__footer');
    const count = element('span', '', 'kyc-referrals__muted');
    const controls = element('div', '', 'kyc-referrals__controls');
    const refresh = element('button', 'Refresh', 'btn btn-sm btn-outline-secondary');
    const previous = element('button', 'Previous', 'btn btn-sm btn-outline-secondary');
    const next = element('button', 'Next', 'btn btn-sm btn-outline-secondary');
    for (const button of [refresh, previous, next]) button.type = 'button';
    previous.hidden = next.hidden = true;
    previous.disabled = next.disabled = true;
    controls.append(refresh, previous, next);
    footer.append(count, controls);
    queue.append(queueStatus, viewport, footer);

    const pageButtons = [refresh, previous, next, ...viewButtons.map(([button]) => button)];
    const date = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' });
    let offset = 0;
    let view = localPilot ? 'OPEN' : 'RESCREEN';
    async function load(page) {
        const indicatorTicket = view === 'OPEN' && page === 0 ? ++indicatorGeneration : null;
        const isRescreen = view === 'RESCREEN';
        for (const button of pageButtons) button.disabled = true;
        previous.hidden = next.hidden = true;
        viewport.hidden = true;
        count.textContent = '';
        items.replaceChildren();
        queueStatus.hidden = false;
        queueStatus.textContent = 'Loading referrals…';
        try {
            const { data, error } = isRescreen
                ? await client.rpc('coreaml_kyc_sanctions_rescreen_page', { p_offset: page })
                : await client.rpc('coreaml_kyc_sanctions_referral_page', { p_view: view, p_offset: page });
            if (error || !Array.isArray(data)) throw Error(error?.message || 'Referrals unavailable.');
            if (indicatorTicket !== null) showHoldIndicator(data.length > 0, indicatorTicket);
            offset = page;
            const visible = data.slice(0, 25);
            for (const entry of visible) {
                const row = element('tr');
                const hit = entry.hit;
                const applicant = element('td');
                applicant.append(element('strong', entry.applicant_name, 'kyc-referrals__name'));

                const evidence = element('td');
                const link = element('a', sourceLabels[hit.source] || hit.source, 'kyc-referrals__source');
                link.href = officialSource(hit);
                link.target = '_blank';
                link.rel = 'noopener noreferrer';
                const nigeriaRecord = /^\/(?:Ind|Ent)SancDetails\?id=(\d+)$/.exec(hit.reference);
                const reference = hit.designation_reference ||
                    (hit.source === 'NIGERIA' && nigeriaRecord ? 'Record ' + nigeriaRecord[1] : hit.reference);
                evidence.append(link, element('span', reference, 'kyc-referrals__muted d-block'));
                if (hit.name !== entry.applicant_name) {
                    evidence.append(element('span', 'Listed as ' + hit.name, 'kyc-referrals__muted d-block'));
                }

                const reason = element('td');
                reason.append(element('p', entry.rationale, 'kyc-referrals__reason'));
                const reviewedAt = new Date(entry.reviewed_at);
                if (entry.reviewed_at && !Number.isNaN(reviewedAt.getTime())) {
                    reason.append(element('span', 'Reviewed ' + date.format(reviewedAt), 'kyc-referrals__muted'));
                }

                const action = element('td', '', 'kyc-referrals__action');
                if (isRescreen) {
                    renderRescreenMatch(entry, applicant, evidence, reason, action);
                    row.append(applicant, evidence, reason, action);
                    items.append(row);
                    continue;
                }
                applicant.append(element('span', entry.corrected ? 'Match corrected' : 'Activation on hold',
                    entry.corrected ? 'kyc-referrals__corrected' : 'kyc-referrals__hold'));
                const correction = entry.correction;
                if (view === 'HISTORY') {
                    const detail = element('div', '', 'mt-2');
                    detail.hidden = true;
                    const decision = element('button', 'View correction', 'btn btn-sm btn-outline-dark text-nowrap');
                    decision.type = 'button';
                    decision.setAttribute('aria-expanded', 'false');
                    decision.addEventListener('click', () => {
                        detail.hidden = !detail.hidden;
                        decision.setAttribute('aria-expanded', String(!detail.hidden));
                        decision.textContent = detail.hidden ? 'View correction' : 'Hide correction';
                    });
                    reason.replaceChildren(
                        element('strong', 'Correction approved', 'small d-block'),
                        element('span', entry.kyc_status === 'COMPLETED' ? 'KYC completed' : 'KYC pending', 'kyc-referrals__muted'),
                        detail
                    );
                    detail.append(
                        element('strong', 'Original confirmation', 'small d-block'),
                        element('p', entry.rationale, 'kyc-referrals__reason'),
                        element('strong', 'Correction reason', 'small d-block mt-2'),
                        element('p', correction.reason, 'kyc-referrals__reason'),
                        element('span', 'Evidence: ' + correction.evidence_reference, 'kyc-referrals__muted d-block'),
                        element('p', 'Decision reason: ' + correction.decision_reason, 'kyc-referrals__reason'),
                        element('span', 'Approved ' + date.format(new Date(correction.decided_at)), 'kyc-referrals__muted')
                    );
                    action.append(decision);
                } else {
                    const open = element('button', 'Open KYC review', 'btn btn-sm btn-outline-dark text-nowrap');
                    open.type = 'button';
                    open.addEventListener('click', () => void window.openKYCVerification(entry.customer_id));
                    action.append(open);
                }
                row.append(applicant, evidence, reason, action);
                items.append(row);

                if (view === 'HISTORY') continue;
                if (correction) {
                    const labels = { PROPOSED: 'Correction proposed', APPROVED: 'Correction approved', REJECTED: 'Correction rejected' };
                    reason.append(
                        element('strong', labels[correction.state], 'small d-block mt-2'),
                        element('p', correction.reason, 'kyc-referrals__reason'),
                        element('span', 'Evidence: ' + correction.evidence_reference, 'kyc-referrals__muted d-block')
                    );
                    if (correction.decision_reason) {
                        reason.append(element('p', 'Decision reason: ' + correction.decision_reason, 'kyc-referrals__reason'));
                    }
                }

                if (entry.corrected) continue;
                if (correction?.state === 'PROPOSED' && !correction.can_decide) {
                    action.append(element('span', 'Awaiting another Head of Compliance', 'kyc-referrals__muted d-block mt-2'));
                    continue;
                }
                const proposal = correction?.state !== 'PROPOSED';
                const toggle = element('button', proposal ? 'Propose correction' : 'Review correction',
                    'btn btn-sm btn-outline-secondary text-nowrap d-block mt-2 ms-auto');
                toggle.type = 'button';
                toggle.setAttribute('aria-expanded', 'false');
                action.append(toggle);
                items.append(correctionForm(entry, proposal, toggle));
            }
            viewport.hidden = visible.length === 0;
            queueStatus.hidden = visible.length > 0;
            const emptyStates = {
                OPEN: 'No open sanctions holds on this page.',
                HISTORY: 'No approved corrections on this page.',
                RESCREEN: 'No rescreening matches on this page.',
            };
            queueStatus.textContent = emptyStates[view];
            if (visible.length) {
                count.textContent = !offset && data.length <= 25
                    ? `${visible.length} referral${visible.length === 1 ? '' : 's'}`
                    : `Showing ${offset + 1}–${offset + visible.length}`;
            }
            previous.hidden = next.hidden = offset === 0 && data.length <= 25;
            previous.disabled = offset === 0;
            next.disabled = data.length <= 25;
        } catch (error) {
            queueStatus.textContent = error.message;
        } finally {
            refresh.disabled = false;
            for (const [button] of viewButtons) button.disabled = false;
        }
    }

    function renderRescreenMatch(entry, applicant, evidence, reason, action) {
        const labels = { FALSE_POSITIVE: 'False positive', FOLLOW_UP: 'Needs follow-up' };
        applicant.append(element('span', labels[entry.disposition] || 'Awaiting review',
            entry.disposition === 'FALSE_POSITIVE' ? 'kyc-referrals__corrected' : 'kyc-referrals__candidate'));
        evidence.append(element('span', 'Snapshot retrieved ' + date.format(new Date(entry.retrieved_at)), 'kyc-referrals__muted d-block'));
        if (entry.identity_changed) {
            reason.append(element('p', 'The recorded identity has changed since this check.', 'kyc-referrals__reason'));
        }
        if (entry.disposition) {
            reason.append(element('p', entry.rationale, 'kyc-referrals__reason'),
                element('span', 'Reviewed ' + date.format(new Date(entry.reviewed_at)), 'kyc-referrals__muted'));
            return;
        }
        reason.append(element('p', 'Possible match from scheduled rescreening.', 'kyc-referrals__reason'));
        const toggle = element('button', 'Review match', 'btn btn-sm btn-outline-dark text-nowrap');
        toggle.type = 'button';
        toggle.setAttribute('aria-expanded', 'false');
        const form = element('form', '', 'mt-2 text-start');
        form.hidden = true;
        const label = element('label', 'Review reason', 'small d-block');
        const input = element('textarea', '', 'form-control form-control-sm mb-2');
        input.required = true;
        input.minLength = 10;
        input.maxLength = 1000;
        input.rows = 2;
        label.append(input);
        form.append(label);
        const submitButtons = Object.entries(labels).map(([value, text]) => {
            const button = element('button', text, 'btn btn-sm btn-outline-dark me-1 mb-1');
            button.type = 'submit';
            button.value = value;
            return button;
        });
        const feedback = element('p', '', 'small mb-0');
        feedback.setAttribute('role', 'status');
        form.append(...submitButtons, feedback);
        action.append(toggle, form);
        toggle.addEventListener('click', () => {
            form.hidden = !form.hidden;
            toggle.setAttribute('aria-expanded', String(!form.hidden));
            if (!form.hidden) input.focus();
        });
        form.addEventListener('submit', async event => {
            event.preventDefault();
            const decision = event.submitter?.value;
            const rationale = input.value.trim();
            if (refresh.disabled || !decision) return;
            if (rationale.length < 10) {
                feedback.textContent = 'Enter a review reason of at least 10 characters.';
                return;
            }
            const disabled = pageButtons.map(button => button.disabled);
            for (const button of [...pageButtons, ...submitButtons]) button.disabled = true;
            feedback.textContent = 'Saving disposition…';
            try {
                const { data, error } = await client.rpc('coreaml_kyc_sanctions_review_rescreen_match', {
                    p_candidate_id: entry.id, p_disposition: decision, p_rationale: rationale,
                });
                if (error || data?.id !== entry.id || data.disposition !== decision) {
                    throw Error(error?.message || 'The server did not confirm the disposition.');
                }
                await load(0);
                queueStatus.hidden = false;
                queueStatus.textContent = 'Disposition saved. Account status is unchanged.';
            } catch (error) {
                feedback.textContent = error.message + ' Refresh to confirm any saved outcome.';
                pageButtons.forEach((button, index) => { button.disabled = disabled[index]; });
            } finally {
                for (const button of submitButtons) button.disabled = false;
            }
        });
    }

    function correctionForm(entry, proposal, toggle) {
        const row = element('tr', '', 'kyc-referrals__correction');
        row.hidden = true;
        const cell = element('td');
        cell.colSpan = 4;
        const form = element('form');
        const reasonLabel = element('label', proposal ? 'Reason the match was misclassified' : 'Decision reason', 'small d-block');
        const reason = element('textarea', '', 'form-control form-control-sm mt-1 mb-2');
        reason.required = true;
        reason.minLength = 10;
        reason.maxLength = 1000;
        reason.rows = 2;
        reasonLabel.append(reason);
        form.append(reasonLabel);
        let evidence;
        if (proposal) {
            const label = element('label', 'Supporting evidence reference', 'small d-block');
            evidence = element('input', '', 'form-control form-control-sm mt-1 mb-2');
            evidence.required = true;
            evidence.minLength = 5;
            evidence.maxLength = 500;
            label.append(evidence);
            form.append(label);
        }

        const buttons = [];
        const actions = proposal ? [['PROPOSED', 'Submit proposal']]
            : [['APPROVED', 'Approve correction'], ['REJECTED', 'Reject correction']];
        for (const [value, label] of actions) {
            const submit = element('button', label, 'btn btn-sm btn-outline-dark me-2');
            submit.type = 'submit';
            submit.value = value;
            form.append(submit);
            buttons.push(submit);
        }
        const feedback = element('p', '', 'small mb-0 mt-2');
        feedback.setAttribute('role', 'status');
        form.append(feedback);
        cell.append(form);
        row.append(cell);
        toggle.addEventListener('click', () => {
            row.hidden = !row.hidden;
            toggle.setAttribute('aria-expanded', String(!row.hidden));
            if (!row.hidden) reason.focus();
        });

        let requestId;
        form.addEventListener('submit', async event => {
            event.preventDefault();
            const decision = event.submitter?.value;
            if (!decision || refresh.disabled) return;
            const rationale = reason.value.trim();
            const reference = evidence?.value.trim();
            if (rationale.length < 10 || (proposal && reference.length < 5)) {
                feedback.textContent = 'Enter a reason and complete the required evidence reference.';
                return;
            }
            if (proposal) requestId ||= crypto.randomUUID();
            const id = proposal ? requestId : entry.correction.id;
            const rpc = proposal ? 'coreaml_kyc_propose_sanctions_correction' : 'coreaml_kyc_decide_sanctions_correction';
            const payload = proposal
                ? { p_request_id: id, p_run_id: entry.run_id, p_hit_index: entry.hit_index, p_reason: rationale, p_evidence_reference: reference }
                : { p_correction_id: id, p_decision: decision, p_reason: rationale };

            const disabled = pageButtons.map(button => button.disabled);
            for (const button of [...pageButtons, ...buttons]) button.disabled = true;
            feedback.textContent = 'Saving correction…';
            try {
                const { data, error } = await client.rpc(rpc, payload);
                if (error || data?.id !== id || (!proposal && data?.state !== decision)) {
                    throw Error(error?.message || 'Correction outcome could not be confirmed.');
                }
                await load(offset);
                if (offset !== 0) void refreshHoldIndicator();
                queueStatus.hidden = false;
                queueStatus.textContent = data.state === 'APPROVED'
                    ? 'Correction approved. Run a new sanctions check before attempting KYC approval.'
                    : data.state === 'REJECTED'
                        ? 'Correction rejected. The activation hold remains.'
                        : 'Correction submitted for independent review.';
            } catch (error) {
                feedback.textContent = error.message + ' Refresh the queue to confirm any saved outcome.';
                pageButtons.forEach((button, index) => { button.disabled = disabled[index]; });
            } finally {
                buttons.forEach(button => { button.disabled = false; });
            }
        });
        return row;
    }

    function selectView(nextView) {
        if (view === nextView || refresh.disabled) return;
        view = nextView;
        for (const [button, key] of viewButtons) {
            const selected = view === key;
            button.classList.toggle('btn-dark', selected);
            button.classList.toggle('btn-outline-secondary', !selected);
            button.setAttribute('aria-pressed', String(selected));
        }
        void load(0);
    }
    function showReferrals(show) {
        queue.hidden = !show;
        profiles.classList.toggle('d-none', show);
        search?.classList.toggle('d-none', show);
        launch.classList.toggle('btn-dark', show);
        launch.classList.toggle('btn-outline-dark', !show);
        launch.classList.toggle('active', show);
        launch.setAttribute('aria-pressed', String(show));
    }

    launch.addEventListener('click', () => {
        if (!queue.hidden) return;
        for (const button of profileTabs) {
            button.classList.remove('btn-dark', 'active');
            button.classList.add('btn-outline-dark');
        }
        showReferrals(true);
        if (!refresh.disabled) void load(0);
    });
    for (const button of profileTabs) button.addEventListener('click', () => showReferrals(false));
    modal?.addEventListener('hidden.bs.modal', () => {
        if (!directoryIsVisible()) return;
        const reloadOpenPage = !queue.hidden && !refresh.disabled && view === 'OPEN';
        if (reloadOpenPage) void load(offset);
        if (!reloadOpenPage || offset !== 0) void refreshHoldIndicator();
    });
    refresh.addEventListener('click', () => void load(0));
    previous.addEventListener('click', () => void load(offset - 25));
    next.addEventListener('click', () => void load(offset + 25));
}
