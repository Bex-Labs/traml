# BexAML — Transaction Monitoring & AML Compliance

A rule-based AML compliance tool built for Nigerian microfinance banks. Ingests transaction data, evaluates it against a library of typology rules, and surfaces alerts for analyst review via the BexAML dashboard.

---

## Stack

| Layer | Technology |
|---|---|
| Frontend | HTML / Bootstrap 5 / Chart.js |
| Backend DB | Supabase (PostgreSQL) |
| Rule Engine | Python (pandas) |
| Auth | Supabase Auth + MFA |
| Edge Functions | Supabase Edge Functions (Deno) |

---

## Project Structure

```
aml_engine.py            — Core rule evaluation engine (runs batch scans)
ingest_data.py           — One-time CSV → Supabase ingestion script
generate_transactions.py — Synthetic transaction data generator
seed_master.py           — Seeds minimal test data for local dev
seed_typologies.py       — Injects known AML typologies for testing
trigger_smurfing.py      — Dev tool: injects smurfing patterns into test DB
dashboard.html           — Main analyst triage workspace
compliance-audit.html    — Head of Compliance view
admin-dashboard.html     — Admin tools (typology injection, system config)
audit-logs.html          — Full audit trail
user-management.html     — User and role management
role-management.html     — Role permission configuration
```

---

## Running the AML Engine

Requires a `.env` file in the project root:

```
SUPABASE_URL=https://<your-ref>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>
```

Then run:

```bash
pip install -r requirements.txt
python aml_engine.py
```

The engine will fetch all transactions from Supabase, evaluate them against the active rule library, write generated alerts directly to the `alerts` table, and save a local CSV backup.

---

## AML Rule Library

| Rule ID | Name | Typology | Severity |
|---|---|---|---|
| R-001A | High Value Single Transaction | NFIU reporting threshold (₦5M) | HIGH |
| R-001B | High Value Cumulative Daily | Aggregated daily volume ≥ ₦10M | CRITICAL |
| R-002 | Structuring / Smurfing (TAML-52) | Multiple transactions just under ₦5M within 24h | CRITICAL |
| R-003 | High Velocity Account (TAML-50) | ≥15 transactions within a 24h rolling window | MEDIUM |
| R-004 | Round-Tripping (TAML-53) | Large debit returned as credit (90–105%) within 24h | CRITICAL |
| R-005 | KYC Gap — Unverified Customer | Customer KYC status is not VERIFIED; transacting above ₦50k | HIGH |
| R-006 | OFAC SDN Watchlist Hit | Counterparty name fuzzy-matches the OFAC SDN list (≥85% similarity) | CRITICAL |
| R-007 | OpenSanctions Watchlist Hit | Customer entity name matches OpenSanctions (OFAC + UN + EU + PEPs, score ≥85%) | CRITICAL |

---

## Alerts Table Schema

Alerts written to Supabase use this shape:

| Column | Description |
|---|---|
| `alert_ref` | Unique human-readable reference (e.g. `ALT-A1B2C3`) |
| `customer_id` | FK → customers |
| `transaction_id` | FK → transactions (NULL for multi-transaction alerts) |
| `rule_triggered` | Rule name string |
| `severity` | `MEDIUM` / `HIGH` / `CRITICAL` |
| `status` | `UNASSIGNED` on creation; analysts update to `ESCALATED` / `CLOSED` etc. |
| `details` | Human-readable description of why the alert fired |

---

## Changelog

### 2026-06-06 (update 3)

**`aml_engine.py` — R-006 OFAC SDN screening + R-007 OpenSanctions screening**

Two new watchlist rules added. Both fire `CRITICAL` severity alerts.

**R-006: OFAC SDN Watchlist (counterparty screening)**
At engine startup, `load_ofac_sdn()` downloads the OFAC Specially Designated Nationals CSV directly from the US Treasury (public, no API key needed). Every unique `counterparty_name` in the transaction batch is then fuzzy-matched against the ~10,000 SDN entries using `rapidfuzz` with a `token_sort_ratio` scorer. Any match at ≥85% similarity triggers an alert per affected transaction. The threshold is configurable in `RULE_CONFIG['watchlist_fuzzy_threshold']`. If the OFAC download fails (e.g. network issue), R-006 is skipped and the engine continues normally.

