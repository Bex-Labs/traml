# Local KYC sanctions approval

Apply this patch after the KYC sanctions review pilot and Retail fix. It extends the local SQL installed by the existing snapshot importer. Apply it only to the local stack while testing.

```powershell
$snapshot = Join-Path $env:TEMP "coreaml-sanctions-pilot.json"
node .\scripts\import-kyc-sanctions-local.cjs $snapshot
if ($LASTEXITCODE -ne 0) { throw "Local sanctions upgrade failed." }
```

If the snapshot is missing or older than seven days, refresh it with `python .\scripts\coreaml-sanctions-pilot.py refresh $snapshot` before importing. Hard-refresh the local browser after installing.

## Approval behavior

| Screening state | What happens at KYC approval |
| --- | --- |
| Current run has no name match | Approval can proceed once the other KYC requirements pass. CoreAML links the run to the approval. |
| All candidates on the current run were dismissed | Approval can proceed once the other KYC requirements pass. CoreAML links the run and keeps the saved dispositions. |
| Check is missing, snapshot is stale, or a candidate is unresolved | The server blocks approval and the application stays pending. |
| A confirmed match was recorded | The server holds activation and shows the case under **Confirmed sanctions referrals** in the same bank's Head of Compliance KYC directory. A list refresh or applicant rename does not clear the hold. |

The ordinary KYC evidence fields remain part of manual review. A sanctions run supplies the sanctions snapshot and candidate evidence. PEP and identity checks must be completed separately. Existing approvals keep their recorded evidence. The approval server can still confirm an exact retry of an already completed approval.

## Local acceptance

Use synthetic applicants and documents for these checks. If the earlier corporate fixture's only candidate is already dismissed, use a separate pending fixture for the unresolved and confirmed paths. A candidate's saved decision is immutable.

1. For a fresh synthetic applicant, attempt approval with otherwise valid KYC evidence before running a sanctions check. The server should ask for a check and leave the account pending.
2. Run a check for a fictional name. A no-match result permits the rest of the manual KYC process.
3. For a synthetic application with a listed name, run the check and attempt approval before disposition. The server should request a review of all candidates.
4. Confirm a candidate on that dedicated hold fixture. Sign in as the same bank's Head of Compliance, open the KYC directory, and expand **Confirmed sanctions referrals**. The referral should show the applicant, source and reviewer reason. Approval by the Head also remains blocked.
5. On a different synthetic application, dismiss all candidates, complete the manual evidence and approve. Verify the application is completed and the account is active.

The pilot records and routes confirmed holds. A release or correction procedure would need a separately approved workflow.
