# Atomic review foundation — local installation

The inspected `propagate_network_contagion()` routine iterates customers with recent transactions without a counterparty match or tenant predicate. Its trigger fires for pending and approved reports. The installer preserves the routine but disables only its identified trigger, after checking the uploaded catalog fingerprint. This is a quarantine, not a replacement contagion model. It must not be re-enabled as a shortcut to restoring risk propagation.

## Decision contract

Only an active head-of-compliance profile whose trusted app metadata matches the database profile may load or decide a review. The maker must be a different user. Cases must have a canonical claim, matching bank/customer/owner/members and a submitted saved draft. Ambiguous legacy records are rejected rather than swept into a group.

QA requires every canonical member to be PENDING_QA_REVIEW. Approval closes exactly that group and its draft; rejection reopens that group and increments the draft revision. Stored detection details and evidence are not rewritten. Existing alert-trigger risk policy remains in place and may recalculate the linked customer's risk; this patch does not introduce a new scoring rule.

Executive review requires a PENDING_APPROVAL report with the canonical anchor, maker and exact case reference/member array in `report_data`. Approval records APPROVED for report preparation while leaving the alert group escalated and the draft submitted. Rejection records REJECTED and reopens only that group and draft. No account freeze, customer-risk action, XML creation, report archive, email or regulatory submission occurs as part of approval. A file download is not a submission receipt.

The server computes a SHA256 state token over the trusted reviewer/bank, claim, members, draft and report. Decisions lock the same customer/anchor advisory key as the installed case workflow, then claim, alert, draft and report rows. A changed state is rejected. Request UUIDs are locked separately, and exact retries return the original receipt. A request reused with different content is rejected. The mutation, immutable receipt and one audit event commit together; an audit failure rolls them back together.

The narrowly scoped public functions use SECURITY DEFINER because existing case/report records are server managed. They do not accept a caller-provided actor, maker, bank, member set, financial action or SQL expression. They verify `auth.uid()`, active database role and trusted app metadata, use an empty search path, and have PUBLIC/anon execution revoked. New receipt writes and direct authenticated report writes are denied. Existing RLS is not disabled or widened.

## Interface

The existing QA and executive modals fetch fresh server snapshots; list-row notes and encoded JSON are not decision authority. Record text renders as text. A lost response locks notes and the selected outcome, prevents modal dismissal/target switching and exposes exact retry. Definitive rejection requires reload. Success is shown only after the complete acknowledgement matches the request, actor, case and member set. No optimistic success or dispatch message is used.

Legacy direct report creation, PDF/archive writes and XML/email-dispatch handlers are removed or visibly unavailable. The existing workspace's review-submission/report-preparation action remains disabled. This foundation does not introduce a maker submission workflow; only canonical pending submissions are reviewable. The supplied inventory contains no pending reviews, so real signed-in pending-review acceptance requires separately prepared isolated fixtures after installation. Do not present this foundation as a completed regulatory filing product.

## Verification and installation

Run `node scripts/test-review-workflow.cjs`, then `node scripts/apply-review-workflow-local.cjs` from the existing local sentinel-aml project. The installer is restricted to its API and database container/port, checks reviewed trigger fingerprints, rechecks identical installed function bodies on repeats, and selects existing marked local maker/checker test profiles. It never provisions or reassigns an account.

Inside one installation transaction, probe cases with null customers and one report are created behind a savepoint, exercised using authenticated PostgreSQL roles, and rolled back before the schema commit. Probes cover role/bank rejection, stale state, exact replay, changed-payload rejection, QA approve/reject, executive approve/reject, direct-write denial and injected audit failure. Existing ledger, risk, evidence, profiles, claims, drafts, reports and audit hashes are compared before/after. No fixture or review decision persists.

`review-workflow-install.json` is a local database foundation receipt, not browser acceptance. The existing read-only `verify-intelligence-local.cjs --headed` remains applicable to the consolidated screens. The old completed claim/save/close acceptance fixtures are not reset or replayed.
