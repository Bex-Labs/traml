import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

serve(async (req) => {
  try {
    const supabase = createClient(SUPABASE_URL!, SUPABASE_SERVICE_ROLE_KEY!);
    
    const { data: schedules, error: scheduleError } = await supabase
        .from('report_schedules')
        .select('*')
        .eq('is_active', true);

    if (scheduleError) throw scheduleError;
    if (!schedules || schedules.length === 0) return new Response("No active schedules.", { status: 200 });

    for (const schedule of schedules) {
        const { count: totalAlerts } = await supabase.from('alerts').select('*', { count: 'exact', head: true });
        const { count: sarsFiled } = await supabase.from('suspicious_transaction_reports').select('*', { count: 'exact', head: true }).eq('status', 'APPROVED');
        const { count: highRisk } = await supabase.from('customers').select('*', { count: 'exact', head: true }).eq('risk_tier', 'HIGH');

        const htmlBody = `
          <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; border: 1px solid #e2e8f0; border-radius: 8px; overflow: hidden;">
            <div style="background-color: #0f172a; padding: 20px; text-align: center; color: white;">
                <h2 style="margin: 0;">BexAML Compliance Overview</h2>
                <p style="margin: 5px 0 0 0; color: #94a3b8;">${schedule.frequency} Automated Summary</p>
            </div>
            <div style="padding: 30px; background-color: #f8fafc;">
                <h3 style="color: #334155; margin-top: 0;">System Snapshot</h3>
                <table style="width: 100%; border-collapse: collapse; background: white; border-radius: 6px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
                    <tr>
                        <td style="padding: 15px; border-bottom: 1px solid #e2e8f0; color: #64748b; font-weight: bold;">🚨 Total Alerts Generated</td>
                        <td style="padding: 15px; border-bottom: 1px solid #e2e8f0; text-align: right; font-weight: bold; color: #0f172a;">${totalAlerts || 0}</td>
                    </tr>
                    <tr>
                        <td style="padding: 15px; border-bottom: 1px solid #e2e8f0; color: #64748b; font-weight: bold;">⚖️ Approved SARs Vaulted</td>
                        <td style="padding: 15px; border-bottom: 1px solid #e2e8f0; text-align: right; font-weight: bold; color: #0f172a;">${sarsFiled || 0}</td>
                    </tr>
                    <tr>
                        <td style="padding: 15px; color: #64748b; font-weight: bold;">⚠️ High-Risk Entities</td>
                        <td style="padding: 15px; text-align: right; font-weight: bold; color: #ef4444;">${highRisk || 0}</td>
                    </tr>
                </table>
                <p style="margin-top: 30px; font-size: 14px; color: #64748b; text-align: center;">
                    Log in to your Command Center to view the full Immutable Vault.
                </p>
            </div>
          </div>
        `;

        const emailRes = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${RESEND_API_KEY}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                from: 'BexAML Engine <onboarding@resend.dev>', 
                to: schedule.recipient_emails,
                subject: `BexAML ${schedule.frequency} Compliance Report`,
                html: htmlBody
            })
        });

        if (!emailRes.ok) console.error(`Failed to send to ${schedule.recipient_emails}`);
    }

    return new Response(JSON.stringify({ status: "Success" }), { headers: { "Content-Type": "application/json" } });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  }
});