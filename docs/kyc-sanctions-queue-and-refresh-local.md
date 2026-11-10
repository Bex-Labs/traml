# Sanctions referral views and scheduled refresh

Apply this patch after the local sanctions corrections patch.

**Open holds** lists pending, confirmed hits whose correction has not been approved. **Correction history** lists approved corrections, including applicants whose KYC is complete. **View correction** shows the original confirmation, evidence reference, and decision reason. History entries have no KYC approval action.

## Run once and register the local Windows task

Start Docker and the local Supabase stack, then run this from the CoreAML folder in PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\register-kyc-sanctions-refresh-local.ps1 -At 06:00
```

The command fetches and validates all official feeds, installs the local queue and refresh SQL, and registers a daily 06:00 task in the Windows machine's time zone. It uses the current Windows account and runs when that account is logged on. The local Supabase stack must be running. Adjust `-At HH:mm` to suit the machine's availability. Registering again updates the named CoreAML task. Scheduled runs import data without reapplying the schema.

Hard-refresh CoreAML and verify that your completed fixture appears only in **KYC & Identity → Sanctions referrals → Correction history**.

## Verify the scheduled task

```powershell
$task = 'CoreAML Local Sanctions Watchlist Refresh'
Start-ScheduledTask -TaskName $task
Get-ScheduledTask -TaskName $task | Select-Object TaskName, State
```

After the task finishes, check its result and the refresh journal:

```powershell
Get-ScheduledTaskInfo -TaskName $task | Select-Object LastRunTime, LastTaskResult, NextRunTime
Get-Content .\.coreaml-local\sanctions-refresh\runs.jsonl -Tail 2
```

`IMPORTED_LOCAL_PILOT` means the records changed and a new snapshot became current. `VERIFIED_UNCHANGED` means the current snapshot was checked again and existing screening references still apply. A changed snapshot requires a current screening run for pending KYC approvals. Prior evidence and confirmed holds remain recorded.

A failed fetch or import records `FAILED` and leaves the last successful database snapshot in place. KYC screening and approval require a snapshot verified within seven days.

To remove the recurring job, use `Unregister-ScheduledTask -TaskName 'CoreAML Local Sanctions Watchlist Refresh' -Confirm:$false`. The job uses the existing local-only database guard. Hosted scheduling and staging deployment are separate work.
