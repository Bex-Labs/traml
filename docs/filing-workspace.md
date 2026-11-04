# CoreAML report preparation and filing

New cases use one final reporting approval. The assigned officer prepares the investigation findings and report XML before the Head reviews the complete version. The assigned officer or Head can then handle export, submission recording and external-response recording. There is no routine Head confirmation of a newly recorded acknowledgement or rejection.

## Default workflow

1. The officer investigates, records findings and links evidence in the AML Investigation Workspace.
2. The officer chooses **Prepare SAR / STR**. CoreAML first saves the latest work, then seals the confirmed investigation revision and opens report preparation. This does not request a preliminary Head approval or file a report.
3. The officer checks the schema profile, prepares or imports XML, saves it and chooses **Submit saved version for final approval**. The saved XML must pass the configured schema and match the sealed findings and transaction facts.
4. The Head opens **Final report review & filing**, then **Final report approval**. The Head inspects the findings, evidence and report XML together. **Approve final report version** records the investigation decision and approval of that exact report version in one database transaction. A person cannot approve their own preparation.
5. The assigned officer or Head exports the approved version, submits the exact file through the institution's reporting channel and records the submission evidence in CoreAML. TEST exports must not be submitted to NFIU.
6. Either authorized user records the actual acknowledgement or **Record rejection from goAML/NFIU**, with the response reference, time and evidence location. These are attributed manual entries, not an automated regulator verification.
7. A recorded rejection immediately unlocks correction. A corrected report needs fresh final approval. A recorded acknowledgement changes reporting progress to **Acknowledgement recorded · case closure pending**. No routine additional response confirmation is required.

## Returning work for correction

The Head uses **Return to preparing officer** with a note and a **Return destination**:

- **Report details only** keeps the investigation snapshot sealed and returns XML preparation to the officer.
- **Investigation findings and evidence** is available for a new, unapproved single-review package. It rejects that internal package and reopens the assigned officer's investigation. The officer can revise findings and evidence, save them and choose Prepare SAR / STR again. Earlier submissions remain in history.

An internal return is distinct from an external goAML/NFIU rejection. An approved or filed report's original investigation snapshot is not silently rewritten. New investigative findings after filing require a governed investigation process rather than editing history.

## Optional early guidance

**Optional early guidance** in the investigation actions retains the earlier executive-review route for cases that need a decision before full report preparation. Head of Compliance sees those requests under **Early reporting guidance**. This route is optional for new cases. Its approval authorizes preparation; the later report XML still needs final version approval. The default complete-package route does not appear in that queue, and the early-review API cannot bypass its final reporting review.

## Install the update

This patch follows the independent-review update, Windows line-ending fix and reporting-toolbar spacing patch. Keep Docker and the existing local database running. Do not reset the database or reapply earlier patches.

```powershell
Set-Location "C:\Users\Admin\Documents\Bex\CoreAML"
$patch = "$env:USERPROFILE\Downloads\coreaml-streamlined-reporting.patch"
git apply --ignore-space-change --check $patch
if ($LASTEXITCODE -ne 0) { throw "Patch check failed. Share the output." }
git apply --ignore-space-change $patch
if ($LASTEXITCODE -ne 0) { throw "Applying patch failed." }
node .\scripts\test-filing-workspace.cjs
if ($LASTEXITCODE -ne 0) { throw "Checks failed. Share the output." }
node .\scripts\apply-filing-streamlined-v3-local.cjs
if ($LASTEXITCODE -ne 0) { throw "Installation stopped. Share the output." }
```

The installer checks the reviewed original functions and the prior filing installation. Source comparisons normalize Windows CRLF line endings. It runs a rollback probe, then applies the same plan with in-transaction checks that existing protected records are unchanged. No report, approval, submission or response is created during installation. Keep its journal under `.coreaml-local/filing-streamlined-v3` local.

Restart Edge Function serving in its existing terminal, then hard-refresh CoreAML:

```powershell
supabase functions serve --env-file .\supabase\functions\.env
```

Leave the web server running. Do not rerun the V1 or V2 installer after this update. The V3 installer can verify an already installed matching V3 release without reapplying its DDL.

## Existing records

Existing reports, approval receipts, drafts, exports and responses are preserved. They are not automatically moved to the new route or assigned invented approvals. Already approved investigations continue with final report-version review. Older pending executive requests remain in the early-guidance queue. New cases use the simplified default.

If an older response was already in **Legacy response awaiting resolution**, the Head can use **Resolve legacy pending response** once after checking the retained evidence. This compatibility step does not apply to new responses. Older acknowledgement records remain explicit legacy records; their provenance is not silently upgraded.

## TEST demonstration

Use a fictional case and keep reporting mode Test. The included schema is fictional, not NFIU validation. Build or import demo XML, complete preparation, obtain final approval and export. Keep the `DEMO-NOT-FOR-SUBMISSION` filename. Use fictional submission and response references and do not upload the file to NFIU. The managed-case progress label retains an explicit TEST prefix.

## Live reporting and provenance

Live preparation/export still requires `COREAML_FILING_ALLOW_LIVE=true`, the institution's configured schema bundle and reporting entity ID, and non-synthetic source information. Use the existing `configure-filing-schema.cjs` and `bundle-filing-schema.cjs` workflow, then restart Edge Functions. Schema validation does not guarantee regulatory acceptance.

The factual starter is not a completed institution report. Complete required party information, codes and other fields from verified information. The current mapping uses NGN; unsupported foreign-currency mappings remain blocked. Sealed findings and transaction facts cannot be silently omitted or altered.

Recording a receipt does not contact NFIU. CoreAML records the actor, source version and evidence location and keeps earlier exports. Reporting status remains separate from case closure, customer risk, KYC status, balances and account restrictions. Missing reporting progress is shown as unavailable rather than inferred as success.

## Validation scope

The suite checks original investigation functions and new reporting functions in an isolated fictional PostgreSQL environment, real WASM XML/XSD validation, controller functions with simulated DOM/API responses, and the Deno Edge handler with mocked Auth/RPC endpoints. A legacy V2 contract test runs before the V3 tests to verify the retained upgrade foundation. These checks do not replace signed-in verification in the local Supabase runtime or validation of an institution's actual live schema.

The SQL files under `scripts/filing-tests` are isolated test fixtures. The application installer reads their reviewed function bodies for integrity checks but never executes those fixture files on the application database. The original unsafe report-propagation trigger fixture is disabled in the isolated test database and is never installed on the application database.
