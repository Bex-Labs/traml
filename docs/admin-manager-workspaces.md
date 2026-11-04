# Bank manager and administration workspaces

## What this release changes

The bank oversight manager (`bank_manager`) now has a dedicated `manager-dashboard.html` page with Overview, Case progress, Transactions and Compliance team sections. Lists have search, 25-row pagination, explicit server snapshot times and full-page detail regions. Long content uses the main page scrollbar. Printing exports only the visible, authorized oversight snapshot.

The administrator page now has a staff directory, institution registry, enforced role matrix, historical custom-role inventory, administrative audit ledger and request outcomes. Large records open as dedicated detail views. Old user, tenant, role and audit URLs redirect to the relevant section. The transaction simulator and production transaction insertion controls are removed from the administration page.

The Head's team-management navigation opens the same scoped directory with bank-only controls. It does not expose the platform administration tabs or authorize other Heads, administrators or other banks as manageable targets.

No historical alerts, findings, reports, users, role assignments, customers, balances or rules are rewritten during installation. Detection, investigation, independent approval and filing handlers remain in place. Reporting totals keep TEST and LIVE modes separate and distinguish stored stages; they do not claim independent regulator confirmation.

## Permission decisions

| Role | Authorized workspace | Authority preserved or introduced here |
| --- | --- | --- |
| `bank_manager` | Bank oversight | Read-only, assigned-bank aggregate metrics, case progress metadata, transaction projection and compliance-team status. No findings, evidence files, report XML, report approval, filing, staff changes or banking writes. |
| `it_admin` | Platform administration | Institution creation, supported staff invitation, access suspension/restoration, administrative audit metadata and request outcomes. No self-suspension/restoration, customer evidence, direct customer/account/transaction access or compliance decisions. |
| `head_of_compliance` | Existing Compliance plus bank team administration | Own-bank compliance decisions remain in the existing workflow. The directory permits invitations and access actions for compliance officers in the same bank only. Other Heads and administrators are read-only or unavailable. |
| `compliance_officer` | Existing Compliance | Existing assigned-case investigation, structured dismissal and reporting workflow remains. No platform administration. |
| `branch_manager`, `bankmanager`, `teller`, `sales_rep` | Existing core banking | These are distinct existing operational roles. `bankmanager` is not silently renamed to or granted the oversight role `bank_manager`. The banking page now verifies the active trusted context before selecting its UI. |

Historical custom-role records remain visible as inventory. They are not advertised as effective permissions, and arbitrary role strings cannot be assigned through the invitation endpoint. A general custom-capability engine is not implemented by this patch.

## Server enforcement

The new dashboard RPCs require an active staff profile, matching trusted JWT claims, a matching current Auth role/bank, an unbanned identity and an existing Auth session row. User-editable metadata is not authorization input. Client routing uses this server context; missing or stale claims may refresh once, without falling back to an untrusted role. Session verification has a deadline.

Restrictive RLS fences deny raw business-table access to the oversight manager and technical administrator even where old permissive policies exist. Evidence storage receives the same fence when `storage.objects` exists. Browser writes to staff profiles, institutions and custom-role definitions are revoked; controlled administration uses RPCs and the revised Edge Functions. The old unscoped rolling-statistics helpers are wrapped with bank/role checks, while trusted worker execution is retained. Browser execution of the unguarded risk-update and global baseline-recalculation RPCs is revoked.

The scope is the supplied dashboards, their provided administration handlers, the reviewed database read/write paths and the relevant storage fence. Other Edge Functions not included in the backup are not replaced or certified by this patch.

## Administration outcomes and retries

Every staff administration action first reserves an attributed request in the database. Exact retries use the same request UUID and payload. A new call cannot silently reuse an old UUID for another target or action.

Suspension disables the trusted profile before the Auth ban. If Auth confirmation fails, the profile stays disabled and the request remains visibly unconfirmed. Restoration does not reactivate the profile until the Auth state, unchanged target role/bank and database audit receipt have been confirmed. Existing access tokens are denied by the active-profile/session checks and business fences; this does not claim that all historical tokens have cryptographically expired.

Invitations are restricted to supported roles and authorized banks. Existing identities cannot be implicitly re-roled by an invitation. The server invites the identity, records its Auth ID, and sets the role and bank in trusted app metadata. Before that assignment, an unprovisioned identity has no staff authorization.

An uncertain invitation is not blindly resent. A reserved request without a confirmed Auth ID requires checking the request and the Supabase Auth directory. Once its Auth ID is checkpointed, an exact retry can resume trusted provisioning without another invitation email. RESERVED is a dispatch reservation, not proof of email delivery or completed provisioning. Confirmed invitations mean that the provider accepted the invite and provisioning completed; they do not prove inbox delivery.

