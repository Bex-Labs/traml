import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/auth.ts";

serve(async (req) => {
    // 1. Handle CORS Preflight perfectly
    if (req.method === 'OPTIONS') {
        return new Response('ok', { headers: corsHeaders(req) });
    }

    try {
        const { caseDetails, customerData, riskScore } = await req.json();
        
        // 2. Retrieve API Key securely
        const apiKey = Deno.env.get('GEMINI_API_KEY');
        if (!apiKey) {
            throw new Error("GEMINI_API_KEY is missing from the Supabase Vault.");
        }

        const prompt = `
        You are a Principal AML Investigator at a Tier-1 financial institution writing a formal Suspicious Activity Report (SAR) narrative for the Nigerian Financial Intelligence Unit (NFIU).
        
        Using the provided context, write a highly sophisticated, 3-paragraph executive summary detailing the financial anomalies.
        - Paragraph 1: Entity profile and account baseline summary.
        - Paragraph 2: The specific suspicious typologies detected (e.g., structuring, velocity spikes, evasion tactics) relying on the SHAP explanation.
        - Paragraph 3: The regulatory conclusion and justification for the recommended action.
        
        RULES:
        - Maintain a strictly clinical, objective, and regulatory tone.
        - Do NOT use markdown formatting, bolding, or asterisks. Write in plain text.
        - Assume the audience is a federal financial regulator.

        Customer Profile: ${customerData}
        Current Risk Score: ${riskScore}
        Investigation Context & Cryptographic Evidence: ${caseDetails}
        `;

        // 3. Call Gemini
        const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }] })
        });

        const data = await response.json();

        // 4. Catch Gemini API Specific Errors (Like 403 Invalid API Key)
        if (!response.ok) {
            console.error("Gemini API Error:", data);
            throw new Error(data.error?.message || "Gemini API rejected the request.");
        }

        const generatedText = data.candidates[0].content.parts[0].text;

        // 5. Return the clean text with dynamic CORS headers
        return new Response(JSON.stringify({ draft: generatedText }), {
            headers: { ...corsHeaders(req), 'Content-Type': 'application/json' },
            status: 200,
        });

    } catch (error) {
        // TYPE FIX: Tell TypeScript how to safely read the 'unknown' error
        const errorMessage = error instanceof Error ? error.message : String(error);
        console.error("Edge Function Error:", errorMessage);
        
        // Return a clean 400 with the EXACT error message so the dashboard can log it
        return new Response(JSON.stringify({ error: errorMessage }), {
            headers: { ...corsHeaders(req), 'Content-Type': 'application/json' },
            status: 400,
        });
    }
});