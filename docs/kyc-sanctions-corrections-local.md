# Local sanctions hold corrections

Apply this patch after the sanctions approval and referral UI patches. With the local Supabase stack running, rerun the existing snapshot importer to install the database changes.

```powershell
$snapshot = Join-Path $env:TEMP "coreaml-sanctions-pilot.json"
node .\scripts\import-kyc-sanctions-local.cjs $snapshot
if ($LASTEXITCODE -ne 0) { throw "Local sanctions correction upgrade failed." }
```

If the snapshot is missing or older than seven days, first run `python .\scripts\coreaml-sanctions-pilot.py refresh $snapshot`. Hard-refresh the local app after the import.

## Verify with the held synthetic application

Use two distinct local Head of Compliance accounts assigned to the fixture's bank.

1. As the first Head, open **KYC & Identity → Confirmed sanctions referrals**. Find the test hold and choose **Propose correction**. Enter `Synthetic fixture is distinct from the listed entity.` and evidence reference `LOCAL-TEST-CORRECTION-001`. Submit the proposal. The hold stays in place. The proposing account should see **Awaiting another Head of Compliance**.
2. As the second Head, open the same referral and choose **Review correction**. Verify the original confirmation, proposed reason, and evidence reference. To test rejection, enter a reason and choose **Reject correction**. The hold should remain and a new proposal can be submitted. To test approval, review a pending proposal, enter `Independently reviewed the synthetic evidence.`, then choose **Approve correction**.
3. The approved referral shows **Match corrected**. Try approval before a fresh check and verify that the server requires screening. If another confirmed candidate remains, it continues to hold activation.
4. Open **Review KYC** and click **Run or reload sanctions check**. A new run is created even if the imported snapshot has not changed. Review any candidates in the new run. Complete the ordinary KYC evidence and approval only after all required checks pass.

CoreAML retains the original confirmed decision and all correction proposals, including rejected proposals, with reviewer identifiers, timestamps, and reasons. The queue shows the latest correction for each confirmed hit. Approval of a correction applies to that hit only and does not activate the account. This patch is installed through the local importer.
