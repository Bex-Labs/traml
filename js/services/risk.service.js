// ======================================================
// CoreAML Risk Service
//
// Investigation-oriented risk capabilities.
//
// This service exposes investigator-ready
// risk information rather than raw database tables.
// ======================================================

import { supabase } from "../config.js";
import { execute } from "../utils/apiExecutor.js";

/**
 * Retrieve the customer's current risk profile.
 *
 * NOTE:
 * This is intentionally a small first capability.
 * It will later expand into a full investigation
 * profile as more data sources are integrated.
 */
export async function getInvestigationProfile(customerId) {

    return execute(() =>
        supabase
            .from("customer_risk_profiles")
            .select("*")
            .eq("customer_id", customerId)
            .maybeSingle()
    );

}