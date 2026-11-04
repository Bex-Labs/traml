# Customer-linked claim and risk checks

The next native slice covers a dedicated synthetic customer with multiple
alerts. The original eight-alert fixture and the completed customerless claim
fixtures are not reused for mutation tests.

## Isolated checks completed

`scripts/test-customer-linked-claim-risk.cjs` executes the actual installed claim
SQL and repaired risk function in isolated PostgreSQL/PGlite 0.5.12. Ten checks
pass: HIGH plus MEDIUM establishes 40/MEDIUM risk, both alerts claim together,
ownership/reference match, risk rows and timestamps do not change during claim,
evidence/reasons remain unchanged, an unrelated customer is not swept in,
member-anchor retry replays the receipt, a second officer cannot steal the
group, and an injected second-member failure rolls back the whole group plus
its audit/receipt/risk effects.

The second-officer denial in this isolated suite is sequential. It is not a
claim that multi-session customer-linked concurrency or signed-in browser group
claiming has passed. The native customerless race remains a separate verified
result. No application or schema change is included in this package.

## Native fixture boundary to inspect

The current customer table has enabled KYC and identity-matching enqueue
triggers. Their function bodies were not included in the earlier case preflight.
Before creating a native synthetic customer, inspect them to determine whether
fixture insertion can cause work outside a rolled-back transaction. No trigger
is disabled and no provider request is made by this preflight.

Run from the repository root:

```powershell
node .\scripts\preflight-customer-linked-claim-local.cjs
```

Attach `.coreaml-local/customer-linked-claim-preflight.json`. It contains only
catalog/default/trigger function source, with recognized JWT/secret-key literals
redacted. It reads no customer records, creates no fixtures or claims, and uses
an explicitly read-only transaction after the known local-project guard.

The isolated test source is included for reproducibility, not as a required
command for this preflight. To run it separately, provide PGlite through
`COREAML_TEST_PGLITE_MODULE` or the existing test-tools directory. Native fixture
creation, full group acceptance and the later drafting/closure workflows remain
pending until the customer trigger boundary is reviewed.
