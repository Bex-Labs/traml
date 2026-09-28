// deno-lint-ignore-file no-import-prefix
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, errorResponse, jsonResponse, requireUser } from "../_shared/auth.ts";

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders(req) });
  }

  try {
    await requireUser(req, ['it_admin', 'head_of_compliance']);

    const { email, role, tenantId } = await req.json()

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    const siteUrl = Deno.env.get('SUPABASE_URL') ? 'https://traml.vercel.app' : 'http://localhost:3000';
    const redirectTo = `${siteUrl}/setup-account.html`;

    // 1. EXACT ORIGINAL LOGIC: Pass the data safely inside the invite call
    const { data: authData, error: authError } = await supabaseAdmin.auth.admin.inviteUserByEmail(email, {
        data: { role: role, tenant_id: tenantId },
        redirectTo: redirectTo,
    });
    
    if (authError) throw new Error(`AUTH ERROR: ${authError.message}`)

    // 2. Sync to your profiles table
    await supabaseAdmin.from('user_profiles').upsert({
        id: authData.user?.id,
        tenant_id: tenantId,
        role: role
    });

    return jsonResponse(req, { success: true });
    
  } catch (error) {
    return errorResponse(req, error);
  }
})