**R-007: OpenSanctions Watchlist (customer screening)**
`screen_via_opensanctions()` sends all customer entity names to the OpenSanctions matching API, which aggregates OFAC, UN Security Council, EU, UK HMT, and ~100 other lists including global PEP databases. Names are batched in groups of 50 to stay within API rate limits. Any match with a confidence score ≥85% fires a CRITICAL alert, with the matched entity name, score, and risk topics (e.g. `sanction`, `pep`, `crime`) included in the alert details.

Requires `OPENSANCTIONS_API_KEY` in `.env` — free for non-commercial use (sign up at opensanctions.org). If the key is absent, R-007 is skipped with a warning. The `.env.example` file has been updated with the new variable.

New pip dependencies: `requests`, `rapidfuzz` (add to your `pip install` command).

---

### 2026-06-06 (update 2)

**`aml_engine.py` — alert deduplication**

`write_alerts_to_db()` now queries today's existing alerts before inserting. Any alert with the same `(customer_id, rule_triggered)` combination already raised today is skipped, so running the engine multiple times in a day no longer produces duplicate alerts in the dashboard. A comment in the function also provides the SQL for an optional DB-level unique index as a belt-and-suspenders measure:
```sql
CREATE UNIQUE INDEX IF NOT EXISTS uq_alert_customer_rule_day
ON alerts (customer_id, rule_triggered, (created_at::date));
```

**`dashboard.html` — NFIU SAR PDF generator**

Analysts can now download a pre-filled NFIU Suspicious Transaction Report (Form NFIU/STR/001) PDF directly from the SAR filing modal. A "Download SAR PDF" button sits in the modal footer alongside the existing submit button. Clicking it fetches the full alert and customer record from Supabase, and generates a formatted PDF via jsPDF covering all six NFIU STR sections:
- Section A: Reporting Institution
- Section B: Subject of Report (entity name, customer type, BVN/RC, address, risk tier, PEP/KYC status)
- Section C: Suspicious Activity Details (typology, severity, system description)
- Section D: Investigation Findings (officer's notes from the modal)
- Section E: Recommended Action
- Section F: Officer Declaration + signature lines

The PDF downloads automatically as `SAR_<alert_ref>_<date>.pdf`. The button can be clicked before or after filling in the investigation notes — notes are included in the PDF at the time of download.

---

### 2026-06-06 (update 1)

**`aml_engine.py` — v1.4**

Three changes shipped. No other files modified.

**1. Alerts now write directly to Supabase**

Previously the engine saved alerts to a local CSV file only, meaning the dashboard never reflected engine output. The engine now calls `write_alerts_to_db()` after each scan, which:
- Builds an `account_id → customer_id` lookup from the accounts table (the alerts table stores `customer_id`, not `account_id`)
- Builds a `transaction_reference → transaction_id` lookup for single-transaction alerts
- Transforms each alert to match the `alerts` table schema (`alert_ref`, `customer_id`, `transaction_id`, `rule_triggered`, `severity`, `status`, `details`)
- Batch-inserts in chunks of 1,000 rows
- The CSV backup is still written as a local fallback

**2. New rule R-005: KYC Gap Detection**

Flags any account belonging to a customer whose `kyc_status` is not `VERIFIED`, if that account has transactions above the CBN Tier 1 threshold (₦50,000). One alert is raised per account (not per transaction) to avoid alert fatigue. Severity: `HIGH`.

Requires the `kyc_status` column to exist on the `customers` table. Run this once in the Supabase SQL editor before executing the engine:

```sql
ALTER TABLE customers
ADD COLUMN IF NOT EXISTS kyc_status TEXT NOT NULL DEFAULT 'PENDING';
```

All existing customers will default to `PENDING`. Update verified customers to `VERIFIED` manually or via your onboarding workflow. If the column is missing, R-005 is skipped with a warning rather than crashing the engine.

**3. Credentials loaded from environment**

The Supabase service role key was previously hardcoded in the source file. It now loads from the `.env` file via `python-dotenv`, consistent with how `seed_master.py` already handled this. The engine exits with a clear error if the env vars are missing.

> ⚠️ The old key was committed to the repo and should be rotated in the Supabase dashboard — Settings → API → Regenerate service_role key.

**Pagination fix**

The transaction fetch loop previously had a hardcoded `while start < 20000` cap. It has been replaced with a `fetch_all_rows()` helper that runs until Supabase returns an empty page, so the engine won't silently miss transactions as the dataset grows.
