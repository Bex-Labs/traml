# Native customer-linked group verification

Run from the CoreAML repository root with local Supabase running:

```powershell
node .\scripts\verify-customer-linked-claim-local.cjs
```

This is database-only acceptance. The web server and browser need not run, and
the successful earlier browser/NULL-customer fixtures are not replayed.

## Guarded fixture creation

The verifier checks the current customer trigger definitions and risk function
against the uploaded reviewed contract. It checks the active alert-trigger
names and requires the two existing same-bank synthetic compliance officers.

Before any fixture write, a repeatable-read transaction checks the three Vault
settings used by the reviewed identity webhook. If all are present and nonempty,
setup refuses and rolls back. No settings are changed or exported. Otherwise,
the reviewed enqueue function takes its unconfigured return path, so the fixture
does not enqueue identity screening. The verifier does not disable triggers.

The retained fixture is one new synthetic INDIVIDUAL customer with PENDING KYC,
no account/BVN/NIN/contact documents, and two alerts inserted in separate
statements (HIGH then MEDIUM). The real risk trigger establishes 40/MEDIUM and two
history entries. No account, transaction, evaluation or filing is created.

Before committing the fixture, savepoint probes exercise group claiming, a
retry through another member, a second-officer denial, risk/evidence preservation
and injected failure on the second processed member. Probe claims/audits and the
temporary fault trigger/function are rolled back. Only the unclaimed setup
fixture and its expected risk history remain when setup commits.

## Native concurrency

The primary officer starts first. After its customer advisory lock is observed,
the peer attempts a claim through the other alert. The peer must be observed
waiting on that advisory lock while the first transaction is still open. One
owner/reference must cover both alerts; the peer must fail after the first
commit. This tests overlapping requests, not identical arrival timing.

The primary owner is retained so a later signed-in draft workflow can use the
existing primary test login. A group-member retry must return the same receipt,
with exactly one audit event and no customer/risk/history/evidence changes.

Per-table hashes preserve all pre-existing customers, alerts, risk history
(including retained NULL-customer rows), claim receipts, events, ledger,
evaluations, drafts, reports, archives and profiles. Only the newly generated
fixture's expected rows are excluded. Reports retain before/after hashes so a
failure identifies a table instead of only showing an aggregate mismatch.

## Results and scope

Results: `.coreaml-local/customer-linked-claim/<run-id>/results.json`.
Six top-level checks are expected on a complete pass. Preserve the result and
fixtures if anything fails; each new invocation would create a new isolated
fixture after prerequisites pass. There is no automatic destructive cleanup.

Preparation: the previous ten customer-linked/risk checks and ten additional
native-builder checks pass in isolated PostgreSQL/PGlite 0.5.12. Generated setup,
savepoint, fault injection and webhook refusal SQL is executed in that isolated
harness. Its schema is minimal; native guards and multi-session behavior still
require this local run. Optional test source is
`scripts/test-customer-linked-native-tools.cjs`, using the same PGlite test
dependency mechanism as the earlier checks.

This package adds verification files only. It does not install a permanent
schema/function change or modify hosted Supabase. Signed-in browser group
claiming, draft save/resume, controlled closure, QA and reporting remain outside
this database-only run.
