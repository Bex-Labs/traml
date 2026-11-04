# Install the absent cash foundation in local Docker

The local catalog showed neither cash RPC, neither foundation table, and no
cash guard/outbox triggers. Applying a Git patch previously added source files;
it did not install their SQL into the local database.

Run `node scripts/apply-coreaml-cash-local.cjs`, then
`node scripts/verify-coreaml-cash-local.cjs`. The installer targets only the
sentinel-aml project and supabase_db_sentinel-aml container mapped to port 55322.
No remote URL or project argument is accepted. No migration history is written.

It uses the checked-in historical cash foundation, requiring its exact SHA-256
with CRLF normalized to LF. It omits that file's superseded staff role-constraint
replacement. The verified local staff constraint stays intact. Cash RPC bodies
run in coreaml_private, with public security-invoker wrappers and explicit
execution grants. Existing role/tenant/account/till validation remains intact.

DDL applies in one transaction with bounded lock/statement waits. Any missing
fixture, failed prerequisite or SQL error rolls back the entire installation.
The installer refuses existing or partial foundation tables/RPCs. Existing
transaction triggers retain their enabled/disabled state; no AML engine is
enabled or disabled. The installation creates no cash postings or customer data.
It installs the foundation's approval/outbox tables, cash RPCs and cash/till/vault
controls. Verification creates only rollback fixtures, separately.

The verifier now stops before scenarios if required foundation objects are
missing. A successful install is not a cash acceptance pass; run and inspect
all acceptance checks against the actual local stack.
