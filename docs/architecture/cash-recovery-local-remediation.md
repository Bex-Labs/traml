# Confirm cash operations after a lost response

The local concurrency report passed all five races with two workers observed at
each barrier. The source-handler response-loss probe exposed two separate gaps:
an uncertain commit was announced as a failure, and a retry generated a new
reference. The probe produced two simulated postings and did not post real cash.

This local draft adds a private result table keyed by request reference, with
actor, bank, immutable payload and original outcome. The receipt and original
posting/approval request commit atomically. A reference advisory lock precedes
the existing account/till locks. Active role and bank are checked on every call;
a different actor or payload cannot reuse the saved result. New attempts still
pass the original account/till/currency/funds validations. A confirmed original
attempt can be read after its till closes; this does not authorize a new posting.

Public RPC signatures remain unchanged and security-invoker. Privileged wrappers
and result storage stay in coreaml_private. Browser roles cannot read/mutate the
result table or execute the renamed historical bodies directly. The original
cash/till/outbox and KYC controls remain in place. The local installer applies
all DDL in one transaction, preserves staff constraints and existing transaction
trigger states, and does not write migration history. It refuses a repeated or
partial recovery installation rather than overwriting it.

Unchanged posting retries now return the same result successfully. Pending cash
request confirmation also returns its current approval status. Repeated manager
decisions by the original reviewer return the original transaction or rejection;
an opposite decision or another reviewer is refused. Accordingly, the updated
concurrency suite requires both identical submissions/approvals to return matching
results while leaving one operation. Distinct competing withdrawals and opposing
manager decisions still require exactly one winner.

The cash page saves a user/bank-scoped attempt in sessionStorage BEFORE sending.
Unknown outcomes retain the frozen payload and locked fields. Confirmation uses
the same reference. A tab reload restores that attempt, including when no open
till remains. Malformed persisted state blocks posting for reconciliation. A
fresh definite SQL rejection unlocks correction; a prior uncertain attempt is
not discarded merely because a later authorization/readiness error occurs.
The UI checks matching response references and IDs before announcing success.
Manager uncertainty preserves the same decision and disables the opposite
button until confirmation. The manager page does not reload its queue while
that decision is uncertain. Its in-page decision lock is not persisted across
reload; after reload the queue reflects server status instead.

Install and verify, with banking tabs closed until SQL installation completes:

    node scripts/apply-coreaml-cash-recovery-local.cjs
    node scripts/test-cash-recovery-handlers.cjs
    node scripts/test-cash-browser-contracts.cjs
    node scripts/verify-coreaml-cash-retry-contract.cjs
    node scripts/verify-coreaml-cash-local.cjs
    node scripts/verify-coreaml-cash-concurrency-local.cjs
    node scripts/verify-coreaml-cash-browser-local.cjs --headed --check-recovery

The SQL draft is shipped at docs/sql/cash-recovery-local.sql and requires no
historical migration filename. No further npm installation is needed for the
normal Docker/browser runs. Local Supabase and the application server on port
5520 are required for the browser run. The optional isolated SQL engine follows
the existing .coreaml-test-tools convention in test-cash-sql.cjs.

The recovery browser mode drops successful local responses AFTER actual server
commit for an ordinary deposit, high-value request, manager approval and manager
rejection. It checks locked controls, restoration after reload, unchanged retry
payloads, original IDs, balances, transactions, outbox receipts and decisions.
Success leaves two synthetic transactions/receipts, one approval and one rejection,
with account/till balances of 5,010,000. It closes only the dedicated fixture till.
Its report is .coreaml-local/cash-browser-recovery/results.json, preserving the
prior normal browser report. Recovery mode has 18 checks including cleanup.

Build validation: the complete local installer transaction and 41 SQL scenarios
passed in isolated PostgreSQL/PGlite. Actual source-handler tests cover uncertain
responses, reload, duplicate UI submits, malformed results, storage failures and
manager decision recovery against mocked SDK/storage. Native concurrent Docker
and browser recovery verification must run on the user's stack; no such run is
claimed from the build container.

The result table is not backfilled from historical postings: old references
without saved actor/payload evidence require reconciliation, not automatic replay.
Clearing browser storage, using a new tab/session with no retained attempt, or
manually creating a new reference represents a new request. This is operation
idempotency, not automatic detection of every duplicated business instruction.
No automatic mutation retries were added. No AML evaluation, CTR filing, real
identity checking, vault/EOD reconciliation or double-entry accounting is claimed.
