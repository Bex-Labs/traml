# AML browser readiness correction and diagnostics

The native report showed 12 passes, one timeout and one dependent blocked check.
No alert was reviewed. Cross-bank denial, both sign-outs and the unchanged-state
fingerprint passed. This is not a successful officer evidence-viewing result.

The original login helper had two unlabelled waitForFunction calls after session,
authenticated read and trusted-profile checks: dashboard handlers/role readiness,
and a queue fetch wait. The report could not identify which failed. The code
therefore does not establish a CDN, database, authentication or evidence-renderer
root cause from that timeout alone.

This patch:

- Separates named readiness phases without rerunning login or forcing dashboard
  initialization. Handler/role and queue readiness have bounded 45-second budgets,
  consistent with the existing navigation budget. Persistent failures still fail.
- Requires an explicit queue result: rendered rows or the application's empty
  message. An absent queue, unknown placeholder or Fetching state is not success.
  The application's database-error message is an explicit failed phase.
- Adds a ten-second abort deadline to the actual queue SELECT. No automatic retry
  is added. An old asynchronous queue response/error cannot overwrite the result
  of a newer request or filter selection.
- Records safe phase timing, DOM readiness/role/queue classification, pending
  script/style/document/REST reads at failure, asset/read completion and status,
  and bounded console errors. Request headers, bodies, passwords, tokens and full
  document/queue contents are not included. Snapshot diagnostics have their own
  1.5-second limit and cannot replace or suppress the original failure.
- Copies an existing results.json to results-before-TIMESTAMP.json before writing
  the next result. Previous native failure evidence remains available locally.

Apply after coreaml-aml-browser-evidence.patch. No SQL installation or financial
fixture creation is needed. Keep the same local Supabase stack and Python server
on port 5520 running. Run:

    node scripts/test-aml-browser-readiness.cjs
    node scripts/test-aml-evidence-ui.cjs
    node scripts/verify-aml-browser-local.cjs --headed

There are 11 simulated readiness/queue regression checks and the existing 19
mocked evidence UI/service checks. These are not native browser verification.
The intended native result is still 14 checks passed and 8 reviewed alerts, with
no financial/evidence changes and CTR NOT_FILED. Any new timeout retains its
specific phase and diagnostics. Share .coreaml-local/aml-browser/results.json.
Do not recreate cash fixtures or rerun integration deposits to address readiness.

The patch does not vendor/change CDN dependencies, disable CSP/RLS, alter role
requirements, bypass login, extend retries for auth/permission/network errors,
claim cases, evaluate new transactions or change hosted Supabase.
