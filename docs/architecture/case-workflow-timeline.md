# Case workflow history

The existing Investigation Timeline is replaced with Case Workflow History. The former panel showed customer alerts; original detection evidence remains in the case context instead of being duplicated in another navigation tab.

The same timeline component is used in the workspace, dismissal/executive review dialogs, and the View case history action on existing submission cards. It displays claim records and immutable case-action, submission and decision receipts. Notes are the recorded review feedback; saved narratives remain in their existing case and receipt views. Actor names are explicitly current profile labels, with the recorded UUID shown alongside them. Older activity without managed receipts is not reconstructed or described as a complete historical audit.

## Read boundary

`coreaml_case_timeline` is a STABLE read-only function. Its narrowly scoped SECURITY DEFINER access is required because makers cannot read reviewer receipt tables directly. It reuses the fingerprinted staff authorization helper, verifies active profile/trusted JWT role and bank, then allows only the case owner or a head of compliance in the same bank. Current complete claim membership, bank, assigned owner, case reference and linked customer scope are checked. Pending, returned, closed and internally approved cases remain readable without reopening or changing them.

The function exposes no caller-selected actor, bank or case membership parameters. Anonymous and PUBLIC execution is revoked, authenticated execution is granted, and search_path is empty with qualified tables. Existing RLS policies and workflow functions are not changed.

Entries are newest first, using timestamp plus unique source/record key for deterministic ordering. Each page defaults to 25 entries and is capped at 50. The cursor retains PostgreSQL microseconds unchanged. The server returns an explicit next cursor and has_more flag; the controller appends older pages only when the user asks. Refresh starts a new snapshot. No client timestamp is used to create history or infer a filing.

## UI behaviour

The service bounds context verification and data reads, rechecks the verified context before returning, and validates the canonical case, actor, bank, membership, event kinds and pagination shape. The controller renders all names, labels and feedback with text nodes. Late replies cannot replace another case or a closed dialog. A failed refresh clears stale history and shows a retryable error; an older-page failure retains already confirmed entries with an explicit error. A history failure does not prevent the case's existing save/review logic from operating.

Opening a case loads history, confirmed workspace saves refresh it, and confirmed review decisions refresh the review history. Unconfirmed mutation replies do not create timeline entries in the browser. The server receipt is the source. Initial dashboard startup does not load a case timeline.

## Local install and verification

`apply-case-timeline-local.cjs` installs only the new read function. Its eight checks use the already retained synthetic QA and executive cases: six QA entries and three executive entries, canonical member lookup, owner/head access, peer/other-bank/forged-bank denial, bounded keyset pagination, invalid inputs and anonymous privilege checks. No new fixtures or business records are inserted. Existing record hashes must match before and after installation. Rechecks require the exact installed source body and function configuration.

`test-case-timeline.cjs` covers service validation, deadlines, context changes, text rendering, stale replies, duplicate pages, read-only harness limits and actual integration. `test-case-timeline-browser.cjs` exercises actual DOM/service/controller behaviour with fictional SDK records, including 25+1 paging and literal HTML-looking feedback. It is not signed-in bank-policy acceptance.

`verify-case-timeline-local.cjs --headed` verifies actual form logins for the owner, same-bank head and other-bank officer. It checks the closed case timeline, the approved executive receipt's history modal, head read-only access and rejection of other-bank direct references. Its network boundary permits only fixture timeline reads alongside the established local authentication/read operations; all workflow writes remain blocked. All retained records, receipts, audits, financial, risk and profile state are compared byte-for-byte by record hashes, and browser sessions are signed out through the server.

This feature creates no report, regulatory XML, filing receipt, workflow action or reconstructed event. It does not require resetting or rerunning the completed maker/checker acceptance fixtures.
