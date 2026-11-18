# Bank integration readiness

Use synthetic records for the first acceptance run. Record the environment, migration versions, test inputs and results. The local core-banking workflows and a working dashboard provide a test baseline. Each bank pilot needs a tested integration into that baseline.

| Acceptance check | Evidence to collect |
| --- | --- |
| Data contract | Agree customer, account and transaction fields, stable source IDs, currencies, time zones, reversals and update semantics. Document validation and rejected-row responses. |
| Transport and access | Agree API or batch delivery, service identity, credentials, connectivity, access rotation and test/production separation. Verify that each service identity can access only its own bank. |
| End-to-end ingest | Load sample customer, account and transaction records through the actual integration. Replay the same batch and demonstrate that transaction IDs, counts and amounts reconcile to the source. Test retries after a partial failure. |
| Detection and review | Trace a known synthetic transaction through evaluation, alert creation, case review, and audit history. Exercise overlapping existing and governed rules and verify alert handling. |
| Staff security | Test invitation, first authenticator enrollment, subsequent sign-in, loss of authenticator, and bank-scoped access. Check Data API, private Storage, Realtime business data and browser-facing Edge Functions. |
| Operations | Agree monitoring and support contacts, a reconciliation schedule, backup and restore checks, rollback steps and the approval required to switch to production. |

## Account settings rollout checks

Enable authenticator enrollment and verification locally before running the account security migration. Confirm the local project reads `supabase/config.toml`. Check that PostgREST has no conflicting pre-request hook in database settings or runtime configuration. The migration refuses to overwrite a different hook recorded in database role settings.

Use one synthetic compliance officer and one Head. Start a new password session for each. Verify that the dashboard and protected Data API require MFA at AAL1, and that the authenticator enables access at AAL2. Sign out and check the code challenge on the next sign-in. Verify that a teller's existing path still works. Test adding, replacing and removing a photo and confirm another user cannot read it. Check that reporting configuration is limited to the Head's bank.

Before a hosted release, test administrator-assisted factor recovery and confirm that the authorized administrator can revoke existing sessions and require fresh enrollment after identity verification. Deploy the changed staff-facing Edge Functions with the database and frontend, and smoke-test their request paths. Keep a known-good administrator recovery route available during rollout.

Production identity verification depends on provider access and each bank's consent and data-handling arrangements. Track those separately from the synthetic integration checks.
