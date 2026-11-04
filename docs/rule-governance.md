# Rule governance and structured dismissal feedback

## Installation

Apply `coreaml-rule-governance.patch` after the review-page isolation fix. This release expects the reviewed local `sentinel-aml` database and the existing filing/workflow foundation.

1. Run `node scripts/test-rule-governance.cjs`. It uses the existing `scripts/filing-tests` PGlite dependency and an isolated database, not your running bank data. If that dependency is missing, run `npm ci --prefix scripts/filing-tests --ignore-scripts` first.
2. Run `node scripts/apply-rule-governance-local.cjs` from the project root. It checks the current review-function bodies, including Windows line-ending normalization; runs the same upgrade in a rollback probe; then commits and verifies it. A transaction-level check compares hashes of existing rules, alerts, accounts, customers, transactions, investigations, reports and review receipts. The installer briefly locks transaction writes and stops if the lock cannot be acquired within five seconds. It creates no active bank deployment.
3. Hard-refresh the dashboard with Ctrl+Shift+R. No Edge Function restart or database reset is required.
4. Open Rules & detection coverage from the existing rules card, or open `rule-governance.html` directly on the frontend server.

An installation journal is saved under `.coreaml-local/rule-governance/`. Preserve it and share the terminal output if installation stops. Re-running the matching installer verifies its function bodies; a different release or modified function fails rather than being overwritten.

## Existing rules and detectors

Existing `aml_rules` records and the behavioural, circular-layering, sanctions and custom-rule triggers remain unchanged. The queued compatibility evaluator found in the inspection is synthetic-account testing infrastructure; this release does not call it a production worker or mark its pending receipts as evaluated.

Legacy browser rule writes are disabled. The old builder opens the new governance page. Old rules keep their original parameters and evaluation behaviour. They are listed separately, without claiming they are equivalent to governed catalogue versions or that an enabled trigger proves screening quality.

New governed scenarios execute synchronously on newly inserted transactions. Their results are separate from the legacy evaluation outbox. No historical transactions are replayed or reclassified during installation. An active governed scenario can detect the same activity as an existing detector: both alert records remain available. Use the existing case grouping and review tools; this release does not suppress legacy alerts or rewrite detection evidence.

## Baseline catalogue and bank deployments

The shared catalogue contains version 1 of four scenarios: individual amount above threshold, credit velocity, multiple smaller credits with a combined threshold, and dormancy reactivation. These are monitoring scenarios, not statutory cash-reporting rules. No universal amount or regulatory threshold is supplied.

Each bank deployment specifies origin (baseline or custom), a catalogue algorithm/version, name, currency, direction, customer type, threshold and window. Baseline and custom origins share the validated algorithm implementations; custom does not mean arbitrary executable code. Amount and dormancy do not use the supplied window. Velocity and structuring are credit-only. Dormancy requires prior account activity; a first transaction is recorded as insufficient history.

Customer types come from the bank's existing customer records. ALL applies to every type. Catalogue releases require an administrator-reviewed database release; banks cannot edit the shared catalogue through the client. Catalogue publication does not change any installed bank version.

### Officer / Head demonstration

