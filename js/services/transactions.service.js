// ======================================================
// CoreAML Transaction Service
//
// Owns transaction retrieval for investigator workflows.
//
// Responsibilities
// ----------------
// - Transaction Monitoring
// - Customer transaction history
// - Investigation timelines
// - Ledger retrieval
//
// This service MUST NOT:
// - Manipulate the DOM
// - Render HTML
// - Display notifications
// - Implement AML rules
// ======================================================

import { supabase } from "../config.js";
import { execute } from "../utils/apiExecutor.js";

/**
 * Retrieve transactions for the Transaction Monitoring screen.
 *
 * @param {string} typeFilter
 * @returns {Promise<Array>}
 */
export async function getMonitoringFeed(typeFilter = "ALL") {

    let query = supabase
        .from("transactions")
        .select(`
            id,
            amount,
            transaction_type,
            transaction_timestamp,
            transaction_reference,
            accounts (
                customers (
                    id,
                    entity_name,
                    first_name,
                    last_name
                )
            )
        `)
        .order("transaction_timestamp", {
            ascending: false
        })
        .limit(50);

    if (typeFilter !== "ALL") {
        query = query.eq("transaction_type", typeFilter);
    }

    return execute(() => query);

}