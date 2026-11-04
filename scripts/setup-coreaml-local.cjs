// Synthetic fixtures for Bex-Labs/traml at 24691a2. No external dependencies.
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const API = 'http://127.0.0.1:55321';
const CONTAINER = 'supabase_db_sentinel-aml';
const PASSWORD = 'CoreAML-Local-Only!2026';
const BANKS = [1, 2, 3, 4].map(n => ({
  id: `a1000000-0000-4000-8000-${String(n).padStart(12, '0')}`,
  name: `Synthetic Test Bank ${n}`,
}));
const ROLES = ['it_admin', 'head_of_compliance', 'compliance_officer', 'bank_manager',
  'branch_manager', 'teller', 'sales_rep', 'bankmanager'];
const LEGACY_PROFILE_ROLES = new Set(['it_admin', 'head_of_compliance', 'compliance_officer', 'bank_manager']);
const USERS = ROLES.map(role => ({ role, bank: BANKS[0], email: `${role}@coreaml-local.test` }));
for (let i = 1; i < BANKS.length; i++) {
  USERS.push({ role: 'compliance_officer', bank: BANKS[i], email: `compliance_bank${i + 1}@coreaml-local.test` });
}

function run(command, args, input) {
  const p = spawnSync(command, args, { input, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (p.error || p.status !== 0) throw new Error(`${command} failed: ${p.error?.message || p.stderr || 'nonzero exit'}`);
  return p.stdout;
}
function sql(value) { return "'" + String(value).replace(/'/g, "''") + "'"; }
function query(statement) {
  return run('docker', ['exec', '-i', CONTAINER, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres', '-At'], statement);
}
async function main() {
  const root = path.resolve(__dirname, '..');
  process.chdir(root);
  const config = fs.readFileSync('supabase/config.toml', 'utf8');
  if (!/^project_id\s*=\s*"sentinel-aml"/m.test(config)) throw new Error('Expected the sentinel-aml local configuration.');
  const inspect = JSON.parse(run('docker', ['inspect', CONTAINER]))[0];
  const boundPorts = inspect.NetworkSettings?.Ports?.['5432/tcp'] || [];
  if (!inspect.State?.Running || !boundPorts.some(p => p.HostPort === '55322')) {
    throw new Error('Expected running sentinel-aml database on host port 55322.');
  }
  const cli = process.platform === 'win32'
    ? spawnSync('cmd.exe', ['/d', '/s', '/c', 'supabase status -o json'], { encoding: 'utf8' })
    : spawnSync('supabase', ['status', '-o', 'json'], { encoding: 'utf8' });
  if (cli.error || cli.status !== 0) throw new Error('Cannot read local Supabase status. Run supabase status to diagnose.');
  let status;
  try { status = JSON.parse(cli.stdout); } catch { throw new Error('Supabase status did not return JSON. No fixtures were created.'); }
  if (status.API_URL !== API) throw new Error(`Local API must be ${API}. No fixtures were created.`);
  const secret = status.SECRET_KEY || status.SERVICE_ROLE_KEY;
  const publicKey = status.PUBLISHABLE_KEY || status.ANON_KEY;
  if (!secret || !publicKey) throw new Error('Local status is missing API keys. Do not paste secret keys into chat.');

  // Every HTTP request is pinned to the loopback API; redirects are rejected.
  async function request(route, method = 'GET', body, token) {
    const response = await fetch(API + route, {
      method, redirect: 'error', signal: AbortSignal.timeout(30000),
      headers: { apikey: (token || route.startsWith('/auth/v1/token?')) ? publicKey : secret, 'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(`${method} ${route.split('?')[0]} returned ${response.status}: ${payload.msg || payload.message || payload.error_description || payload.error || 'request failed'}`);
    return payload;
  }
  const migrationNames = query('SELECT name FROM supabase_migrations.schema_migrations ORDER BY version;');
  if (!migrationNames.includes('aml0032_compliance_reporting')) throw new Error('Expected reporting migration is not applied.');
  query('BEGIN;\n' + BANKS.map(b => `INSERT INTO public.banks(id,name) VALUES (${sql(b.id)},${sql(b.name)}) ON CONFLICT(id) DO UPDATE SET name=EXCLUDED.name;\nINSERT INTO public.tenants(id,institution_name) VALUES (${sql(b.id)}::uuid,${sql(b.name)}) ON CONFLICT(id) DO NOTHING;`).join('\n') + '\nCOMMIT;');
  const existing = [];
  for (let page = 1; ; page++) {
    const data = await request(`/auth/v1/admin/users?page=${page}&per_page=100`);
    existing.push(...(data.users || []));
    if ((data.users || []).length < 100) break;
  }
  const report = { api: API, migrations: migrationNames.trim().split('\n'), fixtures: [], checks: [], limitations: [
    'Staff profile presence is checked against the current database; the baseline checks role and tenant agreement.',
    'No AML thresholds or rules are invented; transaction scenarios are a subsequent step.',
    'Authentication checks do not establish RLS isolation, authorization correctness, or browser workflow correctness.',
  ] };
  for (const fixture of USERS) {
    const found = existing.find(u => u.email === fixture.email);
    const input = { email: fixture.email, password: PASSWORD, email_confirm: true,
      app_metadata: { ...(found?.app_metadata || {}), role: fixture.role, tenant_id: fixture.bank.id },
      user_metadata: { full_name: `Synthetic ${fixture.role.replaceAll('_', ' ')}` } };
    const result = found
      ? await request(`/auth/v1/admin/users/${found.id}`, 'PUT', input)
      : await request('/auth/v1/admin/users', 'POST', input);
    const user = result.user || result;
    if (!user.id) throw new Error(`Auth returned no user ID for ${fixture.email}`);
    fixture.id = user.id;
    query(`BEGIN; INSERT INTO public.profiles(id,email,role,tenant_id,full_name) VALUES (${sql(user.id)}::uuid,${sql(fixture.email)},${sql(fixture.role)},${sql(fixture.bank.id)},${sql(input.user_metadata.full_name)}) ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,role=EXCLUDED.role,tenant_id=EXCLUDED.tenant_id,full_name=EXCLUDED.full_name;\n` +
      (LEGACY_PROFILE_ROLES.has(fixture.role) ? `INSERT INTO public.user_profiles(id,tenant_id,role,full_name,is_active) VALUES (${sql(user.id)}::uuid,${sql(fixture.bank.id)},${sql(fixture.role)},${sql(input.user_metadata.full_name)},true) ON CONFLICT(id) DO UPDATE SET tenant_id=EXCLUDED.tenant_id,role=EXCLUDED.role,full_name=EXCLUDED.full_name,is_active=true;` : '') + '\nCOMMIT;');
    const hasStaffProfile = Number(query(`SELECT count(*) FROM public.user_profiles WHERE id=${sql(user.id)}::uuid;`).trim()) === 1;
    report.fixtures.push({ email: fixture.email, role: fixture.role, bank: fixture.bank.name, user_profiles: hasStaffProfile });
  }
  // Customer fixtures have stable synthetic IDs. Existing fixture balances are not reset.
  const customerStatements = [];
  BANKS.forEach((bank, i) => {
    for (let n = 1; n <= 3; n++) {
      const suffix = String(i * 3 + n).padStart(12, '0');
      const customerId = `b1000000-0000-4000-8000-${suffix}`;
      const accountId = `c1000000-0000-4000-8000-${suffix}`;
      customerStatements.push(`INSERT INTO public.customers(id,tenant_id,customer_type,first_name,last_name,entity_name,email,kyc_status) VALUES (${sql(customerId)}::uuid,${sql(bank.id)},'INDIVIDUAL','Synthetic',${sql(`Customer ${i * 3 + n}`)},${sql(`Synthetic Customer ${i * 3 + n}`)},${sql(`customer${i * 3 + n}@coreaml-local.test`)},'VERIFIED') ON CONFLICT(id) DO NOTHING;`);
      customerStatements.push(`INSERT INTO public.accounts(id,customer_id,account_number,account_type,currency,status,opened_at,balance) VALUES (${sql(accountId)}::uuid,${sql(customerId)}::uuid,${sql(String(9000000000 + i * 3 + n))},'SAVINGS','NGN','ACTIVE',CURRENT_DATE,20000000) ON CONFLICT(id) DO NOTHING;`);
    }
  });
  query('BEGIN;\n' + customerStatements.join('\n') + '\nCOMMIT;');
  for (const fixture of USERS) {
    try {
      const session = await request('/auth/v1/token?grant_type=password', 'POST', { email: fixture.email, password: PASSWORD });
      const claims = JSON.parse(Buffer.from(session.access_token.split('.')[1], 'base64url').toString('utf8'));
      const ok = claims.app_metadata?.role === fixture.role && claims.app_metadata?.tenant_id === fixture.bank.id;
      report.checks.push({ email: fixture.email, check: 'Password login and JWT role/tenant', result: ok ? 'PASS' : 'FAIL' });
      await request('/auth/v1/logout', 'POST', undefined, session.access_token);
    } catch (e) {
      report.checks.push({ email: fixture.email, check: 'Password login and JWT role/tenant', result: 'FAIL', error: e.message });
    }
  }
  const reportDir = path.join(root, '.coreaml-local');
  fs.mkdirSync(reportDir, { recursive: true });
  fs.writeFileSync(path.join(reportDir, 'setup-results.json'), JSON.stringify(report, null, 2) + '\n');
  console.table(report.checks);
  console.log('Fixtures: 4 synthetic banks, 11 synthetic staff users, 12 synthetic customers/accounts.');
  console.log(`Local fixture password: ${PASSWORD}`);
  console.log('Report: .coreaml-local/setup-results.json (contains no tokens or secret API keys).');
  const missingProfiles = report.fixtures.filter(user => !user.user_profiles);
  console.log(missingProfiles.length ? `Staff profile rows still missing: ${missingProfiles.length}.` : 'All 11 synthetic staff users have user_profiles rows.');
  if (report.checks.some(c => c.result !== 'PASS')) process.exitCode = 1;
}
main().catch(e => { console.error('Setup stopped:', e.message); process.exitCode = 1; });