The old reset handler generated a link without delivering it. It no longer reports password-reset success. The new workspace does not offer that misleading control; use the existing sign-in recovery process or the institution's authorized Auth recovery procedure. No recovery message was sent while building/testing this patch.

Institution creation is an atomic request and audit operation. It does not transfer unassigned customers, create fictitious customers or activate rules.

## Install on the existing local project

Apply this incremental patch against the supplied Backup source, after the filing and rule-governance database upgrades. The installer verifies the required objects and legacy helper signatures. It runs the same plan in a rollback probe, compares protected data digests, commits, and verifies function bodies and key permission boundaries. Windows CRLF differences are normalized. A mismatched existing installation is not overwritten.

```powershell
Set-Location "C:\Users\Admin\Documents\Bex\CoreAML"
$patch = "$env:USERPROFILE\Downloads\coreaml-admin-manager-workspaces.patch"
git apply --ignore-space-change --check $patch
if ($LASTEXITCODE -ne 0) { throw "Patch check failed. Share the output." }
git apply --ignore-space-change $patch
if ($LASTEXITCODE -ne 0) { throw "Applying patch failed." }
node .\scripts\test-admin-manager.cjs
if ($LASTEXITCODE -ne 0) { throw "Checks failed. Share the output." }
node .\scripts\apply-admin-manager-local.cjs
if ($LASTEXITCODE -ne 0) { throw "Upgrade stopped. Share the output." }
node .\scripts\configure-admin-manager-local.cjs
if ($LASTEXITCODE -ne 0) { throw "Local configuration stopped. Share the output." }
```

The test runner uses the existing `scripts/filing-tests` dependency installation. If missing, install it with `npm ci --prefix scripts/filing-tests --ignore-scripts` before testing.

The configuration helper defaults to `http://127.0.0.1:5520`; pass your actual loopback frontend origin as its argument if the port differs. It changes only `COREAML_APP_URL` and `COREAML_APP_ORIGINS` in the existing `supabase/functions/.env`, preserving other entries without printing their values. It refuses external URLs. Hosted deployment configuration must use the real allowed HTTPS frontend origin instead; this is a local installation helper.

Restart the existing function-serving terminal after configuration:

```powershell
supabase functions serve --env-file .\supabase\functions\.env
```

Then hard-refresh with Ctrl+Shift+R. No database reset is needed. Preserve `.coreaml-local/admin-manager/` and share the output if the installer stops.

## Signed-in acceptance checks

1. Sign in as `bank_manager`. Confirm the dedicated oversight page, bank name, exact transaction amounts, case metadata, team status and distinct TEST/LIVE reporting stages. Search, page and open/back out of a detail view. Confirm no compliance decision, staff mutation or banking-write control appears.
2. Use a manager from another bank and confirm their views do not show the first bank's references. Known URLs or row identifiers are not authority.
3. Sign in as `it_admin`. Check staff and institution pagination, role boundaries and the historical custom-role inventory. Confirm no simulation, investigation, banking transaction insertion or regulatory filing controls appear.
4. As Head, open Team management. Confirm own-bank officers are manageable, while peer Heads and administrators are not. Confirm an invitation for another bank or higher role is denied by the server.
5. In the test installation, use an explicitly chosen test staff identity to check suspension and restoration. Do not use your own account. Confirm the Request table and audit receipt update; use exact retry after an uncertain response.
6. Only when intentionally testing email, invite an authorized test address and complete the existing setup flow. This is a real provider operation on the stack where you run it. Check the trusted role/profile and the configured local redirect.
7. Return to an existing compliance case and check saved drafts, structured dismissal, independent review, report preparation and Back navigation.

## Validation completed in the build environment

Actual PostgreSQL (PGlite) tests execute the installer rollback/commit plan and RPCs. They cover bank isolation, active trusted identity/session checks, restrictive policies despite broad legacy grants, raw storage/table restrictions, guarded statistics, Head target scope, no self-management, Auth confirmation, request/audit replay, invitation allowlists and unchanged customer data.

Edge-handler tests execute the real shared handler with mocked Auth and RPC endpoints. They cover authorization before privileged operations, denied origins, trusted metadata provisioning, no blind invitation resend, checkpoint recovery and rejection of unconfirmed success. Client and simulated-DOM checks exercise acknowledgement validation, exact request retention, stale page loads, escaping, precision and dedicated detail navigation. Existing compliance submission, review safety and navigation regressions also pass.

Deno adapter checks use an SDK stub; the deployed SDK/network integration and native signed-in browser layout still require local verification. No live users, emails, accounts or reports were changed during these tests.
