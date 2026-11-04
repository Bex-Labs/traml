// ======================================================
// CoreAML Alert Service
//
// This module owns all frontend communication with the
// alerts domain.
//
// Responsibilities
// ----------------
// - Read alerts
// - Claim alerts
//
// It does NOT:
// - Manipulate the DOM
// - Show notifications
// - Render tables
// - Implement AML business logic
// ======================================================

import { supabase } from "../config.js";
import { execute } from "../utils/apiExecutor.js";

/**
 * Load alerts by workflow status.
 *
 * @param {string} status
 * @returns {Promise<Array>}
 */
export async function getByStatus(status) {
    return execute(() =>
        supabase
            .from("alerts")
            .select(`
                id,
                alert_ref,
                customer_id,
                rule_triggered,
                severity,
                status,
                details,
                created_at,
                customers (
                    entity_name,
                    first_name,
                    last_name
                )
            `)
            .eq("status", status)
            .order("created_at", {
                ascending: false
            })
            .abortSignal(AbortSignal.timeout(10000))
    );
}

/**
 * Claim an alert using optimistic locking.
 *
 * Returns an array exactly like the original
 * implementation.
 */
export async function claimCase(alertId) {
    const result = await execute(() => supabase.rpc('coreaml_claim_case', { p_alert_id: alertId }));
    if (!result || typeof result.case_reference !== 'string' || !Array.isArray(result.alert_ids)
        || !result.alert_ids.includes(alertId) || !result.investigator_id) {
        throw new Error('The server did not confirm the complete case claim. Refresh before retrying.');
    }
    return result;
}

// Compatibility adapter: ownership is derived on the server; supplied user IDs are ignored.
export async function claim(alertId, _userId) {
    const result = await claimCase(alertId);
    return result.alert_ids.map(id => ({ id, status: 'INVESTIGATING',
        assigned_user_id: result.investigator_id, case_reference: result.case_reference }));
}

/**
 * Retrieve all alerts for a customer.
 *
 * @param {string} customerId
 * @returns {Promise<Array>}
 */
export async function getByCustomer(customerId) {
    return execute(() =>
        supabase
            .from("alerts")
            .select(`
                id,
                alert_ref,
                status,
                severity,
                rule_triggered,
                created_at
            `)
            .eq("customer_id", customerId)
            .order("created_at", {
                ascending: false
            })
    );
}
/** Read one authorized alert for its evidence panel. Empty means unavailable. */
export async function getEvidenceById(id) {
    const rows = await execute(() => supabase.from('alerts')
        .select('id,alert_ref,customer_id,transaction_id,tenant_id,rule_triggered,evidence')
        .eq('id', id).limit(1).abortSignal(AbortSignal.timeout(10000)));
    return rows?.[0] || null;
}

/** Read the linked ledger entry under the caller's normal bank permissions. */
export async function getEvidenceTransaction(id) {
    const rows = await execute(() => supabase.from('transactions')
        .select('id,transaction_reference,account_id,amount,currency,transaction_type,channel,transaction_timestamp')
        .eq('id', id).limit(1).abortSignal(AbortSignal.timeout(10000)));
    return rows?.[0] || null;
}

/** Compatible evaluation state is separate from alert workflow status. */
export async function getEvidenceEvaluation(id) {
    const rows = await execute(() => supabase.from('coreaml_compatible_runs')
        .select('id,state,set_id').eq('transaction_id', id).limit(1)
        .abortSignal(AbortSignal.timeout(10000)));
    return rows?.[0] || null;
}
