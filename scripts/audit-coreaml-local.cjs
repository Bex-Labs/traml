// Local baseline: authenticated Data API isolation and database configuration.
// Does not insert transactions, change policies, enable triggers, or tune rules.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const API = 'http://127.0.0.1:55321';
const CONTAINER = 'supabase_db_sentinel-aml';
const PASSWORD = 'CoreAML-Local-Only!2026';
const bankId = n => `a1000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const fixtureId = (prefix, n) => `${prefix}1000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const checks = [];
const findings = [];

function run(command, args, input) {
  const p = spawnSync(command, args, { input, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (p.error || p.status !== 0) throw new Error(`${command} failed: ${p.error?.message || p.stderr || 'nonzero exit'}`);
  return p.stdout;
}
function query(sql) {
  return run('docker', ['exec', '-i', CONTAINER, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres', '-At'], sql);
}
function result(actor, check, ok, detail, risk = 'High') {
  checks.push({ actor, check, result: ok ? 'PASS' : 'FAIL', detail });
  if (!ok) findings.push({ risk, actor, gap: check, evidence: detail });
}

async function main() {
  process.chdir(path.resolve(__dirname, '..'));
  const config = fs.readFileSync('supabase/config.toml', 'utf8');
  if (!/^project_id\s*=\s*"sentinel-aml"/m.test(config)) throw new Error('Expected sentinel-aml local configuration.');
  const inspect = JSON.parse(run('docker', ['inspect', CONTAINER]))[0];
  if (!inspect.State?.Running || !(inspect.NetworkSettings?.Ports?.['5432/tcp'] || []).some(p => p.HostPort === '55322')) {
    throw new Error('Expected the running local database on port 55322.');
  }
  const statusText = process.platform === 'win32'
    ? run('cmd.exe', ['/d', '/s', '/c', 'supabase status -o json'])
    : run('supabase', ['status', '-o', 'json']);
  let status;
  try { status = JSON.parse(statusText); } catch { throw new Error('Local status did not return JSON.'); }
  if (status.API_URL !== API) throw new Error(`Expected loopback API ${API}. Audit stopped.`);
  const publicKey = status.PUBLISHABLE_KEY || status.ANON_KEY;
  if (!publicKey) throw new Error('No local public key in status.');
  const report = {
    generated_at: new Date().toISOString(), api: API, checks, findings,
    scope: 'Local configuration and Data API reads. Login/logout can produce normal authentication audit records.',
    limitations: ['Does not test transaction posting, cash approvals, alert generation, reporting, or browser journeys.',
      'Empty business tables cannot establish isolation for those tables; these tests use known synthetic customer/account IDs.',
      'Fixture rules are not invented; absent active rules block meaningful scenario testing.'],
  };
  const snapshotSql = `SELECT json_build_object(
    'migrations', (SELECT json_agg(x) FROM (SELECT version,name FROM supabase_migrations.schema_migrations ORDER BY version) x),
    'transaction_triggers', (SELECT json_agg(x) FROM (SELECT t.tgname AS name,t.tgenabled AS enabled,pg_get_triggerdef(t.oid) AS definition FROM pg_trigger t WHERE t.tgrelid='public.transactions'::regclass AND NOT t.tgisinternal ORDER BY t.tgname) x),
    'rules', (SELECT coalesce(json_agg(x),'[]'::json) FROM (SELECT id,tenant_id,rule_name,condition_type,threshold_value,time_window_hours,status,mode FROM public.aml_rules ORDER BY tenant_id,rule_name) x),
    'account_columns', (SELECT json_agg(column_name ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND table_name='accounts'),
    'atomic_onboarding_rpc', (SELECT count(*)=1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='onboard_customer'),
    'account_status_values', (SELECT json_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e JOIN pg_type t ON t.oid=e.enumtypid JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typname='account_status'),
    'user_profile_constraints', (SELECT json_agg(pg_get_constraintdef(oid)) FROM pg_constraint WHERE conrelid='public.user_profiles'::regclass AND contype='c'),
    'staff_profile_inventory', (SELECT json_agg(x) FROM (SELECT u.email,u.raw_app_meta_data->>'role' AS auth_role,u.raw_app_meta_data->>'tenant_id' AS auth_tenant,p.role AS profile_role,p.tenant_id AS profile_tenant,s.role AS staff_role,s.tenant_id AS staff_tenant,s.is_active FROM auth.users u LEFT JOIN public.profiles p ON p.id=u.id LEFT JOIN public.user_profiles s ON s.id=u.id WHERE u.email LIKE '%@coreaml-local.test' ORDER BY u.email) x),
    'policies', (SELECT json_agg(x) FROM (SELECT tablename,policyname,roles,cmd,qual,with_check FROM pg_policies WHERE schemaname='public' ORDER BY tablename,policyname) x)
  );`;
  report.database = JSON.parse(query(snapshotSql));
  const localSetup = JSON.parse(fs.readFileSync('.coreaml-local/setup-results.json', 'utf8'));
  if (localSetup.api !== API || !Array.isArray(localSetup.fixtures)) throw new Error('Expected the local fixture setup report.');
  const syntheticCustomers = Array.from({ length: 12 }, (_, i) => fixtureId('b', i + 1));
  const syntheticAccounts = Array.from({ length: 12 }, (_, i) => fixtureId('c', i + 1));
  const fixtureRows = JSON.parse(query(`SELECT json_build_object('customers',(SELECT count(*) FROM public.customers WHERE id::text IN (${syntheticCustomers.map(id => `'${id}'`).join(',')})),'accounts',(SELECT count(*) FROM public.accounts WHERE id::text IN (${syntheticAccounts.map(id => `'${id}'`).join(',')})));`));
  if (fixtureRows.customers !== 12 || fixtureRows.accounts !== 12) throw new Error('Expected all 12 synthetic customer/account fixtures. Run the setup script first.');

  async function request(route, method = 'GET', body, token) {
    const r = await fetch(API + route, {
      method, redirect: 'error', signal: AbortSignal.timeout(30000),
      headers: { apikey: publicKey, 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return { status: r.status, ok: r.ok, data: await r.json().catch(() => ({})) };
  }
  const customerRoute = '/rest/v1/customers?select=id,tenant_id&id=in.(' + syntheticCustomers.join(',') + ')';
  const accountRoute = '/rest/v1/accounts?select=id,customer_id&id=in.(' + syntheticAccounts.join(',') + ')';
  const anonymous = await request(customerRoute);
  result('anonymous', 'Synthetic customers inaccessible without login',
    [401, 403].includes(anonymous.status) || (anonymous.ok && Array.isArray(anonymous.data) && anonymous.data.length === 0),
    { status: anonymous.status, returned_rows: Array.isArray(anonymous.data) ? anonymous.data.length : null });

  // Compliance users must see their own three fixtures and no other bank's fixtures.
  for (let bank = 1; bank <= 4; bank++) {
    const email = bank === 1 ? 'compliance_officer@coreaml-local.test' : `compliance_bank${bank}@coreaml-local.test`;
    let token;
    try {
      const login = await request('/auth/v1/token?grant_type=password', 'POST', { email, password: PASSWORD });
      if (!login.ok || !login.data.access_token) throw new Error(`Login failed (HTTP ${login.status}).`);
      token = login.data.access_token;
      const claims = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
      if (claims.app_metadata?.role !== 'compliance_officer' || claims.app_metadata?.tenant_id !== bankId(bank)) throw new Error('Unexpected JWT role or tenant.');
      const customers = await request(customerRoute, 'GET', undefined, token);
      const rows = Array.isArray(customers.data) ? customers.data : [];
      const own = rows.filter(row => row.tenant_id === bankId(bank));
      const foreign = rows.filter(row => row.tenant_id !== bankId(bank));
      result(email, 'Customer isolation between banks', customers.ok && Array.isArray(customers.data) && own.length === 3 && foreign.length === 0,
        { status: customers.status, own_rows: own.length, other_bank_rows: foreign.length, other_bank_ids: foreign.map(row => row.id) });
      const accounts = await request(accountRoute, 'GET', undefined, token);
      const ownIds = new Set(syntheticAccounts.slice((bank - 1) * 3, bank * 3));
      const accountRows = Array.isArray(accounts.data) ? accounts.data : [];
      const ownAccounts = accountRows.filter(row => ownIds.has(row.id));
      const foreignAccounts = accountRows.filter(row => !ownIds.has(row.id));
      result(email, 'Account isolation between banks', accounts.ok && Array.isArray(accounts.data) && ownAccounts.length === 3 && foreignAccounts.length === 0,
        { status: accounts.status, own_rows: ownAccounts.length, other_bank_rows: foreignAccounts.length, other_bank_ids: foreignAccounts.map(row => row.id) });
    } catch (e) { result(email, 'Isolation checks completed', false, e.message); }
    finally {
      if (token) {
        try { const logout = await request('/auth/v1/logout', 'POST', undefined, token); if (!logout.ok) throw new Error(`HTTP ${logout.status}`); }
        catch (e) { checks.push({ actor: email, check: 'Test session logout', result: 'FAIL', detail: e.message }); }
      }
    }
  }
  const activeRules = report.database.rules.filter(rule => rule.status === 'ACTIVE' && rule.mode !== 'SHADOW');
  checks.push({ actor: 'database', check: 'Active rules available for scenario tests', result: activeRules.length ? 'OBSERVED' : 'BLOCKED', detail: { active_rules: activeRules.length } });
  const disabled = (report.database.transaction_triggers || []).filter(trigger => trigger.enabled === 'D');
  if (disabled.length) findings.push({ risk: 'High', gap: 'Disabled transaction triggers require review', evidence: disabled.map(trigger => trigger.name), qualification: 'A disabled trigger alone does not establish a missed alert; the actual processing path still needs testing.' });
  const bankingClient = fs.readFileSync('core-banking.html', 'utf8');
  if (!bankingClient.includes('COREAML_ATOMIC_ONBOARDING_V1') || !report.database.atomic_onboarding_rpc || !(report.database.account_status_values || []).includes('PENDING')) {
    findings.push({ risk: 'High', gap: 'Atomic customer/account onboarding is not fully installed', evidence: { client_updated: bankingClient.includes('COREAML_ATOMIC_ONBOARDING_V1'), rpc_present: report.database.atomic_onboarding_rpc, pending_state: (report.database.account_status_values || []).includes('PENDING') }, qualification: 'Use the onboarding verification script and browser workflow to verify behavior; installation alone is not a passed scenario.' });
  }
  const mismatchedProfiles = (report.database.staff_profile_inventory || []).filter(user =>
    !user.auth_role || user.auth_role !== user.profile_role || user.auth_role !== user.staff_role ||
    user.auth_tenant !== user.profile_tenant || user.auth_tenant !== user.staff_tenant || user.is_active !== true);
  if (mismatchedProfiles.length) findings.push({ risk: 'High', gap: 'Synthetic staff profiles disagree with trusted Auth metadata or are inactive', evidence: mismatchedProfiles, qualification: 'Checks live profile rows rather than the older setup-report flags.' });
  report.summary = { pass: checks.filter(c => c.result === 'PASS').length, fail: checks.filter(c => c.result === 'FAIL').length, blocked: checks.filter(c => c.result === 'BLOCKED').length, findings: findings.length };
  fs.mkdirSync('.coreaml-local', { recursive: true });
  fs.writeFileSync('.coreaml-local/baseline-results.json', JSON.stringify(report, null, 2) + '\n');
  console.table(checks.map(({ actor, check, result }) => ({ actor, check, result })));
  console.table(findings.map(({ risk, gap }) => ({ risk, gap })));
  console.log('Summary:', report.summary);
  console.log('Report: .coreaml-local/baseline-results.json (no passwords, API keys, or session tokens).');
  console.log('FAIL and BLOCKED are useful audit evidence; no policies, triggers, or thresholds were changed.');
  if (report.summary.fail) process.exitCode = 1;
}
main().catch(e => { console.error('Baseline stopped:', e.message); process.exitCode = 1; });
