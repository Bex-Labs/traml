# Local watchlist rescreening

Install from the CoreAML folder with Docker and local Supabase running. This patch builds on the scheduled refresh and inline sanctions referral patches.

```powershell
$python = (Get-Command python.exe -CommandType Application | Select-Object -First 1).Source
node .\scripts\refresh-kyc-sanctions-local.cjs "$python" --install
if ($LASTEXITCODE -ne 0) { throw "Local sanctions rescreening install failed." }
```

The install refreshes the official feeds and screens the current snapshot. The existing Windows task uses the updated runner at its configured time. It needs the same Windows sign-in and running local Supabase stack as before.

## Verify the local workflow

1. Inspect the install output. `rescreening.status` is `SCREENED` when the batch completes. `screened_count` covers customers with completed KYC, a bank, and a screenable recorded identity. `skipped_count` covers bank-linked customers with completed KYC whose names or customer types are missing. `new_candidate_count` can be zero.
2. Hard-refresh the frontend and sign in as Head of Compliance. Open **KYC & Identity → Sanctions referrals → Rescreening matches**. Pending candidates appear before reviewed rows. Where a synthetic match exists, use **Review match** to record a reason and choose **False positive** or **Needs follow-up**.
3. Confirm the disposition stays visible after refresh and the account retains its status. **Needs follow-up** records the review outcome in this queue. Further investigation is a separate staff action.
4. Check the next scheduled run using the commands below. `LastRunTime` should reflect the scheduled run, `LastTaskResult` should be `0`, and the journal should have a matching successful entry. You can also use `Start-ScheduledTask -TaskName $task` to test the scheduled action on demand.

```powershell
$task = 'CoreAML Local Sanctions Watchlist Refresh'
Get-ScheduledTaskInfo -TaskName $task | Select-Object LastRunTime, LastTaskResult, NextRunTime
Get-Content .\.coreaml-local\sanctions-refresh\runs.jsonl -Tail 3
```

The first batch establishes a baseline for the current snapshot. A changed snapshot starts a new batch. When the snapshot is unchanged and already screened, `ALREADY_SCREENED` reports the last batch's coverage counts and zero new candidates. The same customer identity and watchlist evidence produce one queue entry across snapshots. Matching manual KYC dispositions for the same recorded identity remain in effect for queue deduplication. Pending KYC continues through the existing onboarding workflow.

The snapshot import and rescreening commit together. A failed batch leaves the previous snapshot and queue in place and the next run can retry. The bell still represents onboarding activation holds. This pilot uses the existing name and alias normalization and is limited to the local environment.
