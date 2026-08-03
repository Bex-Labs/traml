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
 * Standardised execution wrapper.
 */

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
                rule_triggered,
                severity,
                status,
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
    );

}

/**
 * Claim an alert using optimistic locking.
 *
 * Returns an array exactly like the original
 * implementation.
 */
export async function claim(alertId, userId) {

    return execute(() =>
        supabase
            .from("alerts")
            .update({
                status: "INVESTIGATING",
                assigned_user_id: userId
            })
            .eq("id", alertId)
            .eq("status", "UNASSIGNED")
            .select()
    );

}