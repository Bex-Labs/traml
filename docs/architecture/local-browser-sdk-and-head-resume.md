# Local browser SDK and head-review resume

## Evidence and change

The latest full KYC browser report has 19 PASS, 1 FAIL, 1 BLOCKED and no uncaught
browser errors. Actual onboarding, pending lookup, officer review, required manual
attestations, committed-response-loss recovery, same-reference activation retry,
active-account lookup and the officer's high-risk rejection all passed. The head
session failed loading config.js; request diagnostics identify a timeout fetching
its dependency https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm. Font
requests also timed out. No head approval was executed in that run.

config.js now imports the SDK from js/vendor/supabase-js-2.118.0.js. That checked-in
ES module has no external imports, so SDK startup no longer requires that CDN.
The previous URL was unpinned; the exact SDK version served during earlier runs
was not recorded. This change selects and pins SDK 2.118.0, rather than claiming an
identical prior binary. It needs the real local browser integration check below.

The bundle is built with esbuild 0.28.2 from exact package versions and a committed
lockfile under tools/browser-sdk. The generated manifest records its SHA-256 and
all bundled packages; the adjacent LICENSE.txt contains their license notices.
No node_modules, build executable or package-install step is required to serve it.
Only a maintainer rebuilding the bundle needs:

```powershell
npm.cmd ci --prefix .\tools\browser-sdk --ignore-scripts
npm.cmd run build --prefix .\tools\browser-sdk
```

All nine bundled packages have their versions and license identifiers recorded.
The build rejects external imports and missing package license files. This is
version and build provenance, not a claim of an independent dependency security
audit. Other existing CDN libraries and fonts remain external; font/asset problems
are still possible and are not converted into successful checks.

Login navigation waits for the destination document to commit, then verifies the
actual stored bank/role, an authenticated API read and the initialized dashboard's
matching role and KYC handler. It does not require every external page resource to
finish loading. UI readiness remains a real prerequisite with a bounded wait.
The exact local API/realtime CSP allowances and authentication/RLS checks remain
in force. Hosted/local backend selection, URLs and keys are not changed.

## Resume the existing high-risk application

Keep local Supabase and the Python server on 5520 running. After patch application:

```powershell
node .\scripts\test-browser-sdk.mjs
node .\scripts\verify-coreaml-kyc-browser-local.cjs --headed --resume-head
```

The resume mode reads the existing .coreaml-local/kyc-browser/results.json and uses
its High application's saved identifiers. In the report reviewed for this change,
that is account 8271605921, customer 60742276-92a6-4fb4-abb2-81d44d529cbc. Identifiers
and the fixture marker are validated; the database account/customer relationship
is checked again through the authenticated browser. A different bank is not used.

It creates no new applications. Four checks cover actual head login/API/dashboard
readiness, the saved application's pending zero-balance state, its review form and
private documents, and actual high-risk approval with confirmed activation. Three
more checks cover sign-out, network boundaries and absence of automated provider
calls. A successful resume therefore reports seven passing checks.

The result is saved separately at .coreaml-local/kyc-browser-head/results.json.
The original full-suite evidence is preserved. This is a focused continuation,
not a new 22-check full-suite result and not a new end-to-end AML certification.
If the saved application is already active, the pending-state gate fails and the
script does not submit another approval. Preserve a successful resume result;
rerunning the normal full suite later creates new fixtures as before.

These are synthetic manual attestations, not actual identity/sanctions checks.
The head-only run performs the one existing application's approval/activation if
its prerequisites pass; it makes no schema or rule changes, and posts no cash.

## Verification before delivery

The SDK module's SHA-256, named createClient export, local config import and empty
external-import list are checked by test-browser-sdk.mjs. It uses the real bundled
SDK with mocked HTTP to exercise session reads, PostgREST selection, RPC payloads
and Storage signed-link handling. It performs no real backend writes. Build output
is checked for reproducibility. Existing timing/cleanup regression tests still pass.

Controlled runner mocks exercise both the full 22-check path and the seven-check
head resume. The resume mock verifies one browser context, one existing application,
no new onboarding, high-risk activation and source-report evidence kept separately.
Patch application and JavaScript syntax are checked. Actual browser execution and
real Auth/Storage/PostgREST integration remain the user's next local verification.
