# Review ageing and recorded-severity prioritisation

The existing case and review worklists now show elapsed waiting time, highest recorded member severity and timestamp quality. They offer newest/oldest ordering, active-waiting/severity/longest-waiting ordering, severity filters, elapsed-hour filters and active-waiting-only selection. Review queues default to oldest recorded submissions first. No tab, background workflow, risk-score update or automatic escalation is introduced.

## Timing basis

Investigation age is measured from the recorded claim. Dismissal review age uses the submission receipt linked to the current SUBMITTED draft ID and revision, with the latest expected revision as the ordering authority. A return followed by a new save/submission starts a new review cycle; an older receipt is not used as its clock. Executive review age uses the pending package creation time. The general case worklist links that package to the current submitted draft version before inferring its review state.

Closed cases have no active waiting timer. Approved executive packages are labelled Review complete / internal preparation and have no active review timer. Missing or unmatched current submission timestamps remain unavailable; timestamps ahead of the database clock are explicitly flagged. Neither state becomes zero waiting time. Elapsed-hour filters exclude unavailable/future times rather than inventing elapsed durations.

All rows are calculated from one database transaction timestamp. The UI shows that server snapshot in UTC and refreshes elapsed values on a new read. Browser clock changes do not alter the displayed duration. Displayed days are calendar days of 24 hours, not business days.

No agreed SLA or escalation policy was supplied. The 24-hour, 72-hour and 7-day choices are descriptive elapsed-time filters, not deadlines. No row is labelled overdue, in breach or compliant on this basis. A later SLA implementation needs an agreed bank policy, calendar and effective version.

## Priority basis

Severity is the maximum recorded value across all validated alert members, not only the anchor alert: CRITICAL, HIGH, MEDIUM, LOW. Null/unrecognised member values are counted and shown as unavailable. The Any member severity missing filter includes partially recorded groups as well as entirely unknown groups.

The priority ordering places active waiting work first, then recorded severity, then oldest waiting timestamp, with a deterministic record-ID tie break. Entirely unrecorded severity ranks after known severity and remains visibly flagged. This is a transparent ordering of stored fields, not an AI risk score or regulatory assessment. It does not change customer risk, alert severity or case ownership.

## Access and compatibility

The new `coreaml_case_worklist_priority` endpoint retains the existing active-profile/trusted-app-metadata bank boundary, owner/head rules, complete group validation and independent-head review filtering. It is STABLE and read-only, uses an empty search_path, accepts only bounded filters and pagination, and revokes PUBLIC/anonymous execution. Existing RLS and write functions are unchanged.

The previous eight-argument worklist endpoint is preserved for older clients and existing source checks. The updated UI uses the new endpoint explicitly. Client response validation requires the server timestamp, requested sort, recorded severity/rank and coherent age/basis/quality fields. Missing metadata is an error, not a fallback to a browser-calculated timer. Context changes, stale replies, read failures and retry behaviour retain their existing safeguards.

The existing read-only worklist and timeline browser boundaries now allow the new bounded read endpoint; all workflow mutations remain blocked.

## Validation and installation

`test-review-ageing.cjs` covers filter bounds, review defaults, server-based durations, contradictory metadata, unknown/future timestamps, completed timers, controls and read boundaries. Existing worklist service/controller regressions are updated with explicit age metadata. Native fictional-SDK browser checks cover sorting, active/severity filters, missing/future warnings and existing search/paging/error/action behaviour.

Isolated PostgreSQL executes the real SQL: a current two-hour resubmission is used instead of an older 100-hour receipt; a CRITICAL non-anchor member determines the recorded group severity; a 72-hour filter selects the older executive package; future/missing times stay unavailable; unknown member severity is counted. These deliberately varied records exist only in a rolled-back isolated test transaction.

`apply-review-ageing-local.cjs` installs only the read function and performs eight read-only checks against retained completed fixtures. It checks completed clocks, severity, sort/paging, age filters, authorization and anonymous denial, with all existing record hashes unchanged. It inserts no fixtures or workflow records.

`verify-review-ageing-local.cjs --headed` verifies actual form logins for owner/head/other-bank sessions, retains the grouped-worklist checks, and confirms no active timers for the closed QA/approved executive fixtures, severity filtering, oldest ordering, explicit server snapshot and the absence of assumed overdue labels. It creates no records and repeats no workflow decisions. Positive active-wait, reset and malformed-time cases are separately exercised in isolated SQL and fictional-SDK browser checks.

The complete start-to-finish demo guide remains a later deliverable after the remaining implementation is complete. This document records this feature's actual behaviour and limits for that guide.
