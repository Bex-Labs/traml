import { collectSnapshot } from './feeds.mjs';

const url = Deno.env.get('SUPABASE_URL');
const secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const failures = new Set(['UN_FEED', 'OFAC_SDN_FEED', 'OFAC_NON_SDN_FEED', 'NIGERIA_FEED', 'SNAPSHOT_VALIDATION']);

async function rpc(name, args) {
    if (!url || !secret) throw Error('Supabase service configuration is unavailable');
    const result = await fetch(url + '/rest/v1/rpc/' + name, {
        method: 'POST',
        headers: { apikey: secret, Authorization: 'Bearer ' + secret, 'Content-Type': 'application/json' },
        body: JSON.stringify(args),
        signal: AbortSignal.timeout(45000),
    });
    if (!result.ok) {
        console.error('Sanctions worker RPC failed', name, result.status);
        throw Error('Worker RPC failed');
    }
    return result.json();
}

Deno.serve(async request => {
    if (request.method !== 'POST') return new Response(null, { status: 405 });
    const token = request.headers.get('X-CoreAML-Dispatch');
    if (!token || !/^[a-f0-9]{64}$/.test(token)) return new Response(null, { status: 401 });
    const id = request.headers.get('X-CoreAML-Attempt');
    if (!id || !/^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(id)) {
        return new Response(null, { status: 400 });
    }

    try {
        if (await rpc('coreaml_claim_sanctions_refresh', { p_id: id, p_token: token }) !== true) {
            return new Response(null, { status: 401 });
        }
    } catch {
        return new Response(null, { status: 503 });
    }

    let publication = false;
    try {
        const snapshot = await collectSnapshot();
        publication = true;
        const receipt = await rpc('coreaml_finish_sanctions_refresh', {
            p_id: id, p_sha256: snapshot.sha256, p_retrieved_at: snapshot.retrieved_at,
            p_entries: snapshot.entries, p_files: snapshot.files,
        });
        return Response.json({ ...receipt, counts: snapshot.counts });
    } catch (error) {
        const failure = publication ? 'PUBLICATION' : failures.has(error.message) ? error.message : 'SNAPSHOT_VALIDATION';
        console.error('Hosted sanctions refresh failed', failure, error.feedError ?? '');
        await rpc('coreaml_finish_sanctions_refresh', { p_id: id, p_failure: failure }).catch(() => {});
        return Response.json({ status: 'FAILED', failure }, { status: 502 });
    }
});
