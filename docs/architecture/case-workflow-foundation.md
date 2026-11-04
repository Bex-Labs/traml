# Local draft and closure foundation

This patch installs database functions and rollback-only probes. It does not wire the dashboard buttons or claim a browser acceptance pass. Run only against the existing sentinel-aml local stack. No hosted project is changed.

## Behavior

`coreaml_load_case_draft(p_alert_id)` resolves either member of a claimed group to its original claim anchor. Only its active owning officer or a same-bank head of compliance can load it. The head and closed cases are read-only. Loading an unsaved case does not create a draft.

`coreaml_case_action(p_alert_id, p_action, p_expected_revision, p_request_id, p_narrative, p_snapshot)` accepts SAVE or CLOSE. Identity, bank, owner, anchor and group membership are resolved from the current profile, trusted app_metadata and immutable claim receipt. No officer or bank parameter is accepted. Functions deliberately run as the server owner to perform the authorized atomic writes; public and anonymous execution is revoked. Private helpers have no browser execution grants and use an empty search_path.

SAVE requires narrative text of at most 20,000 characters and a snapshot shaped as `{ "entity_ids": ["uuid"], "transaction_refs": ["reference"] }`. The server validates every reference within the same bank and derives entity labels itself. At most 100 entities and 200 transaction references are accepted, with a 128 KiB snapshot limit. Pinning a reference does not modify a ledger row or the detection evidence.

Each action requires the last acknowledged revision and a fresh UUID request reference. Reusing the same reference with identical content returns its original receipt. Reusing it with different content fails. A stale revision fails rather than overwriting newer work. Actions share the claim function's customer advisory lock and lock the receipt and ordered alert members. The subsequent dashboard integration must retain pending request references across uncertain responses, serialize saves, and wait for acknowledgement before showing Saved or navigating away.

CLOSE uses the already saved draft and requires at least 15 characters after trimming surrounding spaces. It changes only the statuses of the alert IDs in the claim receipt and closes that draft. It does not sweep all customer alerts or overwrite alert details with the narrative. The draft, action receipt and system event commit together. Audit failure or a member update failure rolls everything back. Existing risk policy includes CLOSED alerts; this patch preserves that policy, so this fixture remains 40/MEDIUM with its two original risk-history rows.

Direct browser draft writes are revoked. A restrictive read boundary additionally ties each draft to the matching claim anchor, tenant and owner. Claimed alert updates and deletes are server managed; browser TRUNCATE and trigger privileges are revoked. This is a local case workflow boundary, not an audit of all other application policies or reporting flows. Existing legacy direct save/close handlers are not the supported route after installation; dashboard integration follows the successful installation report.

## Installation and probes

Run `node scripts/apply-case-workflow-local.cjs`. It needs the successful retained report at `.coreaml-local/customer-linked-claim/b4b94f13-5991-4436-8692-b19c8665b92c/results.json` and the same two synthetic officers. It refuses changed trigger definitions, a changed ownership guard, an altered or closed fixture, or any existing draft requiring a separate migration. It reads no Auth Admin credential and creates no account, customer or alert.

DDL and probes run in one transaction with bounded statement and lock deadlines. Before committing DDL, the probes exercise load, save, replay, conflicting revisions, request-content mismatch, invalid pins, peer access, wrong trusted bank, direct writes, injected audit failures, closure and replay. Savepoints then remove every draft, action, closure and injected fault object. Table fingerprints and full retained fixture state must match before installation commits. Only schema changes persist. A repeated run validates function definitions and reruns the same rollback probes while drafts remain empty.

The result is `.coreaml-local/case-workflow-install.json`. A failure inside the installation transaction rolls back the DDL as well as probe writes. A later failure in the post-commit read check must be inspected before continuing. Do not rerun a fixture-creating acceptance command to work around a failure.

Run `node scripts/verify-aml-browser-local.cjs --headed` after installation for the existing read-only browser regression. That test does not save or close a case.

## Isolated developer verification

`test-case-workflow-postgres.cjs` runs the actual SQL and exact installation transaction using PGlite 0.5.12, including RLS and database roles. It covers the installation probes, repeat verification, cross-bank denial, head read-only access, disabled owners, canonical pin labels, stale edits, group-member failure rollback and preservation of risk state. Point `COREAML_TEST_PGLITE_MODULE` to a local installation of that exact package, or install it in `.coreaml-test-tools/node_modules/@electric-sql/pglite`. The local installer itself uses the existing Docker PostgreSQL helper and requires no new Node package.

Thirteen isolated PostgreSQL checks passed during preparation. Native local installation, real concurrent save/close sessions and signed-in draft/closure browser acceptance remain separate. There is no new filing, evaluation, monetary transaction or external webhook invocation in these probes.
