# Dedicated local concurrency peer

The native claim race needs two active synthetic compliance officers in the
fixture bank. If only one is available, the verifier stops before creating any
acceptance alerts.

Run from the CoreAML repository root:

```powershell
node .\scripts\test-case-claim-peer-setup.cjs
if ($LASTEXITCODE -ne 0) { throw 'Peer setup safety checks failed.' }
node .\scripts\setup-case-claim-peer-local.cjs
if ($LASTEXITCODE -ne 0) { throw 'Local peer setup failed; share the output.' }
node .\scripts\verify-case-claim-acceptance-local.cjs --headed
```

The setup is restricted to the existing `sentinel-aml` Docker project and local
API port 55321. It creates `case_claim_peer@coreaml-local.test` through Auth Admin
with a fixture marker in trusted app metadata, then sets that identity's trusted
profile to an active compliance officer in the fixture bank. It never edits a
different identity's role. A colliding email without the expected fixture marker,
bank and role causes a refusal. Repeat runs reuse existing ready peers.

The script obtains the configured Admin credential from the local gateway's
environment or service-role consumer configuration. Keys and the generated
random password stay in process memory. They are not printed, exported, or
added to frontend code. Requests refuse redirects and target only the known
local Auth service. Admin user creation confirms the synthetic email directly;
the script does not invoke invitation or email-sending endpoints.

The peer account is retained for subsequent local tests. The race uses
database-role sessions, so its random password does not need to be exported.
Interrupted setup can be resumed for the same marked fixture. No acceptance
alerts, claims, deposits, evaluations or filings are created by setup. Existing
profiles (other than this dedicated fixture), alerts, customer, account,
transaction and risk data are checked for changes.

Output: `.coreaml-local/case-claim-peer-setup.json`. Nine mocked safety tests and
JavaScript syntax checks passed during preparation; live Auth provisioning still
requires the local run. The acceptance suite separately creates two synthetic
alerts only after its prerequisites pass.

If the gateway does not expose a recognizable Admin key, setup discovers an installed or cached Supabase CLI, checks its help, and reads JSON local status in memory. It refuses credentials unless the reported API is exactly port 55321. No package download or raw status output is used.
