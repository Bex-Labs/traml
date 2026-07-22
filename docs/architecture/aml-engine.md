# AML Rule Engine Architecture

Status: Approved
Owner: CoreAML Team
Version: 1.0
Last Updated: 2026-07-17

## Related ADRs
- ADR-001: Production Database as Baseline

## Related Documents
- database.md
- dependency-map.md

## Purpose

The AML Rule Engine is responsible for evaluating financial transactions against configured Anti-Money Laundering (AML) rules and generating alerts for suspicious activity.

The current implementation is database-driven, with rule evaluation occurring automatically whenever new transactions are inserted into the system.

---

# Objectives

The rule engine is designed to:

- Detect suspicious financial behaviour
- Execute configurable AML rules
- Generate alerts in real time
- Update customer risk profiles
- Support multi-tenant deployments
- Provide deterministic rule execution
- Maintain complete auditability

---

# Current Execution Flow

```
Transaction Insert
        │
        ▼
AFTER INSERT Trigger
        │
        ▼
process_aml_rules()
        │
        ▼
Load Customer
        │
        ▼
Load Account
        │
        ▼
Load Active Rules
        │
        ▼
Evaluate Rule
        │
        ▼
Create Alert
        │
        ▼
Update Risk
```

---

# Current Rule Types

The production database currently supports the following configurable rule types.

| Rule Type | Status |
|------------|--------|
| AMOUNT_ABOVE | Implemented |
| STRUCTURING_PATTERN | Configuration exists |
| VELOCITY_COUNT | Configuration exists |
| STATIC_THRESHOLD | Configuration exists |
| BEHAVIORAL_VELOCITY | Configuration exists |

Only `AMOUNT_ABOVE` is currently executed by the production rule engine.

The remaining rule types are present within the rule configuration but require implementation within the evaluation engine.

---

# Rule Evaluation

The current engine performs the following high-level process.

1. Receive newly inserted transaction.
2. Identify the associated account.
3. Load the customer.
4. Retrieve active AML rules.
5. Evaluate supported rule conditions.
6. Generate alerts for matching rules.
7. Persist alert records.
8. Trigger downstream risk updates.

---

# Strengths

The current implementation already provides:

- Event-driven execution
- Configurable rule storage
- Database-level processing
- Multi-tenant support
- Alert generation
- Risk integration
- Real-time execution

---

# Current Limitations

The current implementation has several known limitations.

## Single Implemented Evaluator

Only `AMOUNT_ABOVE` is currently evaluated.

## Dispatcher Logic

The dispatcher directly evaluates rule conditions rather than delegating to specialised evaluator functions.

## Global Rule Evaluation

Global rules are not evaluated consistently alongside tenant-specific rules.

## Alert Context

Alert records currently omit some contextual information, such as transaction linkage, reducing traceability.

These limitations are tracked separately in `known-issues.md`.

---

# Rule Engine V2

The planned architecture replaces the monolithic evaluator with a modular dispatcher.

```
Transaction
      │
      ▼
process_aml_rules()
      │
      ▼
Rule Dispatcher
      │
      ├──────── evaluate_amount()
      ├──────── evaluate_velocity()
      ├──────── evaluate_structuring()
      ├──────── evaluate_behavior()
      └──────── evaluate_custom()
              │
              ▼
        Alert Factory
              │
              ▼
        Risk Engine
```

Each evaluator is responsible for exactly one detection strategy.

This design improves:

- Maintainability
- Unit testing
- Rule extensibility
- Performance optimisation
- Future machine-learning integration

---

# Design Principles

Future development of the AML engine will follow these principles.

- Single responsibility per evaluator
- Configuration-driven rule execution
- Deterministic behaviour
- Clear separation between evaluation and alert creation
- Independent testing of each rule type
- Backward compatibility where possible