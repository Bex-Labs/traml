import { supabase } from '../config.js';

const isUUID = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
function requireValue(ok, message) { if (!ok) throw new Error(message); }
export function draftPayload(narrative, entities, txs) {
    requireValue(typeof narrative === 'string' && [...narrative].length <= 20000, 'Narrative must contain at most 20,000 characters.');
    const entity_ids = entities.map(entity => entity.id), transaction_refs = [...txs];
    requireValue(entity_ids.length <= 100 && entity_ids.every(isUUID) && new Set(entity_ids).size === entity_ids.length, 'Pin up to 100 valid customer records.');
    requireValue(transaction_refs.length <= 200 && transaction_refs.every(ref => typeof ref === 'string' && ref.length > 0 && ref.length <= 512) && new Set(transaction_refs).size === transaction_refs.length, 'Invalid or duplicate transaction pins.');
    return { narrative, snapshot: { entity_ids, transaction_refs } };
}
export function createCaseWorkflowService(client, timeout = 15000) {
    async function bounded(build) {
        const controller = new AbortController(); let timer;
        try {
            return await Promise.race([
                (async () => {
                    const { data, error } = await build(controller.signal);
                    if (error) {
                        const failure = new Error(error.message || 'Case request failed.');
                        failure.code = error.code;
                        failure.definitive = /^(?:[0-9A-Z]{5}|PGRST\d+)$/.test(error.code || '');
                        throw failure;
                    }
                    return data;
                })(),
                new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); reject(new Error('Case request timed out. Retry to confirm the same request.')); }, timeout); })
            ]);
        } finally { clearTimeout(timer); }
    }
    return {
        async load(alertId) {
            requireValue(isUUID(alertId), 'A valid claimed alert is required.');
            const d = await bounded(signal => client.rpc('coreaml_load_case_draft', { p_alert_id: alertId }).abortSignal(signal));
            requireValue(d && isUUID(d.alert_id) && Array.isArray(d.alert_ids) && d.alert_ids.includes(alertId) && d.alert_ids.includes(d.alert_id) && d.alert_ids.every(isUUID) && typeof d.case_reference === 'string' && d.case_reference.startsWith('CASE-') && Number.isInteger(d.revision) && d.revision >= 0 && typeof d.exists === 'boolean' && typeof d.read_only === 'boolean' && ['INVESTIGATING', 'CLOSED'].includes(d.case_status) && ['IN_PROGRESS', 'CLOSED'].includes(d.status) && typeof d.draft_narrative === 'string' && Array.isArray(d.evidence_snapshot?.entities) && Array.isArray(d.evidence_snapshot?.txs), 'Incomplete case draft confirmation.');
            draftPayload(d.draft_narrative, d.evidence_snapshot.entities, d.evidence_snapshot.txs);
            requireValue(d.evidence_snapshot.entities.every(e => typeof e.name === 'string'), 'Invalid saved customer labels.');
            requireValue(d.status !== 'CLOSED' || (d.read_only && d.case_status === 'CLOSED'), 'Invalid closed case confirmation.');
            return d;
        },
        async list() {
            // This filter is for selection only. Database RLS remains the authority.
            const session = await bounded(() => client.auth.getSession());
            if (!session?.session?.user?.id) return [];
            const rows = await bounded(signal => client.from('investigation_drafts')
                .select('id,alert_id,case_reference,revision,updated_at,alerts(customer_id)')
                .eq('investigator_id', session.session.user.id).eq('status', 'IN_PROGRESS')
                .order('updated_at', { ascending: false }).limit(20).abortSignal(signal));
            requireValue(Array.isArray(rows), 'Draft list unavailable.');
            return rows.filter(d => isUUID(d.alert_id) && typeof d.case_reference === 'string');
        },
        async act(op) {
            const { alertId, caseReference, revision, requestId, action, payload } = op;
            requireValue(isUUID(alertId) && isUUID(requestId) && Number.isInteger(revision) && revision >= 0 && ['SAVE', 'CLOSE'].includes(action), 'Invalid case operation.');
            const args = { p_alert_id: alertId, p_action: action, p_expected_revision: revision, p_request_id: requestId };
            if (action === 'SAVE') { args.p_narrative = payload.narrative; args.p_snapshot = payload.snapshot; }
            const r = await bounded(signal => client.rpc('coreaml_case_action', args).abortSignal(signal));
            requireValue(r && r.request_id === requestId && r.alert_id === alertId && r.case_reference === caseReference && isUUID(r.id) && r.revision === revision + 1 && r.status === (action === 'SAVE' ? 'IN_PROGRESS' : 'CLOSED') && typeof r.replayed === 'boolean', 'Incomplete case action confirmation. Retry the same request.');
            return r;
        }
    };
}
const service = createCaseWorkflowService(supabase);
export const load = service.load;
export const list = service.list;
export const act = service.act;
