# CoreAML consolidated screens

The original intelligence release and its branding patch are superseded by integration into the existing application screens.

| Responsibility | Canonical location |
| --- | --- |
| Operational KPIs, team workload, triage and recent activity | Existing role-specific Command Center |
| Customer search, KYC status and review entry | Existing KYC & Identity directory |
| Identity, recorded risk and due diligence | Existing Customer 360 panel |
| Account balances, recent transactions and linked case shortcuts | Connected records inside Customer 360 |
| Risk-change history | Existing risk-history modal |
| Reference, direction, currency, amount and UTC date filters; ledger pagination | Existing Transaction Monitoring screen |
| Transaction evidence and evaluation detail | Detail within Transaction Monitoring |
| Claims, drafts, investigation, closure and approvals | Existing case workflows |

There is no separate Operations Overview, Customer Intelligence directory, Transaction Explorer tab, detection dashboard or second workload view. Previous saved `intelligence` routes restore Command Center. The compact recent transaction feed remains a five-entry dashboard summary; full search and inspection live in Transaction Monitoring.

## Data consistency

The monitoring table and its client-side heuristic KPI cards are replaced by the bounded ledger search, not retained alongside it. The old table marked all rows CLEARED and inferred engine activity from local sample calculations. The consolidated screen displays stored evaluation runs and evidence; missing results are explicitly unavailable rather than clearance. No new engine or rule is introduced.

Customer 360 is used by directory, case dossier and transaction links. It renders stored risk tiers/scores, including zero, and does not generate fallback identifiers, phone numbers, dates or PEP flags. A sanctions outcome is not inferred by this profile view. The directory also displays recorded risk rather than recalculating it in the browser. Recorded risk changes appear in the single existing modal; ID ordering is explicit because no chronology is assumed by the selected query.

Reads retain verified bank context, explicit parent tenant filters, nested customer joins on accounts/transactions, RLS, deadlines, bounded results and context-change rejection. User-editable metadata is removed from authorization fallbacks in the supplied Auth service. No schema migration, financial mutation, claim, draft, evaluation or filing is part of this patch.

## Validation

- `node scripts/test-intelligence-release.cjs`: shared data/model and read-boundary checks, including retained internal query utilities; this does not assert the removed overview UI exists.
- `node scripts/test-case-workflow-ui.cjs`: existing workflow contract checks with the consolidated transaction router mock.
- `node scripts/test-consolidated-ui-browser.cjs`: actual uploaded dashboard structure, extracted view router, and actual customer/directory/transaction controllers, using fictional SDK records and a Bootstrap surface stub. Requires installed Edge or Chrome and existing test Playwright dependency. This does not replace real Bootstrap/Auth/RLS execution.
- `node scripts/verify-intelligence-local.cjs --headed`: updated local two-bank read-only verification, existing records only, exact entry points, evidence inspection, foreign-record denial, cleanup and before/after state comparison.

The old `test-intelligence-ui-browser.cjs` command delegates to the consolidated UI check. Existing completed write-acceptance fixtures are neither reset nor replayed.
