import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { idNumber, endpointType } = await req.json()
    
    // Grab your secret API key stored in Supabase
    const API_KEY = Deno.env.get('PROVN_API_KEY') 

    // Determine the exact URL based on what the officer selected
    let apiUrl = '';
    if (endpointType === 'BVN') apiUrl = `https://api.provn.ng/v1/bvn/verify`;
    else if (endpointType === 'NIN') apiUrl = `https://api.provn.ng/v1/nin/verify`;
    else if (endpointType === 'CAC') apiUrl = `https://api.provn.ng/v1/cac/verify`;

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
    return new Response(
      JSON.stringify(kycData),
      { headers: { ...corsHeaders, "Content-Type": "application/json" }, status: 200 }
    )

  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    })
  }
})