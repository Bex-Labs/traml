# Final local draft/closure acceptance

This is the final planned acceptance stage for the installed claimed-case workflow. It changes no application code or schema. It deliberately saves and closes only the already retained synthetic group from run b4b94f13-5991-4436-8692-b19c8665b92c. It creates no new customer, alert, claim, financial transaction, evaluation or filing.

## Run

Keep the sentinel-aml local stack and app server at 127.0.0.1:5520 running. Apply the patch, then run:

1. `node scripts/test-case-workflow-acceptance-boundary.cjs`
2. `node scripts/verify-case-workflow-acceptance-local.cjs --headed`
3. If acceptance passes, `node scripts/verify-aml-browser-local.cjs --headed` for the final existing regression.

The browser run requires the existing successful installation report and six-pass read-only workspace report. It uses the same local officer login as previous browser verification; no Admin credential is read or exported. It uses the installed Chrome or Edge and existing Playwright package.

## What it proves

One actual form login supplies two same-officer tabs, which open the actual workspace using its Open Case buttons. Tab A saves the initial synthetic narrative. The harness receives a successful committed server response, then deliberately drops it before the page receives it. The page must stay unconfirmed until Save / Retry sends exactly the same request UUID and content. There must be one persisted save action and one save audit event.

Tab B opened at revision zero. Its stale narrative must receive a database revision conflict, remain visible locally and leave every database row unchanged. Tab A uses Save and Exit and Resume Draft to recover its confirmed narrative, pins, canonical anchor and case reference. Tab B then explicitly uses Reload Saved, accepting the visible confirmation.

Tab A saves the final synthetic narrative at revision two, then clicks Close Investigation and accepts the exact closure confirmation. Again, only a successful committed closure response is deliberately dropped. The workspace must lock editing and offer Retry Closure Confirmation without navigating away. The retry must use the same UUID and return the original receipt, with no extra audit. The closed case must reopen read-only with its final narrative and disabled save/close controls.

These are real browser requests to the installed local PostgreSQL functions. The successful final state is one retained draft at revision three/CLOSED, three action receipts (two saves and one close), and three additional workflow audit events. Both retained alert members are CLOSED. Their original details/evidence, claim receipt, customer/risk record and two risk-history rows must remain unchanged. No other alert is swept into closure. The reviewed risk policy still counts CLOSED alerts, so this synthetic customer remains 40/MEDIUM.

## Limits on writes and recovery

A phase-specific request boundary permits only the exact planned narrative, customer pin, expected revision, canonical alert ID and request shape. It permits one stale attempt and only the exact bounded retries for the initial save and close. Direct writes, claiming, other RPCs, Edge functions, external uploads, another local stack and unexpected destinations are blocked. The action phase is disarmed between steps and before cleanup. Normal local authentication and authorized reads remain available.

Before browser writes, the harness saves its complete synthetic-fixture baseline and hashes of all original tables. It journals requests/checkpoints before dispatch and after responses at `.coreaml-local/case-workflow-acceptance/<run UUID>/results.json`. It retains the final state even on failure and uses an exclusive local lock to prevent overlapping runs. It never deletes or resets a draft, receipt, audit event or fixture to force a clean result.

If a partially committed run fails, do not rerun it or recreate fixtures. Share its result file. A later invocation refuses to start when draft/action rows already exist; a crash-retained lock also requires inspection. If failure happened before any writes, the pristine-state check can still permit a new run after the previous lock was cleanly released. Reports from previous runs remain separate.

The older foundation installer and read-only workspace verifier expect a pristine open fixture. They are not the final regression after this deliberate closure and should not be rerun to restore it. The existing eight-alert browser verifier remains the final regression command.

## Preparation evidence

Seven boundary/reconciliation checks passed using the actual acceptance helper. Seven isolated PostgreSQL integration checks also passed using PGlite 0.5.12 with the actual installed SQL and the exact reconciliation queries; they cover save/replay, stale rejection, final revision, closure/replay and closed loading. The latter can be reproduced with `test-case-workflow-acceptance-postgres.cjs` and `COREAML_TEST_PGLITE_MODULE` pointing to that pinned package (or the standard `.coreaml-test-tools` package location). The native harness itself needs no new Node dependency.

These preparation checks are not a claim that the native browser acceptance has already run. Once the native acceptance and final existing regression pass, this draft/save/resume/closure workflow can be marked complete. Reporting/escalation, hosted deployment and other product features are separate work.
