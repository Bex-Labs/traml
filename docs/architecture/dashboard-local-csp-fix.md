# Dashboard local API connection policy

The browser diagnostic returned 19 PASS and 5 FAIL. Both fixture roles logged in;
Node authenticated reads and local Auth logout returned successfully. Direct browser
fetches and SDK reads failed. The trace contained no local API data requests after
navigation to dashboard.html, despite those attempted reads.

The dashboard's meta Content-Security-Policy has only default-src, permitting self,
HTTPS, secure WebSockets and data URLs. The local application origin uses port 5520;
its HTTP API uses port 55321, a different origin. With no connect-src, the default
policy is used for fetch/WebSocket connections, and the local HTTP API is excluded.
The login page has no equivalent meta restriction. This source defect explains the
Node/browser contrast and missing API requests. It is separate from slow external
resources observed on the head dashboard.

The patch preserves default-src and adds explicit connect-src entries for exactly
http://127.0.0.1:55321 and ws://127.0.0.1:55321 alongside existing permitted connection
sources. It adds no wildcard HTTP/WS permission, does not disable CSP, and changes
no credentials, RLS policies, authentication checks, API configuration or database
state. Configuration still selects the local backend only for loopback application
origins. The explicit loopback connection allowance is present in this shared HTML
file wherever it is served; this is not conditional response-header generation.
Further production CSP tightening is separate work.

Run with the already-installed Playwright and Edge or Chrome:

```powershell
node .\scripts\test-dashboard-csp.cjs
node .\scripts\verify-coreaml-kyc-browser-local.cjs --headed
```

The native browser regression uses synthetic, intercepted pages and responses; it
makes no real backend calls and uses no credentials. It reproduces the old policy
blocking the local API before network routing, verifies that the new policy permits
the selected API, and confirms that port 54321 remains blocked by CSP. It also checks
the explicit realtime address and absence of broad HTTP/WS wildcard allowances.
A --static option checks only policy contents, not native browser behavior.

Before delivery, static assertions, JavaScript parsing and clean patch application
were verified. Native browser execution was unavailable in the build environment;
the supplied browser regression must run on the user's installed browser. The full
KYC browser suite must then establish actual application integration. Slow CDN/font
loads or other defects may still appear; this fix does not claim to resolve every
startup symptom or establish successful KYC approval, cash posting or AML detection.

Keep the local Supabase stack and Python server on port 5520 running. No reset or
new dependency installation is required. The full suite creates two fresh synthetic
applications as before; successful approvals remain local. Upload its updated
.coreaml-local/kyc-browser/results.json even if another check fails. If startup still
fails, the existing read-only diagnostic can record the remaining problem.

Reference: https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Security-Policy/connect-src
