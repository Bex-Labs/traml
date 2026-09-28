// ======================================================
// CoreAML Risk Service
// ======================================================

import { supabase } from "../config.js";
import { execute } from "../utils/apiExecutor.js";

export async function getInvestigationProfile(customerId) {
    // Upgraded to use the Unified Risk Engine (Phase 3)
    const data = await execute(() =>
        supabase
            .from("customers")
            .select("risk_score, risk_tier")
            .eq("id", customerId)
            .maybeSingle()
    );
    
    // Map it to the structure expected by investigations.service.js
    if (data) {
        return {
            risk_level: data.risk_tier,
            total_score: data.risk_score
        };
    }
    return null;
}