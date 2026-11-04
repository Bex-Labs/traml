# Local atomic claim foundation

This slice replaces the dashboard's separate alert sweep and audit insert with
`coreaml_claim_case(uuid)`. It is for the `sentinel-aml` local database only.

The function derives the officer and bank from an active trusted profile and
matching app metadata. A bank/customer advisory lock and ordered alert row locks
serialize claims. The transaction updates only ownership, status and case
reference, inserts a protected claim receipt and records the system event.
Repeating a completed claim by the same officer returns its original receipt.
An audit failure aborts all claim writes. Original evidence and detection reasons
are not overwritten.

The missing `alerts.case_reference` column is added. Browser roles cannot change
case ownership directly or forge claim receipts. Receipt reads require an active
same-bank compliance officer or compliance head. Existing detection triggers
remain installed.

## Installation and verification

Apply the patch, close application tabs, keep local Supabase and the port 5520
web server running, then run from the repository root:

```powershell
node .\scripts\test-case-claim-service.cjs
if ($LASTEXITCODE -ne 0) { throw 'Claim service checks failed.' }
node .\scripts\apply-case-claim-local.cjs
if ($LASTEXITCODE -ne 0) { throw 'Local installation failed; share the output.' }
node .\scripts\verify-aml-browser-local.cjs --headed
```

The installer checks the known local project and Docker database. It installs in
one transaction and runs an eight-check probe inside a savepoint using two
synthetic alerts without customer links. It rolls those alerts, claims and audit
events back before committing DDL. It checks existing alert, customer, account,
transaction and event state before committing. A failed probe rolls back the DDL
as well. A successful installer should not be rerun; use
`verify-case-claim-local.cjs` for a subsequent rollback-only probe.

`test-case-claim-db.cjs` is the isolated PostgreSQL test source. It uses PGlite
0.5.12, provided through `COREAML_TEST_PGLITE_MODULE` or installed separately in
`.coreaml-test-tools/node_modules`; it is not an application dependency. Twenty
checks passed in PostgreSQL 18.6/PGlite. Five actual-service/UI contract checks and
JavaScript syntax checks also passed during preparation.

The local Supabase stack uses PostgreSQL 17 and existing guards not present in
the isolated test. Its installer probe is still required. Multi-session races,
signed-in browser claiming and customer-linked claim side effects have not yet
passed native acceptance testing. The existing evidence-viewing verifier does
not click Claim and leaves all eight original alerts unassigned.

## Remaining workflow scope

Draft save/resume, closure, QA review, SAR/CTR creation and submission are not
implemented or validated by this slice. Existing closure paths and reporting
policies are unchanged. Proactive hunts that try to create alerts directly
remain subject to the existing evidence guard. Claims cannot split a customer
that already has an active investigation; adding newly arrived alerts to an
existing case requires a later explicit workflow. Hosted Supabase is unchanged.
