import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders, errorResponse, jsonResponse, requireUser } from "../_shared/auth.ts";

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders(req) });
  }

  try {
    await requireUser(req, ['compliance_officer', 'bank_manager', 'head_of_compliance', 'it_admin', 'system_admin']);

    const { idNumber, endpointType } = await req.json();
    if (!idNumber || !['BVN', 'NIN', 'CAC'].includes(endpointType)) {
      return jsonResponse(req, { error: 'A valid identity number and verification type are required.' }, 400);
    }
    
    // Grab your secret API key stored in Supabase
    const API_KEY = Deno.env.get('PROVN_API_KEY') 

    // Determine the exact URL based on what the officer selected
    let apiUrl: string;
    if (endpointType === 'BVN') apiUrl = `https://api.provn.ng/v1/bvn/verify`;
    else if (endpointType === 'NIN') apiUrl = `https://api.provn.ng/v1/nin/verify`;
    else apiUrl = `https://api.provn.ng/v1/cac/verify`;

    // Make the secure call to the real KYC provider
    const provnResponse = await fetch(apiUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${API_KEY}`
      },
      body: JSON.stringify({ id_number: idNumber })
    });

    const kycData = await provnResponse.json();

    // Send the real data back to your dashboard
    return jsonResponse(req, kycData);

  } catch (error) {
    return errorResponse(req, error);
  }
});
