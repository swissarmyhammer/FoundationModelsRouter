---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0fggss1y79za6yh8qqpqdbs
  text: 'From the Multitool session, 2026-08-20: the contract does NOT require a call to the shared workflow. It documents the expectations and two accepted shapes; the shared swift-ci.yaml is a convenience, not a mandate. Repo-local jobs with `needs: test` satisfy expectation 4. The authority is the workflows README at commit f7b504f (origin/main 5f7e9a5). Verify against that document; do not chase a shared-workflow gap.'
  timestamp: 2026-08-20T11:57:19.521319+00:00
position_column: todo
position_ordinal: '80'
title: Verify this package against the org test expectations after the workflows README lands
---
Filed on a request from the FoundationModelsMultitool session, on the user's directive: every sibling package must comply with the org's new test expectations, documented in the swissarmyhammer/workflows README (push imminent from the workflows-06 session).

This repository already shipped the nested-package shape on 2026-08-20 (tasks ^ryb01x7 and ^g5ghfgm, commits 1db2b56 and 731a7ba). This card verifies the shipped state against the FINAL documented expectations once the README lands, and closes any gap.

## What

Read the four expectations in the swissarmyhammer/workflows README (fetch the pushed version). Verify each against this repository:

1. Root `swift test` runs every unit test and only unit tests — currently 1023 tests in `FoundationModelsRouterTests` plus 77 in `FoundationModelsRouterEvals`, with zero integration suites in the run and zero `.enabled(if:)` gates.
2. Integration tests run as an explicit target — `swift test --package-path IntegrationTests` runs the nested package at `IntegrationTests/Package.swift`.
3. No environment-variable selection — `rg 'FM_ROUTER_'` over the repository finds nothing.
4. CI runs unit before integration — `.github/workflows/ci.yml` orders the real-model job after the unit job with `needs:`.

If the final README states an expectation the shipped state does not meet (for example a required use of the shared workflow's new `integration-filter`/`integration-skip` inputs instead of a repo-local job), fix exactly that gap.

## Acceptance Criteria

- [ ] Each of the four documented expectations is verified against the current tree, with the command and its output recorded on this card
- [ ] Any gap between the shipped state and the final README is fixed, or recorded as a deliberate deviation with the reason

## Tests

- [ ] Root `swift test` — green at the unit-only baseline, zero integration suites listed in the run
- [ ] `swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests` — green, proving the integration package is selectable and runs
- [ ] `rg 'FM_ROUTER_' --glob '!.build' --glob '!.kanban'` — zero matches

## Workflow

- Use `/tdd` for any code gap found — write the failing check first, then fix. #ci #test-debt #tests