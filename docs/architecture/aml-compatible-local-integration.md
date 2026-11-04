# Local integration of existing AML rule configurations

This patch follows the five-rule compatibility preview. It does not require the
withheld coreaml-aml-server-foundation.patch. It refuses an existing or partially
installed server foundation instead of overwriting it. It makes no hosted
Supabase changes and adds no migration-history entry or paid service.

## Rules, mapping and scope

The verified source snapshots remain in scripts/aml-compatibility/rules.json.
The integration preserves their IDs, names, conditions, amounts, windows, actions,
statuses and modes. A root-only seal derives mapped copies from the explicit map:

| Source tenant | Local evaluation tenant |
|---|---|
| bank-alpha | a1000000-0000-4000-8000-000000000001 |
| SYSTEM_GLOBAL | SYSTEM_GLOBAL |

The copies are stored in coreaml_compatible_sets, tied to a fresh completed
Synthetic/AmlCompatTestXXXXXXXX customer and its account. Source and mapped rules,
the mapping, engine version and set version are immutable and compliance-readable
within the customer's bank. The original local aml_rules table stays empty.
This avoids activating the legacy synchronous engine with incompatible rules.
No rules are imported into hosted Supabase or edited there. Other accounts and
prior outbox receipts are not evaluated. A manual worker handles this one set;
no scheduler or general-purpose production worker is installed.

CTR remains POLICY_REVIEW_REQUIRED for every transaction, with NOT_FILED evidence.
Its amount comparison is only a preview, not an adopted CTR policy. A processed
outbox receipt has status DONE for transport compatibility, but also the explicit
compatible_state POLICY_BLOCKED; its run is POLICY_BLOCKED. DONE alone must never
be interpreted as full AML clearance, filing or policy approval.

Five stored dormancy days remain five despite the thirty-day rule label. BOTH
remains both directions despite the Outflow label. Both generate configuration
warnings. Currency-separated credit windows, transaction-time bounds and the
legacy structuring heuristic follow the reviewed preview. The source records
lack an explicit currency filter; amount/dormancy rules therefore retain that
configuration. No statutory currency/threshold policy is inferred from names.

## Persistence and failure behavior

The Node evaluator computes proposed outcomes from a complete, bounded account
history snapshot. Amounts are decimal strings in snapshots. To avoid rounding
across time boundaries, this local fixture worker refuses submillisecond history;
the verifier explicitly timestamps its synthetic transactions to milliseconds
before registration. This limitation must be removed before a general live worker.
It bounds one account to 5000 history rows and one invocation to 100 receipts.

The commit function runs only as postgres in the named local database. It locks
account then receipt (matching cash account-lock order), checks causal receipt
ordering and recomputes the full snapshot before accepting outcomes. Changed
history gives a FAILED receipt with SQLSTATE 40001 and no partial detection.
Only an explicit failed retry may recalculate; attempts are capped at three.
A failed earlier receipt blocks processing later receipts for that set.

Run, per-rule evidence, linked alert, existing unified-risk trigger effects and
receipt completion commit atomically. Each transaction has one run and each rule
one result. Replaying the identical complete evidence returns the original run
without another alert or attempt. Two local worker processes exercise duplicate
commit handling; database locks and unique constraints protect persistence.
Node calculation outside the transaction may repeat, but financial posting does
not occur inside the worker.

The new private alert factory uses sealed rule IDs, current customer risk_tier,
and evidence rather than the removed customer_risk_profiles table or ambiguous
rule-name lookup. It writes detailed linked alerts directly into public.alerts;
the existing unified-risk trigger remains the authoritative score calculation.
The old public create_alert function is retained but browser execution is revoked.
Legacy transaction-detection trigger states are preserved. They are not certified
or enabled by this patch, and the legacy synchronous engine is not replaced.

An account-scoped history trigger seals evaluated transaction history against
updates/deletes and later backdated inserts. Future strictly later inserts remain
possible. Its SECURITY DEFINER scope is necessary to inspect registrations hidden
by RLS, including for a teller who cannot read compliance metadata; its search
path is empty and its execution privilege is revoked. Browser table UPDATE/DELETE
privileges on transactions are also removed. Existing noncash INSERT privileges
are retained, narrowed by a new bank boundary; cash still requires the existing
checked RPC. Full transfer/vault workflows remain separate verification.

## Bank permissions and browser behavior

New sets, runs and results permit same-bank active compliance reads. Transaction
reads require an active trusted staff profile in the account's bank. Browser
financial updates/deletes are denied. Existing customer/account bank guards from
earlier verified patches remain prerequisites.

