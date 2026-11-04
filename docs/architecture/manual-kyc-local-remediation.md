# Manual KYC review and atomic activation — local draft

## Starting evidence

The user's browser report has 24 passes, no failures and no blocked checks for
11 logins, teller onboarding and pending-account lookup. Earlier local reports
show 18 onboarding checks, 14 staff checks and nine baseline access checks passing.
These results do not establish completed KYC, cash posting, CTR detection or full
admin correctness. The AML scenario suite has no active rules to execute.

## Defects found in the existing KYC screen

A failed verify-kyc request triggers invented identity data and a hard-coded 98%
confidence display. Watchlist clearance and checklist successes are static HTML.
A successful provider response has no completed rendering path. Approval directly
updates customers to COMPLETED and ignores whether its separate event write fails;
it never activates the linked pending account. The alternate performKYC function
also directly sets COMPLETED with no evidence review.

## Scope and meaning of the new workflow

This is explicitly a MANUAL_ATTESTATION workflow. The reviewer opens the two
private documents, records identity and sanctions/PEP evidence references, writes
review notes and confirms the checks. References identify evidence reviewed outside
this application; the application does not verify their authenticity. Nothing in
this patch performs government-provider verification, sanctions screening, malware
scanning, UBO checks or regulatory certification. Synthetic references in tests
must never be treated as real due diligence.

Only current, active same-bank compliance_officer and head_of_compliance staff can
approve; trusted JWT bank/role must match the stored profile. A reviewer who owns
either uploaded document cannot approve that submission, including after promotion.
This depends on onboarding's immutable document owner/path model, not a general
maker/checker framework for every legacy customer. Missing/unowned files, multiple
accounts, a nonpending state or a nonzero balance require reconciliation.

The database derives risk from explicit booleans, preserves higher existing scores
and HIGH tiers, and assigns PEP/adverse-media cases at least 75. HIGH/PEP cases
require head-of-compliance. The scoring rubric follows the existing UI's simple
weights; it is not a calibrated production AML risk model. It should be reviewed
before remote adoption.

A private SECURITY DEFINER helper is needed to update both records while avoiding
broad UPDATE rights on accounts. It checks the actor, current active assignment,
role, bank, documents, separation and input sizes explicitly, with an empty search
path. Its public RPC wrapper is SECURITY INVOKER. Anonymous execution is revoked.
Existing unrelated RPCs and tables remain outside this review.

The helper locks staff, customer and accounts, writes a bank-scoped review row,
completes KYC and activates the pending zero-balance account in one transaction.
A failed audit/customer/account write rolls everything back. Browser roles have
SELECT only on reviews, governed by RLS, with no insert/update/delete privileges.
The record includes reviewer, timestamp, evidence references, notes, flags, score
and document paths. This is access-controlled database evidence, not cryptographic
or administrator-proof immutability. Transition triggers reject completion or
pending-account activation without a corresponding review. Existing historical
customer/account states are not rewritten.

An identical reference/payload by the same reviewer returns the original outcome;
changed evidence or another review requires reconciliation. After an uncertain
browser response, the immutable request remains in memory and the form locks for
same-reference retry. A definite SQL rejection unlocks correction. Closing the page
loses this in-memory state, so retain the displayed review reference for manual
reconciliation. Successful retries after later account suspension deliberately fail
rather than reactivate it.

The UI removes the automatic provider call, all fabricated match data and static
clearances. It provides signed private-document links, manual evidence inputs,
unchecked confirmations and risk flags, an explicit approval button and a leave-
pending action. It reports success only after the RPC confirms ACTIVE. It does not
provide a persisted rejection/remediation case workflow yet.

## Local execution

Apply the patch, then run:

```powershell
node .\scripts\test-kyc-review-service.mjs
node .\scripts\verify-coreaml-kyc-local.cjs --apply
node .\scripts\audit-coreaml-local.cjs
node .\scripts\verify-coreaml-browser-local.cjs --headed
```

The runner refuses any project except sentinel-aml, the named Docker container
supabase_db_sentinel-aml exposing database port 55322, and API exactly
http://127.0.0.1:55321. It requires the prior isolation, staff and onboarding fixes.
It applies docs/sql/manual-kyc-activation.sql directly inside one transaction with
lock/statement timeouts and does not record migration history. This draft has not
been deployed remotely. A migration file still needs normal generation and review
before any hosted deployment.

The runner expects 23 passing checks and retains three synthetic applications:
one ordinary approval, one head-of-compliance approval, and one pending rollback
probe application. Its forced account-failure constraint and SQL write probes roll
back. It logs out all acquired sessions and saves secret-free results to
.coreaml-local/kyc-verification.json. Failed fixture creation explicitly blocks
its dependent tests. Request timeouts are 30 seconds. Review rows and evidence
references remain local.

## Validation and outstanding work

19 isolated PostgreSQL scenarios execute the real draft in PGlite 0.3.14 and verify
atomicity, reference retries, cross-bank/role/disabled/maker denials, document and
balance preconditions, high-risk escalation, malformed inputs, direct-transition
blocking, audit RLS/write denial and anonymous RPC denial. Reproduce with the
optional scripts/test-kyc-review-sql.mjs and its pinned dependency command.

The dependency-free service test also executes the actual dashboard handlers with
a small DOM/API stub: document links, required attestations, lost-response retry,
definite rejection recovery and confirmed-success announcements. Dashboard module
scripts parse; prior onboarding service tests remain passing. These checks do not
substitute for real local Auth/Storage/PostgREST or a browser run of the new review
form. The supplied local runner is the next integration gate. The existing browser
suite remains a regression test and does not cover manual KYC approval itself.

After integration, exercise the actual review form, then test cash posting and
explicit synthetic CTR/alert scenarios. Production-grade provider-backed evidence,
rejection/remediation, broader maker/checker guarantees, all legacy RPCs, complete
admin workflows, migration-history reconciliation and remote deployment remain
separate work.
