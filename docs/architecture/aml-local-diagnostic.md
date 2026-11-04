# Local AML and CTR inventory before remediation

Run `node scripts/diagnose-coreaml-aml-local.cjs` against the existing local
Supabase Docker stack. No application server, browser or new dependency is needed.
The script checks sentinel-aml, the named database container and port 55322. Each
SQL inventory query runs in a READ ONLY transaction with bounded statement/lock
waits. It performs no evaluator calls, Auth logins, rule inserts, threshold tuning,
trigger changes, transaction replay or migration-history writes.

The report `.coreaml-local/aml-diagnostic.json` contains:

- Actual transaction triggers and enabled states.
- Configured rule identity, bank, target, condition, threshold, mode, action and
  allowlisted filter metadata, plus constraint definitions.
- Relevant function signatures, fingerprints, permissions and selected source
  markers. Source markers do not prove implemented behavior or correct execution.
- AML/outbox/archive policies and relation RLS flags.
- Outbox backlog and completeness counts, alert transaction-link/detail counts,
  archive row counts and realtime publication membership.
- Cron job names, schedules and active flags when cron.job exists. Cron commands
  and external worker processes are not inventoried.
- Transaction context restricted to the passed synthetic cash recovery fixture,
  when that report is available and its IDs/marker pass validation.

Function bodies, arbitrary function settings, cron commands, Auth credentials,
customer names and document paths are excluded. This is configuration/inventory
evidence, not rule execution, XML validation, regulator delivery or policy review.

The current dashboard source performs CTR archive metadata and CTR_AUTO_FILED
event writes in its realtime callback. That behavior depends on an open subscribed
browser and does not itself establish generated XML or accepted filing. The
observed code amount boundary is recorded solely as existing code, not adopted
as regulatory policy. The same callback contains a second client rule evaluator,
so a server replacement must also address duplicate/inconsistent client effects.

The historical engine source dispatches several condition types, while older
architecture documentation describes only one. This mismatch is why the next
fix must use current local inventory rather than assume the documentation is a
complete description. The amount evaluator source uses a strict greater-than
comparison; the diagnostic records the installed function's corresponding
operator marker when recognizable. Rule naming alone does not establish the
intended comparison or legal CTR requirement.

Empty active transaction rules remain BLOCKED; absent/disabled outbox capture
fails. Browser archive/event writes remain a finding. Pending receipts and an
archive database row are not promoted to evidence of completed evaluation or
report delivery. Historical pre-outbox transactions can legitimately lack receipts
and must not be automatically replayed because an aggregate count is nonzero.

Diagnostic FAIL/BLOCKED results exit 1 but still write the report. Missing
optional inventory sections are recorded explicitly. Run
`node scripts/test-aml-diagnostic.cjs` for dependency-free classification checks.
Inventory SQL was executed against the isolated PostgreSQL engine with baseline
schemas; actual installed local state must be obtained from the Docker run.
