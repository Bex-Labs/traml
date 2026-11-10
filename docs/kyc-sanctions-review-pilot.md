# KYC sanctions review pilot

This patch adds a local sanctions review panel to the existing KYC modal. It uses the official snapshot from the sanctions CLI pilot. The UI appears when both CoreAML and its Supabase API run on localhost or 127.0.0.1. The importer targets the existing sentinel-aml local Docker database on port 55322.

## Import and open the pilot

Apply the patch from the CoreAML root. Start the existing local Supabase stack and frontend. The local admin/manager upgrade must already be installed because the pilot reuses its active staff authorization function.

```powershell
$snapshot = Join-Path $env:TEMP "coreaml-sanctions-pilot.json"
python .\scripts\coreaml-sanctions-pilot.py refresh $snapshot
if ($LASTEXITCODE -ne 0) { throw "Feed refresh failed." }
node .\scripts\import-kyc-sanctions-local.cjs $snapshot
if ($LASTEXITCODE -ne 0) { throw "Local snapshot import failed." }
```

A successful import reports `IMPORTED_LOCAL_PILOT` and counts for all four lists. Importing the same file twice reuses its snapshot. The server requires a snapshot retrieved within the past seven days.

Hard-refresh the local frontend. Sign in as a compliance officer or Head of Compliance. Open the KYC directory and choose **Review KYC** on a local test application. The existing review modal requires both identity and address test documents.

1. Click **Run or reload sanctions check**. The server screens the application's recorded name against the latest local snapshot.
2. A fictional customer name should produce **No name match in this snapshot**. To test a positive result, use a separate fictional corporate application named **NINE TO NINE BDC LTD** in the local environment.
3. Open the candidate's official source link. Enter a review reason of at least 10 characters and choose **Confirm match** or **Dismiss as false positive**. For a fictional fixture, a suitable test reason is “Synthetic applicant used to test the pilot.”
4. Close and reopen the same review and run the check again. The same applicant name and snapshot should return the saved decision.

## Review behavior

Possible matches compare normalized names and aliases. Individual names also support reordered tokens. The Nigeria source links directly to the designation. UN and OFAC link to their official lists and show the record reference for lookup.

A run retains its snapshot hash, source evidence, reviewer and date. A decision is recorded once per candidate, and an exact retry by the same reviewer returns the saved result. A different snapshot or applicant name starts a separate run. Previous runs remain in the database. This pilot panel shows the current run.

The panel provides sanctions evidence for manual review. Identity verification, PEP screening, KYC approval, account activation and transaction rules use their existing workflows. There are no new hosted migrations or Edge Functions to deploy for this local pilot.
