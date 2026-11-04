# Atomic onboarding: local draft

## Verified starting point

The local staff report dated 2026-10-21 has 14 passing checks. Fixture password
logins pass for all 11 users and the baseline retains nine passing customer/account
access checks. Those results do not establish transaction or browser correctness.

The old onboarding handler uploads two documents, inserts a customer, then sends
accounts.tenant_id although that column does not exist. It also sends PENDING to an
enum without that value and does not inspect the account-insert error. Consequently
it can report a pending account number without an account having been created.

## Workflow and authorization

The enum addition is a separate migration because PostgreSQL must commit a new enum
label before another transaction can use it. Existing account balances and states
are not rewritten. The new RPC explicitly creates a PENDING, zero-balance account;
it does not inherit the existing accounts table's synthetic balance default.

onboard_customer is SECURITY INVOKER. It requires a current, active banking staff
profile matching the JWT's trusted role and bank. The supported maker roles are
teller, sales_rep, branch_manager, and the existing bankmanager alias. Compliance,
head of compliance, bank_manager, and IT admin are not teller substitutes. This
matches the banking entry point and separates staff administration from onboarding.

The RPC validates the customer type/name/BVN shape and bank/customer document paths.
Both Storage records must be owned by the caller. It then inserts the customer and
account in one database transaction. An account insert error rolls back the customer.
The request UUID is retained for retries; an advisory transaction lock serializes
matching references. An identical completed request returns its existing account;
changed details or an inconsistent prior record require reconciliation rather than
silently creating or replacing data. Number allocation retains the simulator's
10-digit format; this is not a certified real-bank NUBAN allocation implementation.

The new account INSERT policy grants the maker roles only own-bank pending,
zero-balance accounts for pending customers, subject to the earlier restrictive bank
boundary. The new BEFORE INSERT transaction trigger rejects pending accounts and
accounts unavailable to the current caller before the AFTER INSERT AML/till hooks.
It is not a complete replacement for an atomic posting/approval ledger service.

## Storage and browser behavior

kyc-vault is private with a 10 MB per-file ceiling and PDF/JPEG/PNG MIME types.
Restrictive policies enforce the bank prefix, caller-owned maker uploads, immutable
documents, and deletion only by the owner when no visible customer references the
object. Staff with a current active assignment can read within their bank; IT-admin
read visibility is preserved. This is access and transport validation, not document
authenticity, malware scanning, or completed KYC verification.

The browser service validates inputs, uploads deterministic object paths, and calls
the RPC. It never inserts a separate account or fabricates a success response. A
definite rejection with no customer permits cleanup of unlinked uploads. A lost or
incomplete RPC response retains documents and the immutable attempt for confirmation;
the form is locked until confirmation or a definite failure. Closing the page loses
that in-memory retry context, so the displayed UUID is the reconciliation reference.
Persistent resumable onboarding is a later product improvement.

The banking account lookup labels PENDING KYC APPROVAL and prevents selection for
posting. The legacy bankmanager role is accepted by bank-login as well as by the
existing terminal role checks. The ordinary bank_manager role keeps its compliance
meaning and is not silently mapped to the legacy banking spelling.

The previous entity-webhook function falls back to port 54321 when unconfigured,
which can target the other local project's gateway. This draft queues no webhook
when its Vault URL/key/shared-secret configuration is absent. Correctly configured
webhooks keep their existing path. A pending application is never described as a
successful external identity/sanctions screen merely because submission succeeded.

## Local integration runner

Run `node scripts/test-onboarding-service.mjs` for dependency-free service tests.
Then run `node scripts/verify-coreaml-onboarding-local.cjs --apply` to apply the two
drafts only to sentinel-aml on local port 55322 and exercise the actual local API.
The runner requires the earlier isolation/staff fixes and the Storage owner_id
column. It refuses a non-loopback status URL. It does not change migration history.

Its 18 checks include successful applications for the four maker roles, a corporate
application, same-reference retry checks, denied creation for the four non-maker
roles, private/cross-bank documents, invalid BVN/missing files, rejected pending
postings, and a forced account-insert failure proving customer rollback. The forced
constraint exists only inside a rolled-back SQL probe. Successful pending synthetic
applications remain available for browser review; the report lists their IDs and
account numbers. Real PNG transport is exercised through local Storage.

## Validation before delivery and limits

Before delivery, 17 scenarios passed against PGlite 0.3.14 using the real migration
SQL and minimal schema/RLS reproductions. Browser service tests passed for success,
upload failure/cleanup, definite RPC rejection, linked-document retention,
lost-response retry, duplicate upload recovery, incomplete responses, and network
errors. Both HTML module scripts passed syntax checking. A mock integration driver
run exercised all 18 runner checks, local-only addressing, rollback probing, and
secret-free reporting. Full local Auth/Storage/PostgREST execution is still the
user's next verification, followed by the browser form journey.

KYC approval and safe activation, the admin invitation flow, AML thresholds/rules,
atomic ledger posting and cash approvals, remaining RLS surfaces, and the modernized
UI are still outstanding. Other schema or authorization gaps may emerge as those
workflows are exercised. These local drafts have not been deployed to the hosted
project. Final migration-history reconciliation and review remain required before
any remote migration deployment.
