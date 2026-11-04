# Manual KYC browser verification

## Starting evidence

The local integration report dated 2026-10-22 has 23 passing checks with no
failures or blocked checks. The user's baseline retains nine passing bank-access
checks, no findings in that suite, and one AML scenario check blocked by an empty
active-rule inventory. These are local results, not hosted deployment evidence.

## Run

Keep the local Supabase stack and the application server running:

```powershell
# Separate terminal, only if the existing server has stopped:
Set-Location "C:\Users\Admin\Documents\Bex\CoreAML"
python -m http.server 5520 --bind 127.0.0.1
```

With the earlier manual-KYC and atomic-onboarding patches installed, run:

```powershell
node .\scripts\verify-coreaml-kyc-browser-local.cjs --headed
```

It reuses Playwright already installed in .coreaml-test-tools and installed Edge
or Chrome. No dependency reinstall, database reset or schema change is needed.
It refuses a different project ID and verifies the loopback backend URL before
entering login credentials. Network routing blocks hosted API requests and the
other local Supabase stack. Only the existing known static asset sources may load
outside the two selected loopback origins; requests to those asset hosts must be
HTTPS GET/HEAD. The script checks that no identity-provider calls were made.

The script creates two fresh synthetic applications through the actual onboarding
form. Random 11-digit BVNs are checked within the teller's visible bank; a database
uniqueness rejection triggers up to two more fresh submissions, so no previous
customer is deleted or overwritten. Both successful pending applications are
retained even if a later check fails. A fully successful run leaves both approved.
A rerun uses new references and applications.

## Browser checks

The expected successful summary is 22 PASS, 0 FAIL, 0 BLOCKED and zero uncaught
browser errors. Nine of these checks cover session cleanup and network boundaries
for the three actors; the remaining 13 cover the following login and product paths:

- Teller login and two actual onboarding submissions.
- Pending account lookup cannot populate the posting selection.
- Compliance officer login, directory review button and actual review modal.
- Both private signed-document links return successfully from local Storage.
- Missing attestations cause no approval RPC and leave the application pending.
- The officer fills manual evidence references and confirms the review.
- The test forwards one approval to the real local server, waits for its success,
  then deliberately aborts the browser response. It verifies that the database
  committed, the review fields stay locked and a reconciliation reference appears.
- Clicking the real approval button again sends the same payload/reference and
  confirms the original activation with exactly one stored review.
- Teller lookup recognizes the active account, without submitting a cash posting.
- An officer's PEP/adverse-media attempt is rejected, remains pending with no review,
  and unlocks the form for correction.
- Head-of-compliance login and approval through the actual form create a HIGH-risk
  review and activate that second zero-balance account.

The test makes synthetic manual attestations for software verification. It does
not validate any real person's identity, sanctions status, PEP status or documents.
The response-loss injection is intentional, not an application outage. The browser
may print an expected failed network request for that single interrupted response.
No console error is counted as proof of business failure by itself; check outcomes
and uncaught browser errors are reported separately.

The report at .coreaml-local/kyc-browser/results.json contains check details and
synthetic application references, with password/JWT/signed-token redaction on error
messages. It contains no session tokens or API keys. No screenshots are generated.
All opened browser sessions are signed out and contexts closed where execution
reaches cleanup. Failed dependencies are explicitly BLOCKED rather than silently
omitted. Stop on a failed/blocked result and inspect its detail before proceeding.

## Validation and limits

Before delivery, the script passed JavaScript parsing, its network-boundary/error-
redaction checks, selector checks against the application plus already-delivered
onboarding/KYC patches, and a controlled runner mock that exercised all 22 checks,
exactly two fixture applications, the committed-response interruption, unchanged
retry, head escalation, cleanup and secret-free reporting. The mock verifies the
runner's orchestration; it is not real browser or Auth/Storage/PostgREST evidence.
Full execution must run against the user's local stack. The 23-check integration
report remains the evidence for the backend workflow until that browser run passes.

Cash posting, AML detection/CTR rules and alert detail, persisted KYC rejection and
remediation, full admin workflows and hosted deployment remain outside this suite.


## Timing correction after the first local browser run

The first real run reported 10 PASS, 3 FAIL and 8 BLOCKED. A teller's initial
read returned “JWT issued at future”; the next synthetic application succeeded
in that same session. Head-of-compliance navigation timed out waiting for the
full page-load event, and officer sign-out returned “Failed to fetch”. No uncaught
browser errors were recorded. The report does not establish a KYC approval defect
or identify which machine/service clock produced the JWT timing error.

Run the dependency-free regression checks before rerunning the browser suite:

```powershell
node .\scripts\test-kyc-browser-timing.cjs
node .\scripts\verify-coreaml-kyc-browser-local.cjs --headed
```

The runner now performs an authenticated customer read after each login before
it declares the session ready. Only the exact future-issued-JWT error is retried,
up to eight read probes with 500 ms between them. Each probe's data request has
a five-second abort signal. Expired/invalid tokens, permission errors and network
errors fail this readiness gate immediately. Persistent future-issued errors also
fail and direct attention to Windows/Docker clock synchronization. No clock, token,
JWT verifier, policy or application behavior is changed; no business write is
replayed by this readiness logic. Recovered timing errors remain in diagnostics.

Navigation waits for DOMContentLoaded with a 45-second bound, then checks the real
form, module configuration, destination and session. It no longer waits for every
page resource to finish loading. This does not manufacture successful logins or
bypass application script requirements. A persistent load/network problem still
fails the suite.

Cleanup signs out only the current browser session. It retries only transient
network failures, at most three attempts, and checks that a browser session still
exists before each call. A missing session after an earlier failure is not accepted
as proof that server revocation succeeded. Persistent/definite errors remain failed
checks. This is separate from approval retries and cannot resubmit a business write.

The report includes safe diagnostics for readiness retries, cleanup attempts, failed
request paths and API error statuses. URL queries, headers and tokens are not logged.
Expected API denials (including the high-risk officer attempt) may appear in these
diagnostics and are judged by their dedicated checks. The intentionally interrupted
approval response is excluded from unexpected request-failure diagnostics. Diagnostic
arrays do not convert failures into passes.

Before delivery, dependency-free tests verified recovery from a single future JWT,
exhaustion after eight probes, no retries for other auth/permission/network errors,
transient cleanup recovery, persistent cleanup failure and refusal to infer logout
from missing local state. The controlled full-runner mock also reproduced a transient
future JWT plus one officer sign-out network failure and still completed its 22
checks through successful retries. These remain runner tests; the actual browser
rerun and environment diagnosis must take place on the user's local machine.
