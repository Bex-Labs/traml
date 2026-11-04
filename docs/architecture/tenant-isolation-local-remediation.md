# Customer and account bank boundaries

## Evidence

The synthetic local baseline generated on 2026-10-21 shows each of four compliance
officers receiving HTTP 200 with three own-bank customers and nine other-bank
customers. Account reads returned the same 3 + 9 distribution. These eight failed
checks reproduce one systemic isolation defect across two tables and four banks.
Anonymous customer reads returned zero records. This evidence describes the local
migration-built environment, not the hosted project.

All five local transaction triggers in that report are enabled (`tgenabled = O`).
The rule inventory is empty. Neither fact establishes whether CTR generation works:
it needs explicit synthetic scenario rules and a transaction workflow test.

## Change

The draft migration adds a restrictive ALL policy to customers and accounts. Each
operation must pass an existing permissive policy AND this new bank boundary.
An authenticated customer row must match the tenant in trusted JWT app_metadata.
Account ownership is resolved through the account's customer. Both USING and
WITH CHECK enforce the boundary for existing and proposed rows. Anonymous callers,
missing tenant claims, and empty tenant claims cannot pass. User-editable
user_metadata is not used.

Existing IT-admin customer/account visibility across banks is preserved. Other
roles, including head of compliance and both manager naming conventions, remain
scoped to their own bank. This is tenant isolation, not a completed capability or
least-privilege redesign.

The migration changes neither grants nor existing permissive policies and adds no
SECURITY DEFINER function. Owner/service-role bypass, privileged RPCs and views,
other tables, role provisioning, token freshness, and deactivated sessions require
separate review. Authenticated business features that currently relied on reads
across banks may now expose underlying workflow assumptions; browser regression
testing is still required.

## Local application and verification

Run `node scripts/apply-coreaml-isolation-local.cjs` only in the CoreAML checkout.
The runner requires the named local Docker database on host port 55322 and the
11 known synthetic identities and 12 customer/account fixtures. It saves the prior
policy inventory, applies the draft SQL transactionally with lock/statement limits,
and checks all synthetic identities, missing claims, anonymous reads, metadata
spoofing, cross-bank updates, and tenant reassignment. Write probes roll back.

This iteration deliberately does not add a migration-history record. The SQL file
is a draft for review; do not push it remotely. Once local integration checks pass,
finalize the migration and reconcile local migration history as part of the next
engineering step. Do not reset the database or remove Docker volumes for this fix.

Then run `node scripts/audit-coreaml-local.cjs` again. The expected outcome for its
current checks is nine passes, zero failures, and one blocked rule-scenario check.
Authentication and scoped SQL tests do not prove browser or transaction behavior.

The two independent schema findings remain open: banking onboarding sends an
accounts.tenant_id column absent from the schema, and user_profiles rejects banking
roles. This patch does not pretend to resolve either.

## Validation before delivery

The migration was executed in PGlite 0.3.14, an embedded PostgreSQL engine, against
a minimal reproduction with the permissive customer/account policies from the
baseline. Checks reproduced the exposure before applying the migration and verified
the expected reads for all eleven fixture identities afterward. Additional checks
covered anonymous access, missing/empty/malformed tenant claims, forged user_metadata,
cross-bank updates, tenant reassignment, and repeat application. That test does not
include the full Supabase services or the application's complete trigger set. The
local runner executes the next integration checks against the user's actual stack.
