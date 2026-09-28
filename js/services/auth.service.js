// ======================================================
// CoreAML Auth Service
//
// Owns session verification, JWT decoding, and
// tenant/role resolution.
//
// Responsibilities
// ----------------
// - Verify active sessions
// - Decode and refresh JWTs for RLS claims
// - Execute database profile fallbacks
// - Handle secure logout
// ======================================================

import { supabase } from "../config.js";

/**
 * Retrieves the current session and securely resolves the user's role and tenant.
 * 
 * @returns {Promise<Object|null>} The resolved security context, or null if unauthenticated.
 */
export async function getVerifiedSession() {
    // 1. Verify Session
    const { data: { session } } = await supabase.auth.getSession();
    
    if (!session) {
        return null; 
    }

    // 2. Extract JWT Metadata
    let jwtPayload = JSON.parse(atob(session.access_token.split('.')[1]));
    let userRole = jwtPayload.app_metadata?.role || jwtPayload.user_metadata?.role;
    let tenantId = jwtPayload.app_metadata?.tenant_id || jwtPayload.user_metadata?.tenant_id;

    // 3. JWT Refresh Engine: If claims are missing, force a session refresh to unlock RLS
    if (!userRole || !tenantId) {
        console.warn("⚠️ JWT claims missing. Forcing token refresh to unlock Row Level Security (RLS)...");
        const { data: refreshData } = await supabase.auth.refreshSession();
        
        if (refreshData?.session) {
            jwtPayload = JSON.parse(atob(refreshData.session.access_token.split('.')[1]));
            userRole = jwtPayload.app_metadata?.role || jwtPayload.user_metadata?.role;
            tenantId = jwtPayload.app_metadata?.tenant_id || jwtPayload.user_metadata?.tenant_id;
        }

        // 4. Fallback: If STILL missing, query the profile table
        if (!userRole || !tenantId) {
            try {
                const { data: profile, error } = await supabase
                    .from('profiles')
                    .select('role, tenant_id')
                    .eq('id', session.user.id)
                    .maybeSingle(); 

                if (!error && profile) {
                    userRole = profile.role;
                    tenantId = profile.tenant_id;
                }
            } catch (fallbackErr) {
                console.error("Fallback query failed:", fallbackErr);
            }
        }
    }

    // 5. Final safety net
    if (!userRole || !tenantId || userRole === 'DEBUG_PROFILE_NOT_FOUND') {
        throw new Error("Tenancy Context Failed. User lacks role or tenant mapping in both JWT and DB.");
    }

    return {
        session,
        user: session.user,
        role: userRole,
        tenantId: tenantId
    };
}

/**
 * securely logs the user out and writes to the audit ledger.
 */
export async function logout() {
    await supabase.rpc('log_user_logout');
    await supabase.auth.signOut();
}