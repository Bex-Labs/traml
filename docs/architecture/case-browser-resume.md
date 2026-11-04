# Browser-only resume after a successful race

Run `9d5f7fca-6a85-4960-ab28-7ff5ad6df6e0` reconciled historical state,
preserved existing data and passed the two-session database race. Its browser
redirect/session/profile checks succeeded, but dashboard readiness timed out
while the document still reported `loading`. The previous empty pending-request
list was not evidence that networking was idle: the verifier had no asset
tracking wired into that diagnostic object.

This update adds document/script/stylesheet/font and local-API request tracking.
It records query-free paths, phases, HTTP statuses, elapsed times and failures,
plus sanitized console errors. It does not capture headers or request bodies,
stub assets, force handlers to boot or relax dashboard readiness.

It also adds a browser-only continuation mode:

```powershell
node .\scripts\test-case-browser-resume.cjs
if ($LASTEXITCODE -ne 0) { throw 'Browser resume checks failed.' }
node .\scripts\verify-case-claim-acceptance-local.cjs --headed --resume-browser-run 9d5f7fca-6a85-4960-ab28-7ff5ad6df6e0
```

Keep local Supabase and the port 5520 server running. No schema installation or
peer setup needs repeating. Resume requires the previous successful race and
state-preservation checks, matching fixtures and winner, and no earlier browser
claim attempt. The browser fixture must still be unassigned. The race fixture
must have its expected receipt, audit count and owner, and remain unchanged.

Historical reconciliation against the original pre-insertion fingerprint is
still required. Both retained orphan history rows are preserved. No new alerts
are inserted and the race is not rerun. The remaining permitted browser write is
the claim RPC for the existing browser fixture, plus login/logout operations.

The new report explicitly references the prior race run and labels its race
check as preservation of a previous result, not a fresh concurrency test. A new
result directory preserves both older reports. If startup fails again, attach
the new report instead of resetting fixtures or running fresh acceptance.

Seven mocked resume/asset-diagnostic checks and JavaScript syntax checks pass.
Native browser completion remains pending. This update does not identify or
repair the underlying stalled startup asset by itself; it captures the evidence
needed if the issue recurs. Drafting, closure and reporting remain separate.
