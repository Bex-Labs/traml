# Customerless alert risk guard and retained-run recovery

The exported local `unified_risk_scoring()` trigger runs after alert insertion
and status/severity changes. For a NULL `customer_id`, no customer row is found
and no customer is updated, but NULL old values compare as distinct from the
calculated baseline. The old function therefore inserts an orphan risk-history
row with NULL customer/previous values and a score/tier of 10/LOW.

The repair adds only an early return when `NEW.customer_id IS NULL`. It leaves
the customer-linked calculation, thresholds and history behavior unchanged. No
trigger is disabled and no historical rows are deleted.

## Apply locally

Close application tabs, keep the local Docker stack and port 5520 server running,
and run from the repository root:

```powershell
node .\scripts\apply-null-customer-risk-guard-local.cjs
if ($LASTEXITCODE -ne 0) { throw 'Risk guard installation failed; share the output.' }
node .\scripts\verify-case-claim-acceptance-local.cjs --headed --resume-run 0f27350e-d2be-4d65-8e4e-21401f52a907
```

The installer refuses to overwrite any risk function except the exact reviewed
original or repaired definition. It replaces the function and probes insertion
and actual claim execution inside one transaction/savepoint. Existing state and
all risk history must stay unchanged; otherwise the function installation is
rolled back. The probe is also rolled back before commit. Its output is
`.coreaml-local/null-customer-risk-guard-install.json`.

## Historical reconciliation

The retained acceptance run stopped before browser login or a race. Recovery
requires those two exact fixture alerts to remain unassigned, customerless and
unmodified, with no claim receipts/audit events. Exactly one orphan history row
per fixture reference must have the old trigger's NULL-to-10/LOW signature.

For that one comparison only, the two precisely identified orphan rows are
excluded from the hash. The result must match the original pre-insertion
fingerprint `c69f0d3ddc0ce194da9d9c9619ed4e01`, recovered from the retained failed
report supplied in the conversation. Any additional historical change blocks
recovery; the verifier does not accept a fresh baseline as evidence that the
failed run preserved state.

The orphan rows remain in the database. Subsequent checks include them in full,
so their mutation or any new orphan history is still a failure. Recovery reuses
the two old alerts, creates no new alerts, and writes a new result directory
with `resumed_from_run` and reconciliation details. The failed report stays
unchanged. If recovery fails, retain the result and do not repeat the default
fresh-fixture acceptance command.

## Validation

Thirteen isolated PostgreSQL/recovery checks pass using PGlite 0.5.12. They
reproduce the old defect, compare eight linked-customer scoring scenarios
between the original and repaired functions, test NULL insertion/status/severity
changes, execute the exact local installer probe, and reject unsafe recovery
accounting. The six acceptance-network-boundary checks still pass. Native local
installation and resumed browser/race acceptance remain to be executed.

Optional isolated test source: `scripts/test-null-customer-risk-guard.cjs`.
Supply PGlite via `COREAML_TEST_PGLITE_MODULE` or the existing test-tools directory.
The reviewed original SQL under `scripts/fixtures` is a test/precondition fixture,
not an installation script. Hosted Supabase is not modified by this repair.
