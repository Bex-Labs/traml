# Hosted sanctions watchlist refresh

Tranx-Monitor uses the `coreaml-sanctions-refresh` Edge Function and the
`coreaml-hosted-sanctions-refresh` job in Supabase Cron. The job is configured
for 05:00 UTC, which is 06:00 in Lagos. The Windows job remains a separate local
workflow. Deploy both worker migrations before enabling the function in another
environment.

The dispatcher generates a one-use credential and delivers it over HTTPS using
an owner-only HTTP extension schema. The function verifies that credential
through the service-role-only claim RPC before fetching any sources. Deploy the
function with gateway JWT verification disabled for this custom authorization
path. The deployment uses `index.mjs` as its entry point.

The worker fetches the official UN, OFAC SDN and non-SDN, and Nigeria lists.
It validates feed format, redirects, required sources, and OFAC primary and
alias release pairing. Publication commits the snapshot and any enrolled-bank
rescreening batches together. Banks require explicit enrollment. The local
onboarding approval gate is a separate release.

## Check the daily run

Run these read-only checks as a database administrator. A successful Cron
dispatch and a successful refresh receipt are separate checks.

```sql
select jobname, schedule, active
from cron.job
where jobname = 'coreaml-hosted-sanctions-refresh';

select r.status, r.start_time, r.end_time
from cron.job_run_details r
join cron.job j on j.jobid = r.jobid
where j.jobname = 'coreaml-hosted-sanctions-refresh'
order by r.start_time desc limit 5;

select state, http_status, failure, receipt, queued_at, finished_at
from coreaml_private.kyc_sanctions_refresh_attempts
order by queued_at desc limit 5;

select sha256, retrieved_at, last_verified_at
from coreaml_private.kyc_sanctions_snapshots
order by coalesce(last_verified_at, retrieved_at) desc limit 1;
```

A healthy run shows `SUCCEEDED` with HTTP status `200`. A receipt of
`VERIFIED_UNCHANGED` means the feeds were checked and the existing snapshot
remains current. `IMPORTED_LOCAL_PILOT` is the existing database receipt
label for a newly imported snapshot, including when the worker runs on hosted
Supabase. `FAILED` records the step that failed and retains the last
successful snapshot. No external alert destination is configured.
