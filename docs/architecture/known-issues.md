# Known Issues

Status: Approved
Owner: CoreAML Team
Version: 1.0
Last Updated: 2026-07-17

## Related Documents

- database.md
- aml-engine.md
- dependency-map.md

---

# Purpose

This document tracks known architectural and implementation limitations within the CoreAML platform.

These issues represent technical debt identified during the architecture review and baseline capture phases.

Every issue should eventually be linked to a development task, pull request, or release milestone.

---

# Priority Definitions

| Priority | Meaning |
|----------|---------|
| Critical | Prevents correct AML detection or compromises system integrity. |
| High | Significantly impacts AML capabilities or maintainability. |
| Medium | Reduces usability or increases technical debt. |
| Low | Minor enhancement or optimisation. |

---

# AML-001

## Title

STRUCTURING_PATTERN evaluator not implemented

### Current State

The rule type exists within the `aml_rules` configuration but is not evaluated by `process_aml_rules()`.

### Desired State

Transactions should be evaluated for structuring behaviour using rolling transaction statistics and configurable thresholds.

### Impact

High

Structuring is a core AML detection requirement and currently cannot generate alerts.

### Planned Release

AML-0010

### Status

Open

---

# AML-002

## Title

VELOCITY_COUNT evaluator not implemented

### Current State

Velocity rules are configurable but are ignored during rule execution.

### Desired State

Support configurable transaction frequency detection using rolling windows.

### Impact

High

### Planned Release

AML-0010

### Status

Open

---

# AML-003

## Title

STATIC_THRESHOLD evaluator missing

### Current State

Static threshold rules exist only as configuration.

### Desired State

Evaluate configurable thresholds independently of amount-based rules.

### Impact

Medium

### Planned Release

AML-0010

### Status

Open

---

# AML-004

## Title

BEHAVIORAL_VELOCITY evaluator missing

### Current State

Behavioural velocity rules are not executed.

### Desired State

Support customer-specific behavioural baselines.

### Impact

High

### Planned Release

AML-0020

### Status

Open

---

# AML-005

## Title

Global AML rules are not evaluated consistently

### Current State

Rule evaluation focuses on tenant-specific rules.

### Desired State

Support both global and tenant-specific rule evaluation.

### Impact

High

### Planned Release

AML-0010

### Status

Open

---

# AML-006

## Title

Alert records should reference originating transaction

### Current State

Alerts do not consistently retain a direct transaction reference.

### Desired State

Every alert should reference the transaction that triggered it.

### Impact

Medium

### Planned Release

AML-0010

### Status

Open

---

# AML-007

## Title

Duplicate customer risk calculation workflows

### Current State

Multiple functions contribute to customer risk scoring.

### Desired State

Consolidate risk calculation into a single authoritative workflow.

### Impact

Medium

### Planned Release

AML-0040

### Status

Open

---

# AML-008

## Title

Monolithic rule dispatcher

### Current State

`process_aml_rules()` performs both orchestration and rule evaluation.

### Desired State

Use specialised evaluator functions coordinated by a lightweight dispatcher.

### Impact

High

### Planned Release

AML-0010

### Status

Open

---

# AML-009

## Title

Rule evaluation lacks standardised testing

### Current State

No documented regression suite exists for AML rule behaviour.

### Desired State

Provide repeatable tests for every evaluator.

### Impact

High

### Planned Release

AML-0050

### Status

Open

---

# AML-010

## Title

Architecture documentation requires ongoing maintenance

### Current State

Architecture documentation has been introduced but must evolve alongside implementation.

### Desired State

Every architectural change updates the relevant documentation before merge approval.

### Impact

Medium

### Planned Release

Continuous

### Status

Open

---

# Release Roadmap

| Release | Focus |
|----------|-------|
| AML-0010 | Rule Engine V2 |
| AML-0020 | Behavioural Detection |
| AML-0030 | Alert Pipeline |
| AML-0040 | Risk Engine Consolidation |
| AML-0050 | Automated Testing |
| AML-0060 | Performance Optimisation |

---

# Maintenance

This document must be reviewed before each development sprint.

Issues should only be closed after:

- Implementation completed
- Testing completed
- Documentation updated
- Pull request merged