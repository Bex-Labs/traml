'use strict';

const fs = require('node:fs');
const { randomBytes } = require('node:crypto');
const { DB, API, assertLocal, run, query, lit } = require('./aml-compatible-db.cjs');
const { extractAdminKey, statusAdminKey } = require('./setup-case-claim-peer-local.cjs');

const EMAIL = 'head_sanctions_peer@coreaml-local.test';
const FIXTURE = 'coreaml_sanctions_head_peer_v1';
const ROLE = 'head_of_compliance';

function read(sql) {
    return JSON.parse(query('BEGIN READ ONLY; ' + sql + ' COMMIT;'));
}

function existingHeads() {
    return read(`
        SELECT coalesce(jsonb_agg(DISTINCT p.tenant_id), '[]'::jsonb)
        FROM public.user_profiles p
        JOIN auth.users u ON u.id = p.id
        JOIN public.banks b ON b.id = p.tenant_id
        WHERE p.role = ${lit(ROLE)} AND p.is_active IS TRUE
          AND u.email LIKE '%@coreaml-local.test' AND u.email <> ${lit(EMAIL)}
          AND u.email_confirmed_at IS NOT NULL
          AND (u.banned_until IS NULL OR u.banned_until <= now())
          AND u.raw_app_meta_data->>'role' = p.role
          AND u.raw_app_meta_data->>'tenant_id' = p.tenant_id;
    `);
}

function fixtureAccount() {
    return read(`
        SELECT coalesce((
            SELECT jsonb_build_object(
                'id', u.id, 'fixture', u.raw_app_meta_data->>'fixture',
                'auth_role', u.raw_app_meta_data->>'role', 'auth_bank', u.raw_app_meta_data->>'tenant_id',
                'profile_role', p.role, 'profile_bank', p.tenant_id, 'active', p.is_active,
                'confirmed', u.email_confirmed_at IS NOT NULL,
                'unbanned', u.banned_until IS NULL OR u.banned_until <= now()
            )
            FROM auth.users u LEFT JOIN public.user_profiles p ON p.id = u.id
            WHERE lower(u.email) = ${lit(EMAIL)}
        ), 'null'::jsonb);
    `);
}

function verify(account, bank) {
    if (!account || account.fixture !== FIXTURE || account.auth_role !== ROLE ||
        account.auth_bank !== bank || account.profile_role !== ROLE || account.profile_bank !== bank ||
        account.active !== true || account.confirmed !== true || account.unbanned !== true) {
        throw Error('The fixture lacks a verified active same-bank assignment. Inspect it in local Studio.');
    }
}

function adminKeyFromStatus() {
    let status;
    try { status = JSON.parse(fs.readFileSync(0, 'utf8').replace(/^\uFEFF/, '')); }
    catch { throw Error('Expected local Supabase status JSON on standard input'); }

    const url = status?.API_URL || status?.api_url;
    if (typeof url !== 'string' || !['http://127.0.0.1:55321', 'http://localhost:55321'].includes(url.replace(/\/$/, ''))) {
        throw Error('CLI status does not describe the local API on port 55321');
    }
    const keys = [
        status.SERVICE_ROLE_KEY, status.service_role_key,
        status.SECRET_KEY, status.secret_key,
    ];
    for (const key of keys) {
        if (typeof key !== 'string') continue;
        try { return extractAdminKey(['SUPABASE_SERVICE_ROLE_KEY=' + key]); } catch {}
    }
    throw Error('Local CLI status did not contain a recognized Auth admin key');
}

function localAdminKey() {
    const gateway = 'supabase_kong_sentinel-aml';
    const [details] = JSON.parse(run('docker', ['inspect', gateway]));
    if (!details.State?.Running || !details.NetworkSettings?.Ports?.['8000/tcp']?.some(p => p.HostPort === '55321')) {
        throw Error('Expected the local sentinel-aml gateway on port 55321');
    }
    const env = details.Config?.Env || [];
    try { return extractAdminKey(env); } catch {}
    try {
        const yaml = run('docker', ['exec', gateway, 'cat', '/home/kong/kong.yml']);
        return extractAdminKey(env, yaml);
    } catch {}
    try { return statusAdminKey(args => run('supabase', args)); }
    catch { throw Error('Could not read the local Auth admin credential from the gateway or CLI'); }
}

async function main() {
    assertLocal();
    if (DB !== 'supabase_db_sentinel-aml' || API !== 'http://127.0.0.1:55321') {
        throw Error('This seed only runs against the sentinel-aml local stack');
    }
    const banks = existingHeads();
    if (banks.length !== 1) {
        throw Error('Expected one bank with an active @coreaml-local.test Head of Compliance');
    }
    const [bank] = banks;
    const existing = fixtureAccount();
    if (existing) {
        verify(existing, bank);
        console.log('Verified existing local fixture:', EMAIL);
        console.log('Bank:', bank, '· Use the password printed when this fixture was created.');
        return;
    }

    const key = process.argv.includes('--status-stdin') ? adminKeyFromStatus() : localAdminKey();
    const password = 'LocalHead!' + randomBytes(18).toString('base64url');
    let response;
    try {
        response = await fetch(API + '/auth/v1/admin/users', {
            method: 'POST', redirect: 'error', signal: AbortSignal.timeout(15000),
            headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
            body: JSON.stringify({
                email: EMAIL, password, email_confirm: true,
                app_metadata: { fixture: FIXTURE, role: ROLE, tenant_id: bank },
                user_metadata: { full_name: 'Synthetic sanctions review Head' },
            }),
        });
    } catch {
        throw Error('Local Auth did not confirm the request. Check local Studio before retrying.');
    }
    if (!response.ok) {
        await response.body?.cancel();
        throw Error('Local Auth Admin returned HTTP ' + response.status + '. Check local Studio before retrying.');
    }
    const created = await response.json();
    const account = fixtureAccount();
    verify(account, bank);
    if (account.id !== created.id) throw Error('The Auth response did not match the verified local fixture');

    console.log('Created and verified a second local Head of Compliance.');
    console.log('Email:', EMAIL);
    console.log('Password:', password);
    console.log('Bank:', bank);
}

main().catch(error => {
    const safe = String(error.message).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '[redacted]')
        .replace(/sb_secret_[\w-]+/g, '[redacted]').split('\n')[0].slice(0, 250);
    console.error('Local Head seed stopped:', safe);
    process.exitCode = 1;
});
