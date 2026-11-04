# Staff profile consistency: local draft

The local bank-isolation reports from 2026-10-21 contain 17 passing SQL checks and
nine passing baseline checks. Customer/account isolation is verified for those
paths. Other tables, views, functions, and service-role code still need review.

## Current change

The known roles are it_admin, head_of_compliance, compliance_officer, bank_manager,
branch_manager, teller, sales_rep, and the legacy bankmanager alias. The two manager
spellings are retained, not silently mapped to different business capabilities.
user_profiles previously rejected four of these roles. The draft CHECK constraint
accepts all eight while rejecting unknown role names.

The Auth trigger now populates both public profile tables from trusted
raw_app_meta_data and maintains display names from raw_user_meta_data. Display data
does not authorize anything. A staff assignment must reference an existing bank,
except that an IT admin can have no bank. Existing explicit is_active=false values
are preserved during synchronization and backfill. Removing an assigned trusted
role deactivates its staff row and clears the ordinary profile's role/bank.

The definer function is a trigger on auth.users, needed because the Auth service
does not directly manage these public tables. It has an empty search_path, fully
qualified tables, and no browser/PUBLIC EXECUTE grant. Existing trigger references
remain valid; the additional trigger also handles trusted metadata changes.

Restrictive profile-directory policies scope reads to the assigned bank while
retaining self-profile bootstrap access and IT-admin management. Existing
permissive policies still determine which writes are possible. Other bank users
cannot gain staff-management rights through the new policies.

The custom token hook uses the documented event.user_id and text bank IDs. Missing
or inactive staff receive access_disabled and no tenant. Only supabase_auth_admin
receives explicit EXECUTE on the hook. This patch updates the function but does not
enable the hook in local configuration, revoke existing sessions, or refresh JWTs.

## Verification

Run the local applier, then the fixture login setup and baseline scripts. The
applier validates the named Docker DB/port and existing bank-boundary policies.
It checks profile consistency and scoped directories for all 11 fixture users,
rejects role escalation through user_metadata, checks inactive-user hook results,
and checks that browser roles cannot execute the internal functions. Mutation
probes roll back. The draft SQL is applied without changing migration history.

Before delivery the exact migration and all 14 runner assertions were executed
against PGlite 0.3.14. Additional PostgreSQL checks verified arbitrary text bank
IDs, unprovisioned signups receiving no staff profile, preservation of explicit
deactivation, and repeat migration application. Full local Supabase verification
is the user's next step; this is not a hosted deployment.

The baseline/setup scripts now inspect actual profile rows rather than continuing
to report the historical missing-profile flags from the first fixture run.

## Remaining work

The admin invite Edge Function still needs a trusted role/tenant provisioning flow,
checked persistence errors, scoped delegation, and custom-role capability design.
Its existing user_metadata-only invitation data is not a source of authority for
this trigger. Use the synthetic users for this stage, not new admin invitations.

Onboarding needs a complete atomic workflow: its existing client sends a missing
accounts.tenant_id column, sends PENDING to an enum that does not contain PENDING,
and ignores the account-insert error. Storage object cleanup, account permissions,
pending approval state, and transaction eligibility also require tests. This
staff-profile patch does not change onboarding or declare it fixed.
