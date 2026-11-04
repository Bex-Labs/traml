// Read-only alert evidence; content from the database is always rendered as text.
import { getEvidenceById, getEvidenceTransaction, getEvidenceEvaluation } from '../services/alerts.service.js';
let generation = 0;
const el = id => document.getElementById(id);
function node(tag, text, className = '') {
    const item = document.createElement(tag);
    if (text !== undefined) item.textContent = String(text);
    if (className) item.className = className;
    return item;
}
function clear(state = 'idle', message = '') {
    const panel = el('preview-evidence-panel');
    if (!panel) return;
    panel.dataset.state = state;
    panel.dataset.alertId = '';
    el('preview-evidence-status').textContent = message;
    for(const id of ['preview-recorded-amount','preview-recorded-threshold'])if(el(id))el(id).textContent='Not recorded';
    el('preview-evidence-fields').replaceChildren();
    el('preview-evidence-warnings').replaceChildren();
    el('preview-evidence-transactions').replaceChildren();
    el('preview-evidence-ledger-result').replaceChildren();
    el('preview-evidence-ledger-result').dataset.state = 'idle';
    const button = el('preview-evidence-ledger');
    button.hidden = true; button.disabled = false; button.onclick = null;
}
export function clearAlertEvidence() { generation++; clear(); }
function field(label, value) {
    if (value === undefined || value === null || value === '') return;
    if(label==='Recorded amount'&&el('preview-recorded-amount'))el('preview-recorded-amount').textContent=String(value);
    if(label==='Threshold'&&el('preview-recorded-threshold'))el('preview-recorded-threshold').textContent=String(value);
    const block = node('div', undefined, 'col-md-6');
    block.append(node('dt', label, 'small text-muted'), node('dd', value, 'small text-break mb-1'));
    el('preview-evidence-fields').append(block);
}
function displayMoney(amount, currency) {
    if (amount === null || amount === undefined || amount === '') return 'Not recorded';
    const value = Number(amount);
    if (!Number.isFinite(value)) return 'Amount unavailable';
    try { return new Intl.NumberFormat('en-NG', { style: 'currency', currency, minimumFractionDigits: 2 }).format(value); }
    catch { return `${value.toLocaleString('en-NG')} ${currency || '(currency not recorded)'}`; }
}
function displayTime(value) {
    if (!value || !Number.isFinite(Date.parse(value))) return 'Not recorded';
    return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Africa/Lagos' }).format(new Date(value)) + ' WAT';
}
function friendlyWarning(value) {
    return String(value).replace(/^SYNTHETIC DEMO:/, 'Demonstration only:')
        .replace(/^NAME_CONFIGURATION_MISMATCH:/, 'Configuration mismatch:')
        .replace(/^LEGACY_STRUCTURING_HEURISTIC:/, 'Structuring calculation limitation:')
        .replace(/^SIMULTANEOUS_ACTIVITY:/, 'Simultaneous activity:');
}
function moneyKey(value) {
    const match = String(value).match(/^(\d+)(?:\.(\d{1,2}))?$/);
    return match ? BigInt(match[1]) * 100n + BigInt((match[2] || '').padEnd(2, '0')) : null;
}
function sameTransaction(actual, saved) {
    return actual && saved && ['id', 'account_id', 'currency', 'transaction_type', 'channel', 'transaction_reference'].every(k => actual[k] === saved[k])
        && moneyKey(actual.amount) !== null && moneyKey(actual.amount) === moneyKey(saved.amount)
        && Number.isFinite(Date.parse(actual.transaction_timestamp))
        && Date.parse(actual.transaction_timestamp) === Date.parse(saved.transaction_timestamp);
}
export async function openAlertEvidence(alertId) {
    const ticket = ++generation;
    clear('loading', 'Loading recorded evidence…');
    const panel = el('preview-evidence-panel');
    if (!panel) return;
    try {
        const record = await getEvidenceById(alertId);
        if (ticket !== generation) return;
        if (!record) { clear('unavailable', 'Evidence unavailable. The alert may not exist or you may not have access.'); return; }
        if (record.id !== alertId) throw Error('Evidence identity mismatch');
        const stored = record.evidence;
        if (!stored || typeof stored !== 'object' || Array.isArray(stored) || !Object.keys(stored).length) {
            clear('empty', 'No structured evidence was recorded for this alert.'); return;
        }
        const rule = stored.rule_snapshot || {};
        const calculation = stored.evidence || {};
        const saved = stored.transaction_snapshot;
        if (saved && (saved.id !== record.transaction_id || stored.transaction_id !== record.transaction_id
            || stored.tenant_id !== record.tenant_id || stored.customer_id !== record.customer_id
            || stored.rule_id !== rule.id)) throw Error('Evidence linkage mismatch');
        let evaluation = null;
        if (stored.set_id && saved) {
            evaluation = await getEvidenceEvaluation(record.transaction_id);
            if (ticket !== generation) return;
            if (!evaluation || evaluation.set_id !== stored.set_id) throw Error('Evaluation state unavailable');
        }
        panel.dataset.alertId = record.id;
        field('Rule', rule.rule_name || record.rule_triggered);
        const demo = typeof stored.method === 'string' && stored.method.startsWith('SYNTHETIC_');
        field('Review type', demo ? 'Demonstration — manual review' : calculation.comparison === 'MANUAL_REVIEW' ? 'Manual review' : 'Recorded detection');
        if (demo) {
            field('Why this alert appears', 'A fictional investigation scenario was created for demonstration. It is not an automated engine finding.');
            field('Detection and explanation', 'No AML engine or SHAP evaluation was run for this demonstration alert. The amount alone does not establish suspicious activity.');
        }
        if (calculation.related_transaction_id) field('Related transfer', 'A related transaction reference is recorded. Open transaction inspection to check the authorized relationship; this reference alone does not verify it.');
        field('Transaction reference', stored.transaction_reference || saved?.transaction_reference);
        field('Recorded amount', saved ? displayMoney(saved.amount, saved.currency) : calculation.transaction_amount);
        field('Direction / channel', saved ? `${({DEBIT:'Money out (debit)', CREDIT:'Money in (credit)'})[saved.transaction_type] || saved.transaction_type || 'Direction not recorded'} / ${saved.channel === 'SYSTEM' ? 'System-recorded' : saved.channel || 'Channel not recorded'}` : null);
        field('Recorded time', saved ? displayTime(saved.transaction_timestamp) : null);
        field('Comparison', ({MANUAL_REVIEW: 'Manual investigation review', GT: 'Amount strictly above threshold', COUNT_GTE: 'Credit count at or above threshold', CURRENT_LT_TOTAL_GTE_COUNT_GTE_2: 'Current credit below threshold; combined credits meet threshold (at least two)'})[calculation.comparison] || calculation.comparison);
        field('Threshold', calculation.threshold);
        field('Transaction count / count threshold', calculation.transaction_count === undefined ? null
            : `${calculation.transaction_count}${calculation.threshold_count === undefined ? '' : ' / ' + calculation.threshold_count}`);
        if (/^\d+$/.test(calculation.total_minor_units || '')) {
            const minor = BigInt(calculation.total_minor_units);
            field('Recorded credit volume', `${minor / 100n}.${String(minor % 100n).padStart(2, '0')} ${saved?.currency || ''}`.trim());
        }
        field('Window start', calculation.window_start);
        field('Window end', calculation.window_end);
        field('Inactive days / configured days', calculation.threshold_days === undefined ? null
            : `${calculation.inactive_days ?? 'No prior activity'} / ${calculation.threshold_days}`);
        field('Previous activity', calculation.previous_activity);
        field('Evaluation state', evaluation?.state === 'POLICY_BLOCKED' ? 'Policy review required (POLICY_BLOCKED)' : evaluation?.state);
        field('Filing status', stored.filing_status === 'NOT_FILED' ? 'Not filed — no regulatory filing confirmed.' : 'No filing confirmation recorded.');
        if (evaluation?.state === 'POLICY_BLOCKED') {
            el('preview-evidence-warnings').append(node('p', 'CTR policy remains unresolved for this transaction. This alert does not confirm filing.', 'small text-warning-emphasis'));
        }
        for (const warning of Array.isArray(stored.warnings) ? stored.warnings : []) {
            el('preview-evidence-warnings').append(node('p', friendlyWarning(warning), 'small text-warning-emphasis'));
        }
        const supporting = Array.isArray(calculation.supporting_transactions) ? calculation.supporting_transactions : [];
        if (supporting.length) {
            const table = node('table', undefined, 'table table-sm small');
            const head = node('tr');
            for (const title of ['Reference', 'Amount', 'Currency', 'Direction', 'Time']) head.append(node('th', title));
            const thead = node('thead'); thead.append(head); table.append(thead);
            const body = node('tbody');
            for (const row of supporting.slice(0, 200)) {
                const tr = node('tr'); tr.dataset.transactionId = String(row.id || '');
                for (const value of [row.transaction_reference || row.id, displayMoney(row.amount, row.currency), row.currency, row.transaction_type, displayTime(row.transaction_timestamp)]) tr.append(node('td', value ?? ''));
                body.append(tr);
            }
            table.append(body); el('preview-evidence-transactions').append(table);
            if (supporting.length > 200) el('preview-evidence-transactions').append(node('p', `Showing 200 of ${supporting.length} recorded transactions. Full evidence is below.`, 'small'));
        } else el('preview-evidence-transactions').append(node('p', 'No supporting transaction list recorded for this comparison.', 'small text-muted'));
        const details = node('details', undefined, 'mt-2');
        details.append(node('summary', 'Technical details — original recorded evidence', 'small'));
        const raw = node('pre', JSON.stringify(stored, null, 2), 'small text-break border rounded p-2 mt-2');
        raw.style.whiteSpace = 'pre-wrap'; raw.style.maxHeight = '320px'; raw.style.overflow = 'auto';
        details.append(raw); el('preview-evidence-transactions').append(details);
        const button = el('preview-evidence-ledger');
        if (record.transaction_id && saved) {
            button.hidden = false;
            button.onclick = async () => {
                button.disabled = true;
                const output = el('preview-evidence-ledger-result');
                output.dataset.state = 'loading'; output.replaceChildren(node('p', 'Reading linked ledger entry…', 'small'));
                try {
                    const actual = await getEvidenceTransaction(record.transaction_id);
                    if (ticket !== generation) return;
                    if (!actual) { output.dataset.state = 'unavailable'; output.replaceChildren(node('p', 'Linked transaction unavailable.', 'small text-danger')); return; }
                    if (!sameTransaction(actual, saved)) { output.dataset.state = 'mismatch'; output.replaceChildren(node('p', 'Ledger and recorded evidence differ. Reconciliation is required.', 'small text-danger')); return; }
                    output.dataset.state = 'verified';
                    output.replaceChildren(node('p', `Ledger check passed: this transaction matches the saved evidence. ${displayMoney(actual.amount, actual.currency)} · ${actual.transaction_reference}. This confirms the record match, not that the activity is suspicious or cleared.`, 'small text-success'));
                } catch {
                    if (ticket === generation) { output.dataset.state = 'error'; output.replaceChildren(node('p', 'Linked ledger entry could not be read. Try again.', 'small text-danger')); }
                } finally { if (ticket === generation) button.disabled = false; }
            };
        }
        panel.dataset.state = 'ready'; el('preview-evidence-status').textContent = 'Recorded evidence loaded.';
    } catch {
        if (ticket === generation) clear('error', 'Recorded evidence could not be loaded or verified. Try reopening the alert.');
    }
}
el('alertPreviewModal')?.addEventListener('hidden.bs.modal', clearAlertEvidence);
