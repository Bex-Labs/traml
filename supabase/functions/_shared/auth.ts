import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const defaultOrigin = "https://traml.vercel.app";

export const corsHeaders = (req: Request) => {
    // 1. Extract the origin of the incoming request
    const origin = req.headers.get('Origin');
    
    // 2. Check if it's a local development server
    const isLocal = origin?.startsWith('http://localhost') || origin?.startsWith('http://127.0.0.1');
    
    // 3. Dynamically grant access to localhost, otherwise default to strict production security
    const allowOrigin = isLocal ? origin : 'https://traml.vercel.app';

    return {
        'Access-Control-Allow-Origin': allowOrigin || '*',
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
        'Access-Control-Allow-Methods': 'POST, GET, OPTIONS, PUT, DELETE',
    };
};

export function jsonResponse(req: Request, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), "Content-Type": "application/json" },
  });
}

export async function requireUser(req: Request, allowedRoles: string[]) {
  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) throw new HttpError(401, "Authentication is required.");
  const client = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    { global: { headers: { Authorization: authorization } } },
  );
  const { data: { user }, error } = await client.auth.getUser();
  if (error || !user) throw new HttpError(401, "Invalid or expired session.");
  const role = typeof user.app_metadata?.role === "string" ? user.app_metadata.role : undefined;
  if (!role || !allowedRoles.includes(role)) throw new HttpError(403, "You are not permitted to perform this action.");
  return { user, role };
}

export function requireSharedSecret(req: Request, headerName: "x-cron-secret" | "x-webhook-secret", envName: string) {
  const expected = Deno.env.get(envName);
  const received = req.headers.get(headerName);
  if (!expected || !received || received !== expected) throw new HttpError(401, "Unauthorized caller.");
}

export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export function errorResponse(req: Request, error: unknown) {
  const status = error instanceof HttpError ? error.status : 500;
  const message = error instanceof HttpError ? error.message : "Unexpected server error.";
  console.error(error);
  return jsonResponse(req, { error: message }, status);
}
