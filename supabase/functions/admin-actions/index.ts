import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { corsHeaders, errorResponse, jsonResponse, requireUser } from "../_shared/auth.ts";

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders(req) });
  }

  try {
    const { user: executingUser, role } = await requireUser(req, ['it_admin', 'head_of_compliance']);

    const { action, targetUserId } = await req.json()
    if (!action || !targetUserId) throw new Error('Missing action or target parameter')

    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )
    let targetEmail: string | undefined;

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
      const { data: targetUser, error: targetUserError } = await supabaseAdmin.auth.admin.getUserById(targetUserId);
      if (targetUserError || !targetUser.user?.email) {
        throw new Error('Unable to find an email address for the selected user.');
      }
      targetEmail = targetUser.user.email;

      const { error: resetError } = await supabaseAdmin.auth.admin.generateLink({
        type: 'recovery',
        email: targetEmail,
      })
      if (resetError) throw new Error(`Reset failed: ${resetError.message}`)
    } else {
        throw new Error('Invalid action provided')
    }

    // 2. WRITE TO THE IMMUTABLE AUDIT LEDGER
    const { error: auditError } = await supabaseAdmin.from('audit_logs').insert({
        event_type: `admin_action_${action}`,
        actor_id: executingUser.id,
        target_id: targetUserId,
        details: { 
            action: action,
            target_email: targetEmail ?? "ID provided",
            executed_by_role: role
        }
    })

    if (auditError) {
        console.error("Audit Log Failure:", auditError)
        // We don't throw here because the main action succeeded, but we log the failure.
    }

    return jsonResponse(req, { success: true });

  } catch (error) {
    return errorResponse(req, error);
  }
})
