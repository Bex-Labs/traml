# Hosted deployment recovery — 6 November 2026

Target: Tranx-Monitor (mbwgglgvykjpsnvnvcsj), frontend https://traml.vercel.app.
Repository branch: Bex-Labs/traml, feature/aml-engine-v2.

## Already deployed
- Text bank identifiers retained; existing UUID audit and telemetry identifiers converted losslessly to text.
- Canonical login audit retained; the redundant legacy login trigger function no longer attempts a second malformed write.
- Trusted session/profile/Auth metadata verification restored through coreaml_dashboard_context.
- Case claim/workflow, review/submission/ageing, case worklists/timeline/summary, filing v1/v2/v3, rule governance, admin/manager and chart modules installed in dependency order.
- New workflow functions corrected to write text bank IDs to telemetry; administrative audit records retain text bank IDs.
- admin-actions version 16, invite-user version 22, filing-workspace version 1 deployed.
- Hosted origin/redirect defaults apply only to this Supabase project; explicit environment settings still take precedence. Other projects retain their existing configuration.
- No baseline rules automatically activated. No invitations or regulatory submissions sent. LIVE filing export remains disabled unless explicitly configured.

## Verification
- Full workflow installation first executed inside a rolled-back transaction against the hosted schema.
- Existing compliance user's actual session/profile/trusted claims passed dashboard context, worklist, submissions, rule workspace and filing queue reads.
- Admin context and Users/Banks/Audit/Requests directory reads passed.
- Officer platform-directory denial, admin manager-dashboard denial, and anonymous context denial passed.
- Login timestamp change produced exactly one bank-scoped audit entry; write rolled back.
- Text-tenant logout audit passed; write rolled back.
- Case claim attempted only if an eligible existing unassigned alert was available; this is not an unconditional workflow write acceptance pass.
- Edge Functions reported ACTIVE after deployment. Signed-in browser, CORS and real Auth API flows still require user verification.
- Security advisors were checked before and after. Existing unrelated findings remain, including RLS disabled on public.loans, mutable function search paths, and other legacy callable definer functions. This is not a full production security sign-off.
  Advisor reference: https://supabase.com/docs/guides/database/database-linter?lint=0013_rls_disabled_in_public

## Account provisioning still required
- The existing bank_manager profile has no tenant assignment and no trusted role metadata. An administrator must confirm the intended bank before assigning it.
- The existing head_of_compliance profile has bank-alpha assigned but lacks trusted Auth role/tenant metadata. Its trusted provisioning needs review.
- These identities were not silently granted new access during deployment.

## Record changes in GitHub
The GitHub integration returned 403 Resource not accessible by integration. No remote commit was created.

Apply the accompanying patch to the Windows checkout, inspect the staged diff, commit and push feature/aml-engine-v2. It includes four migrations with the exact versions already recorded in the hosted migration history.

Do not re-run these SQL files manually against the hosted project: they are already applied.
Do not apply the combined workflow migration manually to your previously configured local database: those objects already exist there through the local installers. Local history reconciliation needs a separate verified plan.

Hard-refresh https://traml.vercel.app and sign in with the existing compliance account. Do not send passwords, access tokens, or recovery links in chat.
