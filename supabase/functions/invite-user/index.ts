// deno-lint-ignore-file no-import-prefix
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

serve(async (req: Request) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' } })
  }

  try {
    // DIAGNOSTIC TRAP 1: The Frontend Payload
    let requestData;
    try {
        requestData = await req.json()
    } catch (err) {
        throw new Error("DIAGNOSTIC 1: The frontend sent an empty or invalid JSON body. Check the UI fetch request.")
    }

    const { email, role, tenantId } = requestData

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // DIAGNOSTIC TRAP 2: The Auth API (Ghost Bypass)
    let authData, authError;
    try {
        // Bypass the SMTP mailer entirely and force-create an active user
        const result = await supabaseAdmin.auth.admin.createUser({
            email: email,
            email_confirm: true, // Bypasses the email click requirement
            password: 'SecurePassword123!', // Hardcodes an initial password
            user_metadata: { role: role }
        });
        authData = result.data;
        authError = result.error;
    } catch (err) {
        throw new Error("DIAGNOSTIC 2: The Supabase Auth API failed during ghost creation.");
    }
    
    if (authError) throw new Error(`AUTH ERROR: ${authError.message}`)
    if (!authData?.user?.id) throw new Error("AUTH ERROR: Supabase created the user but returned no ID.")

    // DIAGNOSTIC TRAP 3: The Database Insert
    const { error: profileError } = await supabaseAdmin
      .from('user_profiles')
      .insert({
        id: authData.user.id,
        tenant_id: tenantId,
        role: role
      })

    if (profileError) throw new Error(`DATABASE ERROR: ${profileError.message}`)

    // Success Route
    return new Response(JSON.stringify({ success: true }), {
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      status: 200,
    })
    
  } catch (error) {
    // Return the exact diagnostic message to your browser
    const errorMessage = error instanceof Error ? error.message : "An unknown error occurred";
    
    return new Response(JSON.stringify({ error: errorMessage }), {
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      status: 400,
    })
  }
})