Restrictive bank policies constrain legacy alerts, rules, archives and risk
history even when old permissive policies remain. Anonymous privileges are
revoked. Browser writes to rules/archives are denied. Automated alert fabrication,
delete and canonical evidence rewrites are denied; manual entity-review inserts
are bank checked and stamped, and QA narrative/status/severity updates remain
available to authorized compliance staff. Existing risk-history INSERT/manual-risk
flows are not claimed to be a complete governed override workflow.

Browser execute permissions are revoked from the old create_alert,
get_rolling_tx_stats, get_rolling_tx_volume and update_risk_tier endpoints. Rule
editing, archive creation and any UI action dependent on these endpoints require
a future governed backend implementation. The patch does not claim full isolation
of other AML tables such as investigations, STRs or loans.

The read-only diagnostic separately inventories legacy aml_rules and sealed
compatible copies; an empty legacy table does not imply absent hosted rules.
It retains unresolved policy/reporting findings.

The dashboard realtime callbacks now refresh views only. They cannot evaluate
rules, insert CTR archive rows or announce filing. Mocked execution checks this
actual callback; native browser alert/case rendering is a separate test.

## Run locally

Close dashboard/banking tabs first, to stop previously loaded browser evaluators.
Keep the existing local Supabase Docker stack running. No Python server or browser
is needed for this verification. Apply the new patch once, then:

    node scripts/test-aml-rule-compatibility.cjs
    node scripts/test-aml-browser-observer.cjs
    node scripts/test-aml-diagnostic.cjs
    node scripts/apply-aml-compatible-local.cjs
    node scripts/verify-aml-compatible-local.cjs
    node scripts/verify-coreaml-cash-local.cjs

The installer checks sentinel-aml, supabase_db_sentinel-aml and database port 55322,
verified synthetic staff/KYC prerequisites and unchanged role constraints and
existing trigger states. It installs docs/sql/aml-compatible-local.sql in one
bounded transaction. The snapshot tables exist after installation, but no rule
sets or cash test data are created until verification runs.

The verifier uses real local Auth, private document uploads, onboarding and manual
KYC for a NEW customer/account. It opens a dedicated zero till, posts eight cash
deposits and uses actual branch-manager approval for the large deposit. Before
sealing the set, it assigns deterministic synthetic transaction timestamps spanning
six days and the recent rolling window. It then runs two local worker processes,
checks evidence linkage, replay, real API bank/role reads and fabrication denials,
and uses fully rolled-back fault/retry and manual-review/QA probes.

Expected complete native result: 20 passing verification checks, including four
local Auth sign-outs and closing only the dedicated till. Expected persisted
fixture: 8 transactions, 8 runs, 40 results, 8 alerts, 8 policy-blocked runs, no
archive writes. Balance and till cash total are 15000004.01 NGN. Test customer,
documents, account, deposits, approval and evidence remain locally. Closing the
till administratively does not verify physical end-of-day cash reconciliation.

Report: .coreaml-local/aml-compatible-verification.json. Never automatically rerun
financial fixture creation after a failure; inspect the report and state first.
The separate manual worker can safely revisit the same registered set:

    node scripts/process-aml-compatible-local.cjs --set-id UUID
    node scripts/process-aml-compatible-local.cjs --set-id UUID --retry-failed

These commands do not create cash postings. A zero-work result proves only no
eligible receipts for that explicit set, not clearance of the wider backlog.

## Build-side validation and limits

- 58 dependency-free computational compatibility checks.
- 35 isolated PostgreSQL integration checks, including the exact installer,
  actual unified-risk function/trigger, RLS, stale snapshots, causal ordering,
  rollback/retry, shadow behavior and sealed evidence/history.
- 41 existing cash acceptance scenarios after the exact compatible installer,
  using baseline table/enum definitions and actual cash/recovery functions.
- Actual realtime-observer and diagnostic-classifier regressions.

The isolated SQL suites use an optional pinned PGlite dependency on the build
side. They are scripts/test-aml-compatible-sql.cjs and
scripts/test-aml-compatible-cash-regression.cjs. The normal user commands above
need no additional dependencies. Isolated PostgreSQL checks do not establish
native Docker, network transport, parallel execution or browser success; the
provided local verifier and existing cash verifier are authoritative for those
local database paths. Regulatory policy, reporting, sanctions, behavior/mule
models, production scheduling and full UI/admin workflows remain separate work.
