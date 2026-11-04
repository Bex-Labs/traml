import {getVerifiedSession} from './auth.service.js';
import {createIntelligenceService} from './intelligence.service.js';
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
export async function getDirectoryPage(filter='ALL',search='',offset=0){
    const service=createIntelligenceService(supabase,getVerifiedSession);
    if(!['ALL','PENDING','COMPLETED'].includes(filter))throw Error('Invalid directory filter.');
    return service.customers({kyc:filter==='ALL'?'':filter,search,offset});
}
export async function getDirectory(filter='ALL'){return (await getDirectoryPage(filter)).rows;}

/**
 * Retrieve a single customer by ID.
 *
 * @param {string} customerId
 * @returns {Promise<Object|null>}
 */
export async function getById(customerId) {

    return execute(() =>
        supabase
            .from("customers")
            .select("*")
            .eq("id", customerId)
            .maybeSingle()
    );

}