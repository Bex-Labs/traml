# Concurrent cash and response-loss regression checks

Run the existing local Supabase stack. No application HTTP server or browser is
needed for these checks. Do not run other banking sessions while test tills are
being created. This patch changes verification code only.

    node scripts/test-cash-concurrency-contracts.cjs
    node scripts/verify-coreaml-cash-concurrency-local.cjs
    node scripts/verify-coreaml-cash-retry-contract.cjs

The concurrency runner requires the passed head-browser report and validates its
synthetic completed customer, bank and marker against the actual database. It
checks the local project, named Docker database, port 55322, installed cash RPCs
and active fixture profiles. No remote target is accepted.

Each race uses a new synthetic account and till. The withdrawal race starts with
100 units of synthetic opening balance; others start with zero. Dedicated account
and till rows, cash transactions, approvals and pending receipts remain locally.
Cleanup closes only those test tills, without claiming physical EOD verification.
Fixture IDs and starting balances are recorded in the report.

Two independent psql sessions set unique application names and wait on a shared
advisory lock held exclusively by a coordinator. The observer must see BOTH
workers waiting at once in pg_stat_activity before releasing the lock. Shared
locks then permit both worker requests to proceed; the application account/till
and approval row locks determine the winning request. Failure to reach the
barrier fails the scenario rather than treating sequential execution as a pass.

The five races check:

- Identical ordinary deposit reference: one success, one duplicate-key rejection.
- Distinct 80-unit withdrawals from 100: one success, one insufficient-funds rejection.
- Identical high-value reference: one pending approval, no posting.
- Two manager approvals: one posting and one unavailable-approval rejection.
- Approve versus reject: exactly one terminal decision, with funds matching it.

Each scenario checks balances, transaction sums, references, till/channel and
one pending outbox receipt per transaction. It records worker outcomes and closes
its own test till. Expected failures must match the anticipated SQL error; an
unrelated permission/schema error fails the race. Native parallel execution
requires the user's Docker stack and has not been run in the build container.
Report: `.coreaml-local/cash-concurrency.json`.

The retry probe executes the actual page's cash submit handler against a mock
SDK. A simulated server commits the first request but loses its response. The
second submit must preserve the first reference and leave one simulated posting.
It also checks that uncertainty is not announced as a definite cash failure.
There are NO browser, HTTP or database writes in this probe. It is not a native
browser or database idempotency pass. Report:
`.coreaml-local/cash-retry-contract.json`.

The current handler fails both retry checks: it announces a cash failure and
creates a new reference on every submit. The probe deliberately returns exit 1
and preserves those findings. Do not change its assertions to accept duplicate
postings. A follow-up fix needs a retained immutable attempt, a definite versus
uncertain outcome distinction, and authoritative confirmation of the same server
operation. The current SQL foundation rejects duplicate references rather than
returning a confirmed original result, so a complete recovery fix spans client
and server behavior.

These checks do not establish AML evaluation, CTR filing, full vault/EOD flows,
HTTP concurrency, or production readiness. No migration/history/policy changes
are applied by this patch.
