# Claimed case workspace integration

This patch connects the installed local draft/closure foundation to the dashboard. It changes no database schema. Apply it after the 11-check foundation installation has passed.

## Interface

Case Management includes an Open Case button for server-claimed investigating or closed alerts. Either member of a group opens the same canonical claim anchor and case reference. The server validates the current officer, bank, membership and ownership on every load and write. A same-bank head or a closed case is read-only. Unlinked claimed cases can open without a customer profile.

Open drafts restore the saved narrative and pins, including intentionally empty pin lists. The previous workspace ledger is cleared. An older request cannot replace a newer case or local text. Pin labels and transaction references render as text in the new workflow rendering paths. Existing broader dossier/reporting rendering is outside this change.

Typing and pin changes save through `coreaml_case_action`. Saves run serially, coalesce intermediate edits and require a matching server acknowledgement before the status says confirmed. There is no direct draft upsert, client-supplied bank/officer authorization, or client alert sweep. Every request has a UUID and expected revision. A failed transport or incomplete acknowledgement retains its exact request for retry before newer edits are saved. A stale revision stops editing rather than silently replacing another editor's work. Copy local text, then use Reload Saved to explicitly replace it from the server. An unsuccessful reload preserves the previous local text.

Save / Retry explicitly retries pending content. Save and Exit and in-app navigation await the current saves; an error keeps the workspace open. Closing flushes the latest draft and submits only the closure action. An uncertain closure locks editing and offers Retry Closure Confirmation, which reuses the original request. No success message or exit occurs before acknowledgement. A reload/close-browser warning covers unsaved or pending work while the tab is alive; pending request references are held in memory and do not survive a browser restart. After restart, load the server draft to reconcile its saved revision and case status before editing.

Only validated same-bank customer records and transaction references can be pinned. Arbitrary external manual targets are not saved. Proactive creation and the workspace Escalate button remain unavailable while their separate workflows are unverified; this patch does not submit reports, invoke provider functions or create financial activity. Closure changes only the members named in the existing claim receipt, preserving original alert details/evidence and the reviewed risk policy.

## Checks

Run `node scripts/test-case-workflow-ui.cjs` for 21 service, session, actual-handler and browser-boundary checks. They execute the real service/session modules and extracted dashboard handlers with simulated SDK/DOM dependencies. They cover request deadlines, exact acknowledgement checks, overlapping edits, uncertain save and close responses, stale revisions, safe exit, literal saved labels, canonical resume, late load invalidation and closed read-only controls. They are not a native browser or concurrent database acceptance pass.

Run `node scripts/verify-case-workspace-readonly-local.cjs --headed` with the local app server running on 127.0.0.1:5520. It logs in through the actual form, opens the retained customer-linked fixture using its actual Open Case button, verifies the canonical workspace, signs out and compares full state. Its request boundary allows only the exact retained fixture's read RPC; save/close, claiming, direct writes, Edge functions and unexpected destinations are blocked. It retains diagnostics in `.coreaml-local/case-workspace-readonly.json`. No draft saves or closures are permitted by this test. Keep the local app bound to the intended project and API port 55321.

Then rerun `node scripts/verify-aml-browser-local.cjs --headed` for the existing eight-alert evidence and cross-bank read-only regression.

Native signed-in save/resume/closure, lost-response replay and two-tab stale-edit acceptance are the next controlled stage. Do not use the retained fixture for manual closure before that stage: it should stay open for the acceptance harness. Existing completed claim and risk tests do not need to be rerun or recreate their fixtures.
