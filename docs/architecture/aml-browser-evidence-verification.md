# Native browser verification of existing AML evidence

This patch adds a read-only Recorded Detection Evidence section to the existing
alert preview. It does not install SQL, rerun the worker, create cash postings,
claim alerts or change reporting policy.

## UI behavior

The queue's existing Review Case button opens the existing preview. Both preview
handlers now call the same evidence controller. It fetches one alert under the
signed-in user's normal RLS permissions, rather than attaching all evidence to
the queue download. For compatible detections, it separately reads the protected
evaluation state. Displayed fields include rule and transaction references,
recorded amount/direction/channel, comparison and thresholds, count/volume/window
or dormancy context, configuration warnings and NOT_FILED status. Recorded
supporting transactions and the full stored JSON are available in the panel.

Verify linked ledger entry performs another authorized SELECT and compares the
ledger ID, account, amount, currency, direction, channel, reference and timestamp
with the saved snapshot. A discrepancy requires reconciliation; an unavailable
or failed read never announces a verified match. This is a snapshot/ledger
comparison, not a new AML evaluation or regulatory clearance.

Every evidence value is rendered through textContent, including JSON and warnings.
Closing/reopening the modal clears prior evidence and invalidates late responses.
An inaccessible alert returns a generic unavailable message without revealing
whether another bank owns it. Legacy alerts without structured evidence are
explicitly labeled; the UI does not invent missing evidence or filing proof.
CTR POLICY_BLOCKED remains visible and no report is marked filed.

## Verification prerequisites

Keep the successful .coreaml-local/aml-compatible-verification.json from the
20-pass integration run. Its eight alerts must still be UNASSIGNED. The browser
verifier validates its UUIDs, synthetic customer marker, bank/account/set linkage,
eight stored alerts and NOT_FILED evidence against local SQL before logging in.
It does not reset changed statuses or create a replacement fixture on failure.

Use the existing local Supabase stack and installed Edge or Chrome. Playwright
uses the existing .coreaml-test-tools installation from prior browser checks.
Start the application's local Python server on 127.0.0.1:5520 if it is not already
running, from the CoreAML repository in a second PowerShell window:

    py -m http.server 5520 --bind 127.0.0.1

After applying the patch, in the original PowerShell window:

    node scripts/test-aml-evidence-ui.cjs
    node scripts/verify-aml-browser-local.cjs --headed

The first command has 19 dependency-free controller/service/boundary checks using
mocked SDK reads and a DOM stand-in. It verifies the actual source's evidence
linkage, missing/error/mismatch states, safe rendering and response-race handling.
It does not establish native browser success. Existing cash-handler, KYC-handler
and display-only observer contract checks also pass with the dashboard changes.

The second command uses actual browser login forms and backend sessions for the
first-bank compliance officer and another bank's officer in separate contexts.
It scans the actual queue pages, opens all eight fixture previews, verifies their
recorded fields/supporting lists and clicks the linked-ledger read button. It
then verifies the other bank's queue excludes those alerts and that a direct
preview reference and direct ledger SELECT cannot retrieve the protected data.

Browser network rules allow only the same bounded destinations used by prior
local checks. Before credentials are entered, the actual config must point to
127.0.0.1:55321. All database writes, RPC invocations (including GET), and Edge
Function invocations are blocked and retained as failures. Only local Auth
login/refresh/sign-out mutations are allowed. Local realtime endpoints are
observed separately. No credentials, request headers or tokens are put in the
report. Both browser sessions sign out through local Auth.

A read-only SQL fingerprint compares the existing fixture's customer, account,
till, transaction, alert, risk-history, run, result and receipt records before
and after. Global transaction/alert/archive counts and CTR_AUTO_FILED event count
must also remain unchanged. Local Auth session/audit changes are outside that
financial/evidence fingerprint. The verifier does not claim that every unrelated
table is covered or that all other application workflows are read-only.

Expected complete result: 14 passing browser checks, reviewed_alerts: 8,
zero failures/blocked checks and unchanged database state. No new screenshot
artifact is required. Report: .coreaml-local/aml-browser/results.json.

This verifies unassigned-alert preview and evidence reads. Claiming, investigation,
QA decisions, SAR/CTR filing, native admin workflows and regulatory policy remain
separate work. Hosted Supabase is not modified.
