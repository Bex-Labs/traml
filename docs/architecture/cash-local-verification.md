# Local cash database verification

Run `node scripts/verify-coreaml-cash-local.cjs` with the sentinel-aml Docker
stack running. No npm installation, frontend server, or schema apply flag is
needed. The runner checks the project ID and database container's 55322 port.
It cannot target a hosted project.

Each independent scenario runs inside one SQL transaction, creates an account
attached to a completed synthetic local manual-KYC customer and a separate till,
then sets the authenticated PostgreSQL role and synthetic claims. All scenario
state rolls back, including deliberate profile changes and forced-failure
constraints. Existing customer/account balances are never used as test funds.
Errors close the psql session, which also rolls back its open transaction.
A previously verified manual-KYC fixture and the cash foundation must exist.

Checks cover ordinary deposits/withdrawals; exact and just-below 5,000,000
boundaries; manager approvals/rejections; replay prevention; active role,
account/currency/till checks; anonymous and cross-bank denial; own-request
approval even after role promotion; direct-write denial; and forced rollback
of account, till, transaction, approval and outbox effects. Each posting checks
both balances, transaction count and pending outbox receipts. Outbox presence
is not evidence of AML detection, CTR generation or filing.

The report is `.coreaml-local/cash-verification.json`; failures cause exit 1.
No policies, thresholds, migration history or schema fixes are applied.
A failure is useful evidence for the next targeted fix.

This verifies actual database functions and triggers, not browser/HTTP login,
concurrent execution, double-entry accounting, AML processing or production
readiness. Browser execution and concurrency remain separate acceptance steps.

Development validation: `scripts/test-cash-sql.cjs` optionally uses the same
PGlite dependency convention as `test-kyc-review-sql.mjs`. It executes the exact
scenario SQL against real cash-foundation SQL and extracted baseline table/till
trigger definitions. Its minimal surrounding schema does not reproduce every
policy or trigger in the user's local stack; the Docker run is authoritative.
