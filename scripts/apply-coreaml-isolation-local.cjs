// Applies the draft customer/account boundary ONLY inside the named local Docker DB.
// This intentionally does not alter remote projects or migration-history records.
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const CONTAINER = 'supabase_db_sentinel-aml';
const MIGRATION = 'supabase/migrations/20261021132503_tenant_isolation_guard.sql';
const sql = value => "'" + String(value).replace(/'/g, "''") + "'";
function run(command, args, input) {
  const p = spawnSync(command, args, { input, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (p.error || p.status !== 0) throw new Error(`${command} failed: ${p.error?.message || p.stderr || 'nonzero exit'}`);
  return p.stdout;
}
function query(text) { return run('docker', ['exec', '-i', CONTAINER, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres', '-At'], text); }
function bankId(n) { return `a1000000-0000-4000-8000-${String(n).padStart(12, '0')}`; }
const fixtureFilter = table => `${table}.id::text LIKE '${table === 'customers' ? 'b' : 'c'}1000000-0000-4000-8000-%'`;
function claimsFor(user, metadata = {}) {
  return { sub: user.id, role: 'authenticated', app_metadata: { role: user.role, tenant_id: user.tenant_id }, ...metadata };
}
function readAssertion(role, claims, expected) {
  return `BEGIN;
SELECT set_config('request.jwt.claims', ${sql(JSON.stringify(claims))}, true);
SET LOCAL ROLE ${role};
DO $test$
DECLARE customer_count integer; account_count integer;
BEGIN
 SELECT count(*) INTO customer_count FROM public.customers WHERE ${fixtureFilter('customers')};
 SELECT count(*) INTO account_count FROM public.accounts WHERE ${fixtureFilter('accounts')};
 IF customer_count <> ${expected} OR account_count <> ${expected} THEN
   RAISE EXCEPTION 'Expected ${expected} customers/accounts, got %/%',customer_count,account_count;
 END IF;
END $test$;
ROLLBACK;`;
}
function main() {
  process.chdir(path.resolve(__dirname, '..'));
  const config = fs.readFileSync('supabase/config.toml', 'utf8');
  if (!/^project_id\s*=\s*"sentinel-aml"/m.test(config)) throw new Error('Expected sentinel-aml local configuration.');
  const inspect = JSON.parse(run('docker', ['inspect', CONTAINER]))[0];
  if (!inspect.State?.Running || !(inspect.NetworkSettings?.Ports?.['5432/tcp'] || []).some(p => p.HostPort === '55322')) {
    throw new Error('Expected running local database on host port 55322. No change applied.');
  }
  const identities = JSON.parse(query(`SELECT json_agg(x) FROM (
 SELECT id,email,raw_app_meta_data->>'role' AS role,raw_app_meta_data->>'tenant_id' AS tenant_id
 FROM auth.users WHERE email IN (
 'it_admin@coreaml-local.test','head_of_compliance@coreaml-local.test','compliance_officer@coreaml-local.test',
 'bank_manager@coreaml-local.test','branch_manager@coreaml-local.test','teller@coreaml-local.test',
 'sales_rep@coreaml-local.test','bankmanager@coreaml-local.test','compliance_bank2@coreaml-local.test',
 'compliance_bank3@coreaml-local.test','compliance_bank4@coreaml-local.test') ORDER BY email) x;`));
  if (!Array.isArray(identities) || identities.length !== 11) throw new Error('Expected all 11 local synthetic users.');
  const total = JSON.parse(query(`SELECT json_build_object('customers',(SELECT count(*) FROM public.customers WHERE ${fixtureFilter('customers')}),'accounts',(SELECT count(*) FROM public.accounts WHERE ${fixtureFilter('accounts')}));`));
  if (total.customers !== 12 || total.accounts !== 12) throw new Error('Expected 12 synthetic customer/account fixtures before applying policies.');
  const original = query("SELECT coalesce(json_agg(x),'[]'::json) FROM (SELECT * FROM pg_policies WHERE schemaname='public' AND tablename IN ('customers','accounts') ORDER BY tablename,policyname) x;");
  fs.mkdirSync('.coreaml-local', { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  fs.writeFileSync(`.coreaml-local/policies-before-${stamp}.json`, original);
  query('BEGIN;\nSET LOCAL lock_timeout = \'5s\';\nSET LOCAL statement_timeout = \'60s\';\n' + fs.readFileSync(MIGRATION, 'utf8') + '\nCOMMIT;');
  const checks = [];
  function test(name, statement) {
    try { query(statement); checks.push({ check: name, result: 'PASS' }); }
    catch (e) { checks.push({ check: name, result: 'FAIL', detail: e.message }); }
  }
  for (const user of identities) {
    test(`${user.email}: customer/account visibility`, readAssertion('authenticated', claimsFor(user), user.role === 'it_admin' ? 12 : 3));
  }
  const officer = identities.find(user => user.email === 'compliance_officer@coreaml-local.test');
  if (officer.role !== 'compliance_officer' || officer.tenant_id !== bankId(1)) throw new Error('Unexpected officer fixture claims.');
  test('Anonymous customer/account reads denied', readAssertion('anon', { role: 'anon' }, 0));
  test('Missing tenant claim fails closed', readAssertion('authenticated', claimsFor(officer, { app_metadata: { role: 'compliance_officer' } }), 0));
  test('Empty tenant claim fails closed', readAssertion('authenticated', claimsFor(officer, { app_metadata: { role: 'compliance_officer', tenant_id: '' } }), 0));
  test('Malformed tenant claim fails closed', readAssertion('authenticated', claimsFor(officer, { app_metadata: { role: 'compliance_officer', tenant_id: 'invalid-bank-id' } }), 0));
  test('User metadata cannot grant admin visibility', readAssertion('authenticated', claimsFor(officer, { user_metadata: { role: 'it_admin', tenant_id: bankId(2) } }), 3));
  test('Cross-bank customer updates and tenant reassignment blocked', `BEGIN;
SELECT set_config('request.jwt.claims', ${sql(JSON.stringify(claimsFor(officer)))}, true);
SET LOCAL ROLE authenticated;
DO $test$
DECLARE affected integer; rejected boolean := false;
BEGIN
 UPDATE public.customers SET first_name='Should never persist'
 WHERE id='b1000000-0000-4000-8000-000000000004'::uuid;
 GET DIAGNOSTICS affected = ROW_COUNT;
 IF affected <> 0 THEN RAISE EXCEPTION 'Cross-bank customer update was allowed'; END IF;
 BEGIN
   UPDATE public.customers SET tenant_id=${sql(bankId(2))}
   WHERE id='b1000000-0000-4000-8000-000000000001'::uuid;
 EXCEPTION WHEN insufficient_privilege THEN rejected := true;
 END;
 IF NOT rejected THEN RAISE EXCEPTION 'Tenant reassignment was not explicitly rejected'; END IF;
END $test$;
ROLLBACK;`);
  const report = { generated_at: new Date().toISOString(), scope: 'Local customer/account restrictive policies; SQL role tests use the actual fixture identities; write probes are rolled back.',
    migration_draft: MIGRATION, migration_history_modified: false, checks,
    limitations: ['Transactions, alerts, profiles, other tables, views, RPCs, and service-role paths need separate authorization tests.',
      'Existing IT-admin cross-bank customer/account visibility is preserved.',
      'JWT changes require token refresh; active-session revocation and role governance remain separate work.'] };
  fs.writeFileSync('.coreaml-local/isolation-verification.json', JSON.stringify(report, null, 2) + '\n');
  console.table(checks.map(({ check, result }) => ({ check, result })));
  console.log('Policies applied ONLY to the local Docker database. Draft migration history has not been recorded.');
  console.log('Verification report: .coreaml-local/isolation-verification.json');
  console.log('Now rerun: node .\\scripts\\audit-coreaml-local.cjs');
  if (checks.some(c => c.result === 'FAIL')) process.exitCode = 1;
}
try { main(); } catch (e) { console.error('Local isolation step stopped:', e.message); process.exitCode = 1; }
