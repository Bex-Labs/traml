# Information trust corrections

This patch builds on feature consolidation and changes displayed information and read paths. It creates no database records, schema migrations, claims, evaluations or filings.

## Recorded information versus inference

- Graph counterparties use recorded fields. Missing identities remain unknown and are separate per transaction unless a bank and account are both recorded. A transaction is not attributed to the first pinned subject; recorded ownership or account references are required. Unknown direction is undirected, and missing amounts are not zero. Currency and fractional amounts retain their recorded presentation.
- The case detection summary preserves recorded explanations, escapes record text and labels legacy engine commentary as commentary. It does not invent an evasion finding or infer a financial aggregate from free-text alert amounts.
- AI failure, timeout or malformed output preserves findings and produces no substitute narrative. Success is an unverified suggestion in a separate preview. An explicit Use reviewed draft action inserts it only if the original findings and evidence context remain unchanged. Closing the modal invalidates pending output. Applying a suggestion performs no save or submission. This does not validate the factual accuracy of a provider-generated suggestion; officers must review it against evidence.

## Dashboard definitions

| Display | Definition |
| --- | --- |
| Alerts created (30d UTC) | Alerts in the current UTC day and previous 29 calendar days, up to the refresh instant |
| Alerts linked to cases (30d) | Percentage of that period's alerts with a recorded case reference; not case count divided by alert count |
| Recorded alert statuses | Separate raw statuses across all readable alert records |
| Workload/open/closed case totals | Distinct recorded case references with consistent ownership and status; ungrouped or inconsistent records are disclosed and excluded |
| Cases with alerts aged 48h+ | Officer's grouped investigating cases containing an alert older than 48 hours; not an SLA promise |
| High-risk customers | HIGH plus VERY_HIGH |
| Customers with recorded risk | Percentage with LOW, MEDIUM, HIGH or VERY_HIGH; not a compliance score |
| Filing rate, confirmed SAR submissions, average resolution time, confirmed false-positive rate | Unavailable until authoritative outcome/timing records are connected; closure/escalation is not proof of submission |

Empty measured counts are zero. Unknown percentages with no denominator, failed reads and unsupported metrics remain unavailable. Team directory workload uses the same grouped definition and does not call closed cases resolved reports. Audit-event recency is labelled recently active, not online presence.

Analytics reads have a 20-second overall deadline, exact count, explicit tenant filter and stable 500-row pages. Duplicates, count changes, incomplete reads and datasets over 10,000 records are rejected rather than presented as complete totals. Requests recheck verified user/bank/role. These are on-demand sequential reads, not an atomic reporting snapshot; production-scale reporting should use appropriately authorized server-side aggregates. Chart-library failure does not suppress measured numeric values. Query failure clears stale values.

## Verification scope

- `test-information-trust.cjs`: deterministic model/service checks and actual extracted AI/graph/controller handlers with SDK/library mocks. It makes no external AI requests or database writes.
- `test-information-trust-browser.cjs`: real browser execution of actual dashboard markup, controllers and handlers with fictional SDK records, captured graph data and a Bootstrap surface stub. It verifies UI interaction, not the external AI provider or real graph library.
- Existing workflow, intelligence data, graph loading and consolidated browser regressions remain applicable.
- `verify-intelligence-local.cjs --headed`: the read-only local two-bank harness now also checks actual officer totals against database grouping, in addition to canonical screens, linked evidence, cross-bank denial and unchanged persistent state. It does not provision executive accounts or invoke external AI. Existing completed acceptance fixtures are not reset or replayed.

QA approvals, regulatory delivery receipts, report scheduling, exports, deployment and the remaining enterprise review items are separate work. Their presence in the interface is not proof of end-to-end verification by this patch.
