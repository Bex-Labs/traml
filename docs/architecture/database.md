# CoreAML Database Architecture

Status: Approved
Owner: CoreAML Team
Version: 1.0
Last Updated: 2026-07-17

## Related ADRs
- ADR-001: Production Database as Baseline

## Related Documents
- database.md
- dependency-map.md

## Overview

CoreAML is a database-driven Anti-Money Laundering (AML) platform built on PostgreSQL and Supabase. The database is responsible for much more than data persistence—it executes the core AML detection engine, sanctions screening, customer risk scoring, audit logging, and real-time alert generation.

The architecture follows an event-driven model where new transactions trigger database functions that evaluate AML rules and create alerts without requiring an external processing service.

---

## Design Principles

The platform is built around the following principles:

- Database-first rule evaluation
- Event-driven processing
- Tenant isolation for multi-tenancy
- Deterministic rule execution
- Full auditability
- Real-time alert generation
- Extensible rule framework

---

## Core Domains

The database is organised into several business domains.

### Customers

Stores customer identity, KYC information, and current risk profile.

### Accounts

Represents customer financial accounts and their relationships.

### Transactions

Stores financial activity and serves as the entry point into the AML engine.

### AML Rules

Contains configurable AML detection rules that are evaluated during transaction processing.

### Alerts

Stores suspicious activity detected by the rule engine.

### Risk

Maintains customer risk scores and historical risk changes.

### Sanctions

Supports sanctions screening against maintained watchlists.

### STR

Stores Suspicious Transaction Reports and regulatory reporting data.

### Audit

Captures authentication events and system activity for traceability.

### Tenants

Provides logical isolation between organisations using the platform.

---

## High-Level Execution Flow

```
New Transaction
       │
       ▼
Database Trigger
       │
       ▼
process_aml_rules()
       │
       ├─────────────► Alert Generation
       │
       ├─────────────► Risk Updates
       │
       ├─────────────► Sanctions Screening
       │
       └─────────────► Audit Trail
```

---

## Primary Components

The current implementation contains several major functional areas.

### Rule Engine

Evaluates configured AML rules against incoming transactions.

### Risk Engine

Maintains customer risk scores based on transactional behaviour and detected alerts.

### Sanctions Engine

Screens transactions and customers against sanctions lists.

### Alert Pipeline

Creates, stores, and exposes AML alerts for analyst investigation.

### Audit Framework

Records security and operational events for compliance.

---

## Database Characteristics

| Characteristic | Value |
|---------------|-------|
| Database | PostgreSQL |
| Platform | Supabase |
| Architecture | Event-driven |
| Rule Evaluation | Database Functions |
| Multi-tenancy | Supported |
| Row Level Security | Enabled |
| Real-time Alerts | Supported |

---

## Current State

The database already provides a strong foundation for AML monitoring.

Strengths include:

- Database-driven processing
- Multi-tenant architecture
- Strong audit capability
- Configurable AML rules
- Integrated sanctions screening
- Risk scoring framework

Areas identified for improvement are documented separately in:

- known-issues.md
- aml-engine.md
- dependency-map.md

---

## Future Direction

The platform will evolve toward a modular rule engine where each AML rule type is evaluated by an independent database function coordinated through a lightweight dispatcher. This approach improves maintainability, testability, and extensibility while preserving the existing event-driven architecture.