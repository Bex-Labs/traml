# Existing-rule compatibility preview

This supersedes the synthetic three-rule preview as the next review step. It does
not install or enable a live AML engine. Do not apply
coreaml-aml-server-foundation.patch as a prerequisite.

## What is included

- A minimal snapshot of the five configured public.aml_rules records inspected
  on 2026-10-23. IDs, tenants, thresholds, modes and metadata are retained;
  author IDs and creation timestamps are omitted because evaluation does not use
  them. The source table is not updated.
- A pure Node server-side evaluator and a dependency-free synthetic regression
  suite. Run `node scripts/test-aml-rule-compatibility.cjs` with the existing
  Node installation. Expected: 58 passing checks. The suite writes only
  `.coreaml-local/aml-rule-compatibility.json` on the developer's machine.
- No network calls, Supabase login, SQL installation, scheduler, database records,
  financial postings, risk changes, archives or filing events.

## Preview semantics

| Configuration | Behavior |
|---|---|
| AMOUNT_ABOVE | Strict amount > stored threshold; BOTH remains both directions |
| VELOCITY_COUNT | CREDIT count >= stored count; current row included once |
| STRUCTURING_PATTERN | Current CREDIT below threshold, total CREDIT >= threshold, count >= 2 |
| DORMANT_ACCOUNT_ACTIVITY | Floor elapsed days since latest strictly earlier account transaction >= stored days |
| STATIC_THRESHOLD | Displays a GTE amount comparison only; always POLICY_REVIEW_REQUIRED, NOT_FILED |
| ACTIVE/SHADOW | Matches are ALERT_CANDIDATE/SHADOW_MATCH; neither creates records |
| Bank/global | Exact tenant or SYSTEM_GLOBAL; no bank-alpha to UUID mapping is guessed |

Rolling windows are inclusive [transaction time - window, transaction time].
Future rows, other accounts/banks and other currencies are excluded. Historical
channel filters match the current rule filter. CREDIT-only rolling rules reject
a triggering DEBIT, unlike the existing helper call path. History is deduplicated
by transaction ID; conflicting snapshots fail rather than pick one. Invalid
configuration is reported distinctly from a nonmatch. Money uses integer minor
units, not binary floating-point arithmetic. Evidence contains original rule and
transaction snapshots, a rule hash, window bounds and supporting transactions.

These are proposed computational semantics, not an adopted regulatory policy.
The structuring heuristic still allows prior above-threshold credits; its warning
states this limitation explicitly. A transaction-level preview cannot prove
structuring intent, reporting obligations or risk-model adequacy.

## Configuration decisions retained for review

1. CTR: the row has a 5,000,000 amount and 24-hour window but no explicit
   single-versus-aggregate basis, cash definition, currency or customer-type
   scope. Its title does not establish a current legal reporting threshold.
   No regulatory threshold is adopted in this preview.
2. Dormancy: five stored days versus thirty in the label. Calculation preserves
   five and reports the mismatch; no silent threshold edit.
3. Massive Outflow: BOTH includes CREDIT and DEBIT. Calculation preserves that
   value and reports the mismatch; no silent direction edit.
4. Velocity/structuring are account-scoped here, matching existing helpers.
   Customer-wide aggregation across accounts is a separate policy/design choice.
5. Equal-time dormancy records retain the existing strictly-earlier-time rule and
   produce a simultaneous-activity warning rather than invent an ordering.

## What is not proven

The supplied synthetic history arrays are complete only by construction. Before
live use, a database integration must prove authenticated scope, complete history,
consistent concurrent snapshots, retry/replay behavior, idempotent persistence,
atomic alert/risk writes, immutable evidence and failure recovery. This preview
is not connected to transaction posting or the cash outbox.

The hosted audit also confirmed disabled detection triggers, a missing risk
profile dependency in create_alert, rule-name-only lookup, overly broad table
policies and unguarded privileged functions. This patch does not remediate those
permissions, replace create_alert, or change hosted triggers. Those changes need
a separate local database integration and role-based verification.

The previous local database uses synthetic tenant UUIDs while the hosted rules
use bank-alpha and SYSTEM_GLOBAL. Do not import these rows into that database
and assume selection works without an explicit tenant mapping.
