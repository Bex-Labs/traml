// ======================================================
// CoreAML API Executor
//
// Shared execution helper for all frontend services.
//
// Responsibilities
// ----------------
// - Execute Supabase operations
// - Standardise error handling
// - Return data only
//
// This module MUST NOT:
// - Manipulate the DOM
// - Display notifications
// - Implement business logic
// ======================================================

/**
 * Executes a Supabase operation and standardises
 * error handling across all frontend services.
 *
 * @param {Function} operation
 * @returns {Promise<any>}
 */
export async function execute(operation) {

    const { data, error } = await operation();

    if (error) {
        console.error("[CoreAML API]", error);
        throw error;
    }

    return data;

}