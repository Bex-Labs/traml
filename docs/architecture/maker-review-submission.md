# Saved-case review submission

The workspace now offers Request Dismissal Review and Request Executive Review. Both save current narrative/pins through the existing serialized draft session before sending the confirmed saved revision, canonical anchor, review kind and a request UUID. No client actor, bank, member list, report body, financial action or filing instruction is accepted by the submission RPC.

The actual draft session locks editing, closure and navigation during submission. An uncertain reply retains the exact request UUID, review kind and revision. Retry does not save newer content or issue a different outcome. An acknowledgement must match the original maker, bank, case, members and source/next revisions before the UI leaves the workspace. Save failure never sends submission. A definitive revision conflict preserves local work for reload. Another tab cannot write over the now-submitted server state.

## Server transition

- The installed case helpers verify active trusted officer identity, ownership, bank and canonical membership and take the existing customer/anchor lock.
- Only an IN_PROGRESS saved draft at the exact revision may submit. Its narrative and evidence pins are sealed server-side.
- Dismissal review changes only canonical member statuses to PENDING_QA_REVIEW, resets the current QA feedback fields for the new cycle and marks the draft SUBMITTED at the next revision. Historical review actions/audits are retained.
- Executive review changes canonical members to ESCALATED and marks the draft SUBMITTED. It creates one PENDING_APPROVAL review package using saved narrative, saved pins and exact canonical linkage. It is explicitly not a regulatory filing or generated statutory document.
- Submission receipt and audit commit with the group/draft/report changes. Report insertion or audit failure rolls everything back. Exact retries return the original receipt/package. A changed UUID payload or stale revision is rejected.
- The existing unsafe network propagation must remain in its verified disabled state. Existing alert-status risk-scoring triggers are preserved; this patch does not introduce account freezes, counterparty penalties or a new risk model.

A restrictive report policy is added because the existing permissive report policies did not isolate reads. Only the owning maker and head of compliance in the verified bank may read a package. Submission receipts have equivalent maker/head/bank SELECT scope and no authenticated write grant. Existing direct report-write denial remains in place. Server functions keep trusted-profile checks, empty search paths and restricted execution. Their narrowly scoped elevated execution is for atomic server-managed lifecycle transitions, not a permission-error workaround.

## Existing screens

Your submitted reviews is a receipt section inside Case Management, not a new tab or a second investigation workspace. It lists the latest submission revision per case, up to 50 cases, with current observed case/report state, sealed submission narrative and latest review feedback. Returned IN_PROGRESS cases resume through the existing canonical workspace. CLOSED cases open read-only. Pending/approved-for-preparation cases remain read-only. None of these labels establishes regulatory submission.

The reviewer modal now includes the saved evidence pins and complete recorded detection snapshot corresponding to its state token. Snapshot size is bounded at 2 MiB; oversized targets fail rather than silently truncate evidence. Record text is rendered as text. The existing fingerprinted review-context function is upgraded only from its known prior body or the exact new body. The older decision/receipt semantics and bank/reviewer checks are preserved.

## Local validation

`test-review-submission.cjs` exercises the service, actual serialized draft session and actual extracted dashboard navigation/submit handlers with mocked SDK/DOM. `test-review-submission-browser.cjs` runs the actual markup, session, handlers and receipt section in a browser with fictional SDK records and a Toast stub. Neither invokes Auth, a real database or a regulatory service.

`apply-review-submission-local.cjs` checks the installed review foundation, known case-helper bodies, trigger fingerprints and marked existing local actors. In one transaction it installs the schema/API/policy and runs rollback-only null-customer fixture probes. These cover maker/owner/bank rejection, saved-version conflicts, exact retries, QA return/resubmit/approval, executive package/approval, peer/foreign-bank read denial, report/audit fault rollback and refusal when propagation quarantine is altered. All probe records/fault objects roll back before schema commit. Before/after hashes cover existing financial, risk, evidence, profiles, cases, reports, receipts and audit records.

The isolated PostgreSQL tests and browser fixture checks do not constitute signed-in pending-review acceptance on the user's local stack. That remains the next gate after installation. Existing completed claim/draft/closure acceptance fixtures must not be reset or rerun. XML/report preparation, delivery and regulatory submission remain unavailable pending their own verified workflow.
