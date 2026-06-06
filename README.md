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
pip install pandas supabase python-dotenv
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

### 2026-06-06

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
