# Grouped case and review worklists

The existing Case Management and review queues now share real server-side search, status/owner/date filters, exact matching counts, 25-row pagination, clear filters and refresh/retry. They retain the existing navigation, case workspace and review actions. CoreAML's Bootstrap theme remains the styling source.

Case Management lists validated managed claim groups, once per case reference, instead of one row per alert. It shows the number of alert members, canonical reference, entity, rule, current member status and owner. Historical or unclaimed alerts without a valid managed claim remain in their existing alert and customer views. Counts are explicitly managed groups, not all alerts or regulatory filings. Partial/invalid membership and cross-bank customer links are excluded; mixed statuses have an explicit MIXED label and cannot open an editable workspace. The old assumed 14-day SLA badges are removed: no approved SLA policy has been supplied for these worklists.

The dismissal queue counts complete pending groups across all matching records, rather than deduplicating only a loaded alert sample. The executive queue counts pending internal report packages and preserves each report UUID as its review target. Completed cases and approved reports do not remain in these pending queues. The review function still validates the full canonical snapshot before any decision.

## Authorization and queries

`coreaml_case_worklist` is a new STABLE read-only function, with an empty search_path and qualified tables. It reuses the fingerprinted staff helper to enforce active profiles and trusted JWT app metadata. Officers see only their owned managed cases; compliance heads see managed cases within their bank and can read the review queues. ALL means all authorized owners, not unrestricted bank data for an officer. A peer or another bank cannot discover an owned case using search.

Narrow SECURITY DEFINER access is used to aggregate claim groups and reviewer packages without exposing receipt or claim tables more broadly. PUBLIC and anonymous execution are revoked, authenticated execution is granted, and existing RLS/write functions are unchanged. No caller-selected bank or actor is accepted.

Search is a bounded literal substring over canonical case reference, recorded customer/entity name and rule. Percent, underscore and backslash are escaped on the server; no customer-ID sampling or client-side partial filtering is used. Claims use claim dates; review queues use recorded submission/package dates, with an explicit unavailable date for older records without a submission timestamp. Through-date filters use an exclusive next-day UTC boundary. Deterministic timestamp/ID ordering breaks ties. Counts and page rows come from the same SQL statement snapshot. Pages reflect the current read, not a frozen cross-page dataset; refresh retrieves the latest state.

## UI behaviour

The controls are shared by the three existing tables and use visible labels and keyboard form submission. Applying or clearing filters resets the page. Previous/Next are bounded by the confirmed count; an out-of-date page offers navigation rather than claiming there are no matches globally. An empty match is distinct from a failed read. Failures clear old rows and show Unavailable with a retry; counts are never estimated as zero. Context changes, invalid input and unconfirmed response shapes fail closed. Generations prevent old responses from replacing new filters, and both session checks and data reads have deadlines.

Records use text nodes and bound event handlers. Case actions receive the canonical anchor/reference/customer; reviews receive the canonical QA anchor or executive report ID. Unlinked cases no longer get a View Dossier button pointing at a string null ID. No case is claimed, saved, closed, submitted or approved by searching, paging or filtering.

## Validation

The unit suite checks filters and UTC dates, scope/count/row validation, roles, deadlines, generation changes, text rendering, canonical actions and the native read boundary. The fictional-SDK native browser suite exercises actual case controller/service/DOM search, Next/Previous, clear, errors/retry, literal HTML-looking text, canonical Open Case and both review targets.

Isolated PostgreSQL executes the real function and verifies global grouping of two alert members into one pending QA case, executive report targets, literal wildcard search, exact counts, deterministic pages, status filters and owner/head/peer/foreign-bank authorization. The installer uses the existing retained fixtures and eight read-only checks, with all existing record hashes compared before and after. No new fixtures or business records are inserted.

`verify-case-worklists-local.cjs --headed` uses actual form logins for the owner, compliance head and other-bank officer. It checks one-row grouping, canonical closed-case opening, search/status/owner/UTC-date filters, clear empty states, visible invalid dates, head grouped counts and removal from pending queues, and other-bank exclusion. All workflow mutations remain blocked and all original record hashes must remain unchanged. No completed write acceptance needs to be replayed.
