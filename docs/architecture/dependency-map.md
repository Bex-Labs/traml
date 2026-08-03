# Database Dependency Map

Status: Approved
Owner: CoreAML Team
Version: 1.0
Last Updated: 2026-07-17

## Related ADRs

- ADR-001: Production Database as Baseline

## Related Documents

- database.md
- aml-engine.md

---

# Purpose

This document describes the relationships between database triggers, PostgreSQL functions, and core business tables within the CoreAML platform.

Its primary purpose is to provide a clear dependency map before modifying any production database logic.

This document should always be reviewed before refactoring database functions or introducing new AML detection capabilities.

---

# Current Architecture

The current platform follows an event-driven execution model.

```text
                    New Transaction
                           │
                           ▼
                  INSERT INTO transactions
                           │
                           ▼
                  AFTER INSERT Trigger
                           │
                           ▼
                  process_aml_rules()
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
     Load Rules      Evaluate Rules     Create Alerts
         │                 │                 │
         ▼                 ▼                 ▼
    aml_rules         customers        alerts
                           │
                           ▼
                  Risk Score Updates
                           │
                           ▼
                     customers

# High-Level Execution Flow

```
Incoming Transaction
        │
        ▼
transactions
        │
        ▼
AFTER INSERT Trigger
        │
        ▼
process_aml_rules()
        │
        ├──────────────► alerts
        │
        ├──────────────► aml_rules
        │
        ├──────────────► customers
        │
        ├──────────────► accounts
        │
        ├──────────────► risk scoring
        │
        └──────────────► sanctions screening
```

---

# Trigger Dependencies

| Trigger | Table | Calls |
|----------|-------|-------|
| process_aml_rules | transactions | process_aml_rules() |
| sanctions trigger | transactions | screen_transactions_for_sanctions() |
| risk trigger | transactions | update_customer_risk_score() |
| network trigger | transactions | propagate_network_contagion() |

---

# Function Dependencies

## process_aml_rules()

Reads:

- transactions
- accounts
- customers
- aml_rules

Writes:

- alerts

Invokes:

- Risk update workflow

---

## update_customer_risk_score()

Reads:

- alerts
- customers

Writes:

- customers

---

## recalculate_customer_risk()

Reads:

- transactions
- alerts

Writes:

- customers

---

## propagate_network_contagion()

Reads:

- accounts
- transactions

Writes:

- customer risk

---

## screen_transactions_for_sanctions()

Reads:

- sanctions_watchlist
- customers
- transactions

Writes:

- alerts (when required)

---

# Core Business Tables

| Table | Purpose |
|--------|---------|
| customers | Customer master data |
| accounts | Financial accounts |
| transactions | Financial activity |
| aml_rules | Configurable AML rules |
| alerts | Suspicious activity alerts |
| sanctions_watchlist | Sanctions data |
| suspicious_transaction_reports | Regulatory reporting |
| risk_score_history | Historical risk changes |
| audit_logs | Security and audit records |

---

# External Dependencies

The database currently has no external rule evaluation service.

All AML processing is performed inside PostgreSQL.

---

# Planned Changes

The dependency graph will evolve during Rule Engine V2.

Future changes include:

- Modular rule evaluators
- Alert Factory
- Rule Dispatcher
- Shared evaluation library