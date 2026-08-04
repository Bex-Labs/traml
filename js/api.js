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
import * as alerts from "./services/alerts.service.js";
import * as customers from "./services/customers.service.js";

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

    alerts,

    customers,

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