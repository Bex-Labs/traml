import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      { global: { headers: { Authorization: req.headers.get('Authorization')! } } }
    )

    // 1. Verify the token is mathematically valid and not expired
    const { data: { user: executingUser }, error: userError } = await supabaseClient.auth.getUser()
    if (userError || !executingUser) throw new Error('Unauthorized executing user')

    // 2. Extract the exact role directly from the secure JWT
    const authHeader = req.headers.get('Authorization')!
    const token = authHeader.replace('Bearer ', '')
    const jwtPayload = JSON.parse(atob(token.split('.')[1]))
    
    // Fallback checks both app_metadata and user_metadata just in case
    const role = jwtPayload.app_metadata?.role || jwtPayload.user_metadata?.role;

    if (role !== 'it_admin' && role !== 'head_of_compliance') {
        throw new Error(`Insufficient privileges. Role detected: ${role}`)
    }

    const { action, targetUserId } = await req.json()
    if (!action || !targetUserId) throw new Error('Missing action or target parameter')

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // 1. EXECUTE THE ACTION
    if (action === 'deactivate') {
      const { error: banError } = await supabaseAdmin.auth.admin.updateUserById(targetUserId, { ban_duration: '876000h' })
      if (banError) throw new Error(`Ban failed: ${banError.message}`)

      const { error: updateError } = await supabaseAdmin.from('user_profiles').update({ is_active: false }).eq('id', targetUserId)
      if (updateError) throw new Error(`Profile update failed: ${updateError.message}`)
      
    } else if (action === 'restore') {
      const { error: unbanError } = await supabaseAdmin.auth.admin.updateUserById(targetUserId, { ban_duration: 'none' })
      if (unbanError) throw new Error(`Restore failed: ${unbanError.message}`)

      const { error: updateError } = await supabaseAdmin.from('user_profiles').update({ is_active: true }).eq('id', targetUserId)
      if (updateError) throw new Error(`Profile update failed: ${updateError.message}`)

    } else if (action === 'reset') {
      const { error: resetError } = await supabaseAdmin.auth.admin.generateLink({
        type: 'recovery',
        email: targetUserId, // Assuming targetUserId is passed as email for reset
      })
      if (resetError) throw new Error(`Reset failed: ${resetError.message}`)
    } else {
        throw new Error('Invalid action provided')
    }

    // 2. WRITE TO THE IMMUTABLE AUDIT LEDGER
    const { error: auditError } = await supabaseAdmin.from('audit_logs').insert({
        event_type: `admin_action_${action}`,
        actor_id: executingUser.id,
        target_id: action === 'reset' ? null : targetUserId, // We don't have target UUID on reset, just email
        details: { 
            action: action,
            target_email: action === 'reset' ? targetUserId : "ID provided",
            executed_by_role: role
        }
    })

    if (auditError) {
        console.error("Audit Log Failure:", auditError)
        // We don't throw here because the main action succeeded, but we log the failure.
    }

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error) {
    // Type-check to satisfy strict TypeScript environments
    const errorMessage = error instanceof Error ? error.message : "An unknown error occurred";

    return new Response(JSON.stringify({ error: errorMessage }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})