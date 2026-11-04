# Native local claim acceptance

Requires the successfully installed atomic claim foundation and the existing
local browser tools. Run from the CoreAML repository root:

```powershell
node .\scripts\test-case-claim-acceptance-boundary.cjs
if ($LASTEXITCODE -ne 0) { throw 'Acceptance boundary checks failed.' }
node .\scripts\verify-case-claim-acceptance-local.cjs --headed
```

The verifier creates and retains **two new synthetic alerts**, with no customer
or transaction links. The first is claimed using the actual officer login,
queue, modal and Claim button, then retried through the actual service. The
second is claimed by two concurrent database-role sessions using existing active
synthetic compliance officers. An observed advisory-lock wait, exactly one
successful session and one receipt/audit event are required for a race pass.

The browser network boundary allows only local login/logout, reads and one exact
claim RPC for the new browser fixture ID. It blocks all other RPCs, database
writes and Edge Functions. Credentials and tokens are not written to the report.

Existing alert rows (including the original eight), claim receipts, audit events,
customer/account/transaction/risk/evaluation state and report archives are hashed
before and after, excluding only the two new fixtures and their expected claim
records. A difference is a failure. No deposits, evaluations or filings are
created. The test needs two already-existing, active, same-bank synthetic
officers; it does not create users or change their roles.

Results are retained under `.coreaml-local/case-acceptance/<run-id>/results.json`.
Each invocation creates a fresh pair if prerequisites pass. On a failure, preserve
the report rather than repeatedly creating more fixtures. Partly completed
fixtures are retained for diagnosis; there is no automatic destructive cleanup.

Preparation validation: JavaScript syntax and six boundary/receipt contract
checks pass. Native browser and concurrency acceptance must be run on the local
Windows/Docker stack. This suite does not validate customer-linked batch claims,
risk-trigger side effects for linked customers, drafts, closure, QA or reporting.
