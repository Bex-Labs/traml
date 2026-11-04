# Signed-in maker/checker review acceptance

This check uses the installed maker submission and review-decision functions through the actual local dashboard. It adds no product tabs, schema changes or filing capability.

## Prerequisites and scope

Keep the existing CoreAML application server available at http://127.0.0.1:5520 and the sentinel-aml API at http://127.0.0.1:55321. The other local stack on 54321 is blocked. The existing 13-check submission installation report and exact installed function bodies are checked before proceeding.

Three independent browser contexts log in through the actual form: the established marked local maker, one active marked head of compliance in that bank, and the established other-bank officer. Existing trusted app metadata must match active profiles. No account provisioning, password reset or profile reassignment occurs. The existing local test password is used; COREAML_LOCAL_PASSWORD can override it. COREAML_REVIEW_HEAD_PASSWORD and COREAML_REVIEW_FOREIGN_PASSWORD can override those individual test account passwords. Passwords and tokens are excluded from reports. All three login/profile checks finish before fixture creation.

## Controlled changes

The check creates two synthetic null-customer groups, each containing two alerts, one claim and a saved draft. Names and evidence carry the run marker. There are no customer, account, transaction, risk, evaluation or filing inserts. Setup holds transaction locks and compares unrelated state both before and after inserting; an unexpected setup side effect rolls back the entire setup transaction.

The actual UI then performs:

1. QA submission, deliberate loss of its committed response, navigation lock and exact UI retry.
2. Checker reading of the saved narrative, evidence pins and complete recorded detection snapshot, followed by rejection with feedback.
3. Maker feedback discovery, Resume returned case, one clarified draft save and resubmission.
4. Checker approval with another deliberately lost committed response and exact decision retry.
5. Maker reopening the closed case read-only with its final narrative preserved.
6. Executive submission and checker approval of one internal report preparation package. The draft remains submitted, the alerts remain escalated, and this is not a filing.
7. Signed-in other-bank direct report/receipt reads and review references being denied.

Every permitted mutation is armed with an exact expected payload. The first generated request UUID is bound to its phase before the network request is sent. Only the two planned lost-response phases permit a second request, with the same UUID and byte-equivalent JSON content. Request UUIDs cannot be shared across phases. Unarmed actions, claims, direct writes, other functions, RPC GET requests, other destinations and the other local stack are blocked. No startup readiness is forced, and the browser SDK and DOM are not mocked by the local acceptance runner.

## Evidence and stopping

Results are written under `.coreaml-local/review-acceptance/<run-id>/results.json`. The journal records identities before setup, requests before sending, observed responses and committed receipt/audit state. All original financial, evidence, risk, profile, case, report, draft and audit records are compared using hashes outside the precisely scoped fixture. Within the fixture, reconciliation checks exact state transitions, ownership, membership, immutable detection evidence, draft metadata, narratives, evidence pins, report content, receipt payloads and one audit per unique operation. Browser sessions are signed out through the server.

The two groups are retained for inspection. A durable fixture journal prevents a second run from silently creating more fixtures or replaying a partly completed workflow. Do not delete the journal, reset records or rerun a stopped acceptance; share the results for reconciliation. This also applies to a setup whose outcome is uncertain after a process interruption. An interrupted process may retain an active lock; inspect its report instead of removing the lock blindly.

## Validation boundaries

The boundary/reconciliation suite uses a synthetic model produced by isolated PostgreSQL, not records exported from the user's database. The seven planned transitions and their exact retries were executed against the actual installed SQL definitions in isolated PostgreSQL; altered-state probes were rejected. The native local runner still requires execution on the user's signed-in application and database. Passing its static/boundary checks alone does not establish signed-in browser acceptance or production/regulatory readiness.

Run:

```powershell
node .\scripts\test-review-acceptance-boundary.cjs
if ($LASTEXITCODE -ne 0) { throw "Acceptance boundary checks failed." }
node .\scripts\verify-review-acceptance-local.cjs --headed
if ($LASTEXITCODE -ne 0) { throw "Acceptance stopped. Share the report before rerunning." }
```
