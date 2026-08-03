// ======================================================
// CoreAML API Gateway
//
// This file provides the single frontend entry point for
// all communication with Supabase.
//
// NOTE:
// Do NOT place business logic here.
// Do NOT manipulate the DOM here.
// This layer only communicates with the backend.
// ======================================================

import { supabase } from "./config.js";

/**
 * Executes a Supabase operation and standardises
 * error handling across the application.
 *
 * @param {Function} operation
 * @returns {Promise<any>}
 */
async function execute(operation) {

    const { data, error } = await operation();

    if (error) {
        console.error("[CoreAML API]", error);
        throw error;
    }

    return data;

}

/**
 * CoreAML API namespaces.
 *
 * These namespaces will gradually be implemented
 * as we migrate functionality out of dashboard.html.
 */
const API = {

    alerts: {

        /**
         * Load all unassigned alerts.
         */
        /**
 * Load alerts by workflow status.
 *
 * @param {string} status
 * @returns {Promise<Array>}
 */
async getByStatus(status) {

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

    },

    customers: {},

    transactions: {},

    risk: {},

    rules: {},

    sar: {},

    reports: {},

    auth: {},

    execute

};

export default API;
export { API };