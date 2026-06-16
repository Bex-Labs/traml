// deno-lint-ignore-file no-import-prefix
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' } })
  }

  try {
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

    return new Response(JSON.stringify({ success: true }), {
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      status: 200,
    })
    
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : "An unknown error occurred";
    return new Response(JSON.stringify({ error: errorMessage }), {
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      status: 400,
    })
  }
})