# Actual local cash forms

Prerequisites: the passed local cash database suite, passed head-of-compliance
browser result at `.coreaml-local/kyc-browser-head/results.json`, local Supabase,
application server on 127.0.0.1:5520, installed Edge or Chrome, and the existing
`.coreaml-test-tools` Playwright dependency. No additional installation required.

Run:

    node scripts/test-cash-browser-contracts.cjs
    node scripts/verify-coreaml-cash-browser-local.cjs --headed

The browser runner checks project/container/port, cash RPC existence, application
HTTP availability and the expected banking handlers before setting up fixtures.
It validates the completed synthetic KYC customer by its source report ID, bank,
first name and unique marker. It refuses an already open or discrepant teller
till. It creates a separate ACTIVE NGN account with zero balance and dedicated
zero-balance till as SQL test setup; account onboarding and till opening are not
claimed as browser-tested by this suite.

Actual banking login forms authenticate teller and branch_manager, check trusted
role/bank and confirm an authenticated read. The teller's real denomination form
posts a 10,000 deposit and 4,000 withdrawal, then queues a 5,000,000 deposit. The
manager cancels confirmation first (no review RPC), then clicks AUTHORIZE. A
second 5,000,000 request is REJECTED through the actual manager screen.

After each action, independent SQL observation checks both balances, transaction
reference/amount/direction/till/channel, unique outbox linkage, receipt status and
approval state. No cash action is performed by directly invoking a handler or by
calling the RPC from the harness. Reads/fixture setup are separate from UI actions.
Browser routing blocks unapproved destinations and unrelated database writes;
posted account/till/narration and reviewed approval IDs must match this run.

Success leaves three transactions and pending outbox receipts, one approved and
one rejected request, with net 5,006,000 synthetic account/till balances. These
committed rows remain for inspection. Cleanup administratively closes only the
new test till, retaining its balance and evidence. It does not manufacture a
physical cash count or assert successful EOD reconciliation. Existing tills and
accounts are not changed. If cleanup fails, the report records a failure; resolve
the fixture till before rerunning. Do not run alongside another teller session.

Report: `.coreaml-local/cash-browser/results.json`. Failures and dependency blocks
remain explicit. Sessions sign out through local Auth. Reports exclude passwords,
API keys, JWTs and credential headers.

The dependency-free contract test executes the real page handlers against a mock
SDK and exercises the evidence validator with inconsistent states. This does not
replace native browser execution on the user's local stack. This suite excludes
concurrency, lost-response cash retries, AML evaluation/CTR, EOD/vault operations,
double-entry accounting and production readiness. No schema or migration changes.