1. As the officer, open Propose a rule. Choose a baseline or bank custom origin, enter the bank-approved parameters and submit. The version is PROPOSED and evaluates nothing.
2. As a different Head, inspect the exact parameters and approve shadow testing with a rationale. Self-approval and cross-bank actions are rejected server-side.
3. Post representative fictional transactions through the existing transaction workflow in the test installation. SHADOW records matches, filtered rows, nonmatches and insufficient history without creating alerts. Use the existing transaction view to inspect the test activity; this page reports aggregate evaluation results.
4. Refresh as Head and review the test evidence. Activation requires at least one usable MATCH/NO_MATCH shadow evaluation, no recorded evaluation errors for that version, and a review rationale. This is a minimum software gate, not proof that a bank's validation programme is complete. Sampling, below-threshold testing and validation remain necessary according to the bank's policy.
5. Activate the approved exact version. Future matching transactions create alerts with the bank, deployment ID, catalogue version, parameters, comparison and transaction snapshot recorded in the evidence.
6. To change parameters, propose a new version. To replace an existing governed deployment, select its explicit replacement target at proposal time. Activation atomically pauses that target. No custom rule silently overrides a baseline. An identical active baseline scope cannot be duplicated. Currency, direction and customer type form its scope; overlapping ALL/BOTH and narrower scopes may both match and require review. Legacy rules cannot be selected as automatic replacement targets.
7. A Head may pause a running deployment with a rationale. Paused versions are not silently reactivated; resumption uses a fresh proposal, shadow test and approval. Older evidence and event records remain intact.

## Structured dismissal reasons

The officer's investigation workspace now has a dismissal-reason section. Choose a category and supply 15–4000 characters of supporting explanation. The existing saved findings and evidence requirements still apply.

Categories: legitimate activity, duplicate detection, source data error, rule calibration, detection defect and other. The category describes the officer's recommendation, not an automatic conclusion or a rule adjustment. The Head sees that submitted reason in the QA snapshot and independently approves closure or returns the investigation with feedback.

A dropped submission response retains the original request and reason for exact retry. The old unstructured API cannot submit new QA requests. The direct Close Investigation shortcut is hidden and new direct closure calls are rejected server-side; closure follows the independent dismissal review. Previously confirmed closure receipts remain replayable through the retained handler. Draft saves still delegate to that existing handler. Previously recorded submissions retain their old receipts and are shown as unclassified; a new call cannot add a retrospective category to an old receipt.

Feedback counts distinguish recommendations, approved dismissals and returned investigations. Officer scope covers their own structured submissions; the Head sees the bank's totals. Per-deployment approved-dismissal counts are attached to the alert IDs in recorded Head decisions, retaining the deployment's exact rule version and scope. Legacy alerts have no invented deployment lineage.

There is no automatic threshold tuning, customer whitelist, model retraining, account freeze, or risk reset. Existing status-dependent database triggers still run when the existing review function changes case/alert status.

## Coverage, precision and limits

- The page shows evaluator trigger configuration, active deployment count, last recorded evaluation and recorded errors. Zero active deployments is an explicit coverage gap. This is not an end-to-end health certificate for ingestion, legacy detectors, sanctions data or the entire AML programme.
- Windows use transaction event time, inclusive boundaries and committed account history available at insertion. Credits in other currencies/accounts are excluded. Same-time transactions already present are included. A backdated insertion does not recalculate earlier saved results; a controlled historical replay is a separate future capability.
- Transaction writes serialize on the account row. Governed history scans are bounded at 10,001 rows; exceeding the bound records an ERROR, not a nonmatch. Errors prevent activation and remain visible. An active evaluation failure records an error without blocking the banking transaction. This tradeoff needs monitoring in a production deployment.
- Numeric amounts use PostgreSQL numeric, and proposal amounts stay decimal strings in the browser. No FX conversion is inferred.
- The current UI shows the latest 200 deployments, 200 legacy rules and 200 governance events, explicitly labelled. It is not an unlimited audit export.
- A reduction in dismissed alerts does not establish better detection or fewer false negatives. Calibration requires representative evidence and controlled validation.

## Verification completed

Automated checks execute the actual upgrade and installer rollback/commit plan in isolated PostgreSQL (PGlite), real scenario evaluation and independent review functions. They cover bank and currency separation, structured dismissal, exact replay, scope filtering, replacement, permission boundaries and retained records. Client checks cover acknowledgement validation and the actual existing draft session's frozen reason on retry. Auth/SDK and DOM interactions in the client checks are mocked.

Signed-in local verification remains necessary with both accounts. Native browser visual verification was not completed in the build environment because no Chromium executable was available.
