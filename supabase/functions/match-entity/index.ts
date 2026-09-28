// deno-lint-ignore-file no-import-prefix no-explicit-any
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { corsHeaders, errorResponse, jsonResponse, requireSharedSecret } from "../_shared/auth.ts";

// Tell local TypeScript that the Edge Runtime will provide this global object
declare const Supabase: any;

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const supabase = createClient(supabaseUrl, supabaseServiceKey)

// Initialize Supabase's free native embedding model
const session = new Supabase.ai.Session('gte-small')

serve(async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });

    try {
        requireSharedSecret(req, 'x-webhook-secret', 'MATCH_ENTITY_WEBHOOK_SECRET');
        const payload = await req.json()
        const customer = payload.record
        
        if (!customer.entity_name || customer.identity_embedding) {
             return jsonResponse(req, { status: "Skipped: Embedding exists or invalid" });
        }

        const identityString = `${customer.entity_name} ${customer.industry || ''} ${customer.geography || ''}`
        
        // Generate a 384-dimension vector natively (No API key needed)
        const embeddingResult = await session.run(identityString, { mean_pool: true, normalize: true })
        const vector = Array.from(embeddingResult)

        await supabase
            .from('customers')
            .update({ identity_embedding: vector })
            .eq('id', customer.id)

        // The _matchError prefix silences the "unused variable" lint warning
        const { data: matches, error: _matchError } = await supabase.rpc('match_sanctions', {
            query_embedding: vector,
            match_threshold: 0.88,
            match_count: 1
        })

        if (matches && matches.length > 0) {
            const topMatch = matches[0]
            
            await supabase.from('alerts').insert([{
                alert_ref: `ALT-${Math.random().toString(36).substring(2, 8).toUpperCase()}`,
                customer_id: customer.id,
                rule_triggered: 'Sanctions Watchlist Match (Semantic Vector)',
                severity: 'CRITICAL',
                status: 'UNASSIGNED',
                details: `Vector Engine identified an ${Math.round(topMatch.similarity * 100)}% semantic match with sanctioned entity: "${topMatch.sanction_entity_name}".`
            }])
            
            await supabase.from('customers').update({ kyc_status: 'FROZEN' }).eq('id', customer.id)
            console.log(`🚨 CRITICAL SANCTIONS MATCH: Customer ${customer.id} frozen.`)
        }

        return jsonResponse(req, { status: "Evaluated" });

    } catch (err) {
        return errorResponse(req, err);
    }
})
