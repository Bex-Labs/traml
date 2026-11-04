# Optional investigation graph loading

The native AML browser diagnostic captured the unpkg vis-network script still pending while the dashboard document was loading and its handlers were absent. The graph library was a synchronous script in the document head.

The dashboard now requests that same library only when rendering a nonempty investigation graph. Concurrent renders share a request. A ten-second deadline or load error displays an unavailable message; explicitly reopening the graph retries. Clearing the graph invalidates pending renders. No initialization is forced and no authentication, database, CSP or AML policy changes are made.

Other existing external dashboard assets remain. This fix addresses the captured graph dependency; it does not establish that every other startup dependency is reliable.

Run:

```powershell
node .\scripts\test-investigation-graph-loading.cjs --browser
node .\scripts\test-aml-browser-readiness.cjs
node .\scripts\test-aml-evidence-ui.cjs
node .\scripts\verify-aml-browser-local.cjs --headed
```

The graph test defaults to simulated DOM/library contracts. `--browser` additionally uses the installed Playwright/browser setup and an isolated fixture containing the actual dashboard head, graph renderer and loader. Other assets and the graph library response are synthetic. It proves optional loading, bounded failure and graph rendering integration, not real graph-library correctness, real login or bank isolation. The final verifier separately tests the actual local app with existing sealed synthetic AML evidence and checks unchanged database state.
