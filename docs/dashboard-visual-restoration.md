# Dashboard visual restoration

This follow-up corrects the previous patch's replacement of the familiar layouts. Apply it on top of the installed admin-manager release. Do not reverse that release or reapply the original backup.

## Restored appearance and navigation

- The manager page uses the original coreAML white header, blue sidebar, typography, red accents, Executive Risk Exposure heading, four KPI cards and the original risk-tier and industry chart panels. The PDF control uses the browser's print/save-as-PDF dialog for the visible oversight snapshot.
- Case progress, transaction and compliance-team tables sit inside that original shell. Lists retain search, pagination, refresh and dedicated details with Back navigation. The sidebar selection follows the active view. KYC and other restricted actions do not acquire new permissions.
- Administration again uses the original BexAML Admin dark header/sidebar and the original separate management URLs. Platform Health retains its card-based overview and administrative activity area. Tenant, user, role and audit pages use the same familiar shell.
- Health cards show measured directory reachability, institution count and administrative-request count. The old hardcoded deployment/health claims and transaction-injection controls are not reintroduced. Historical custom roles remain inventory rather than claims of enforced permissions.
- The user directory again offers CSV export, explicitly scoped to the currently loaded visible page. Exported fields are quoted and potential spreadsheet-formula prefixes are escaped.
- Detailed records and forms retain full-page space. Vertical scrolling uses the main browser scrollbar; wide tables can scroll horizontally on small screens.

## Permission preservation

Existing authentication, active-profile/session checks, bank boundaries, staff-management scope, storage restrictions and Edge handlers remain installed. The correction does not change existing permission function bodies or RLS policies, assign roles, invite users, alter balances or restore direct customer-data access to managers/admins.

One new read-only RPC supplies the aggregates needed for the original manager charts. It calls the installed manager authorization boundary, queries only the actor's bank, exposes no customer identities or findings, and groups the largest 12 industries separately with the remainder combined. The LIVE completion card counts only LIVE drafts currently recorded REPORTING_COMPLETED; TEST stages remain separately visible. These entries are recorded workflow outcomes, not independent regulator confirmations.

## Install

```powershell
Set-Location "C:\Users\Admin\Documents\Bex\CoreAML"
$patch = "$env:USERPROFILE\Downloads\coreaml-dashboard-visual-restoration.patch"
git apply --ignore-space-change --check $patch
if ($LASTEXITCODE -ne 0) { throw "Patch check failed. Share the output." }
git apply --ignore-space-change $patch
if ($LASTEXITCODE -ne 0) { throw "Applying patch failed." }
node .\scripts\test-dashboard-visual-restore.cjs
if ($LASTEXITCODE -ne 0) { throw "Checks failed. Share the output." }
node .\scripts\apply-dashboard-visuals-local.cjs
if ($LASTEXITCODE -ne 0) { throw "Visual query installation stopped. Share the output." }
```

Hard-refresh with Ctrl+Shift+R. No database reset, permission rollback, environment change or Edge Function restart is needed. If test dependencies are missing, use the existing `npm ci --prefix scripts/filing-tests --ignore-scripts` installation first.

The small installer runs the same additive function definition in a rollback probe before commit and verifies its body and grants. A different existing projection is not overwritten.

## Verification

The PostgreSQL suite checks the installed administration boundaries, bank-isolated chart aggregates, correct higher-risk totals, bounded industry aggregation, forbidden roles and unchanged existing permission function bodies. Controller tests cover original chart-panel rendering, exclusion of TEST from the LIVE card, Head-specific controls, exact uncertain-request retry, stale reads, escaped content and all restored admin page entry points. HTML structure checks verify the original shell identifiers, unique controls and placement of detail/list regions.

The build environment did not provide a native browser for signed-in visual verification. After installation, compare both accounts against the original layouts, open/back out of a detail view, and check the sidebar, charts and separate admin pages. The authorization tests use an isolated database and simulated Auth/DOM; no live users, emails or customer records were changed while building this patch.
