# Local compliance browser startup diagnostic

## Why this diagnostic exists

The second browser run reports 11 PASS, 3 FAIL and 7 BLOCKED. Both teller onboarding
submissions and pending-account lookup passed. The compliance officer's customer
read hit its abort timeout. Head-of-compliance navigation reached dashboard.html
but did not complete DOMContentLoaded. Officer cleanup could not confirm server
revocation after a failed fetch cleared local session state. No uncaught browser
errors were recorded. Its request-failure list was empty; that does not rule out
requests that were still pending or work stalled before a request was emitted.

These results do not establish a KYC approval failure, a clock fault, an SDK fault,
a CDN fault or a local API outage. The 23 backend integration passes remain earlier
evidence; browser approval is still unverified. Do not increase timeouts or disable
authentication to label the full suite successful.

## Run

Keep local Supabase and the Python application server on port 5520 running. This
patch adds diagnostic scripts and documentation only. It changes no application
code or schema and requires no dependency installation or reset.

```powershell
Set-Location "C:\Users\Admin\Documents\Bex\CoreAML"
node .\scripts\test-browser-diagnostic.cjs
node .\scripts\diagnose-coreaml-browser-local.cjs --headed
```

Upload .coreaml-local/browser-diagnostic.json, including failed diagnostic checks.
The diagnostic intentionally reports failures rather than treating them as a KYC
verdict or manufacturing a passing summary. Do not rerun the full onboarding test
until this report identifies the failing path. Existing synthetic applications can
remain where they are; the diagnostic does not delete or approve them.

## What it does

The script requires the sentinel-aml project ID and reuses installed Playwright
and Edge/Chrome. It checks HTTP reachability of the selected application server
and API gateway. The unauthenticated gateway check may return 401; that establishes
HTTP reachability only, not valid authentication or authorization.

It handles compliance_officer and head_of_compliance sequentially, closing the
first browser context before creating the second. Each actor uses the actual login
form after the browser configuration is confirmed to use the selected local API.
Navigation waits for document commit as an observation point; this is not treated
as a completed application startup. DOMContentLoaded and application initialization
are separate checks that may still fail.

For a readable session with the expected trusted bank and role, it compares:

1. A Node HTTP read of one customer ID using that captured fixture session.
2. A direct browser fetch of the same endpoint without the SDK query builder.
3. A browser Supabase SDK read of the same endpoint.

Data reads have eight-second network abort signals. Browser evaluation stages have
separate bounds so an SDK or module stall does not prevent report creation. A timed-
out browser evaluation is not considered successful, even if it later finishes.
The underlying operation may complete until context cleanup; no business write is
involved. The script records JWT issuance/expiry timestamps and host UTC time,
without saving the JWT itself. Those values alone cannot identify a service clock.

Request records contain query-free URL paths, methods, resource types, start times,
response statuses and completion/failure times. They are capped at 200 per actor.
A separate pending-resource snapshot is taken before cleanup cancels outstanding
requests. Lifecycle events distinguish document readiness from load completion.
An empty failure list is therefore distinguishable from a list of unfinished work.

At cleanup, a captured fixture token is used for a bounded POST to the exact local
Auth logout endpoint with current-session scope. This avoids mistaking cleared
local storage for proven server revocation. Only a successful Auth response confirms
cleanup; failures remain failed checks. If no token could be captured, the report
explicitly states that server revocation could not be verified before context close.
It never signs out unrelated browser sessions globally.

Only Auth login/logout write state. No customer application, KYC approval, account
activation, cash posting, rule, migration or hosted-backend operation is performed.
Known HTTPS static assets retain the existing browser allowlist. Credentials are
held in memory, sent only to the selected loopback API, and excluded from report
fields and logged errors. No screenshots or browser traces are generated.

## How to interpret the next report

A Node request succeeding while browser requests fail points investigation toward
the browser/SDK/resource path; it is not proof of the exact cause. Direct browser
fetch succeeding while the SDK read stalls narrows the search further. Matching
Node and browser failures keep the local gateway, Auth and API path in scope.
Outstanding resource paths show which resources had not finished by cleanup; a
pending resource does not by itself prove it caused the application to stall.

The next fix must be based on those observations. The diagnostic cannot establish
that KYC approval, real identity/sanctions screening, cash posting, CTR detection,
detailed alerts or complete administration work end to end.

## Validation before delivery

Both scripts parse. Dependency-free regression checks cover bounded evaluation,
propagation of underlying failures, credential-bearing requests restricted to the
selected loopback targets, release of response bodies and preserved API errors.
A controlled runner mock reproduced a successful Node/direct-browser read plus a
failed SDK read, and a head dashboard with a pending resource/startup failure. It
verified that both actors still run sequentially, failures remain visible, captured
sessions receive local Auth cleanup, and report output excludes credentials. These
are diagnostic-runner checks, not actual local browser execution evidence.
