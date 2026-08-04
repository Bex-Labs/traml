// ======================================================
// CoreAML Customer Service
//
// Owns all customer-related database operations.
//
// Responsibilities
// ----------------
// - Customer directory
// - Customer lookup
// - Customer profile retrieval
// - Customer updates
//
// This service MUST NOT:
// - Manipulate the DOM
// - Render HTML
// - Display notifications
// - Implement AML business logic
// ======================================================

import { supabase } from "../config.js";
import { execute } from "../utils/apiExecutor.js";

/**
 * Load customers for the KYC Directory.
 *
 * @param {string} filter
 * @returns {Promise<Array>}
 */
export async function getDirectory(filter = "ALL") {

    let query = supabase
        .from("customers")
        .select("*")
        .order("risk_score", {
            ascending: false
        })
        .limit(50);

    if (filter === "PENDING") {
        query = query.eq("kyc_status", "PENDING");
    }

    if (filter === "COMPLETED") {
        query = query.eq("kyc_status", "COMPLETED");
    }

    return execute(() => query);

}