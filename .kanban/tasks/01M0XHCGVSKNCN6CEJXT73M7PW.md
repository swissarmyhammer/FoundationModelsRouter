---
assignees:
- claude-code
depends_on:
- 01M0XGSGZHRNAFH48D4DMTTQZ1
position_column: todo
position_ordinal: '8880'
title: 'Multitool: purge waitSeconds from sources and tests'
---
## What
Cross-repo task in `../FoundationModelsMultitool`. Second of three. Remove every `waitSeconds` parameter, argument, and mention from `Sources/`, `Tests/`, and `IntegrationTests/` (12 files) — the Router engine no longer has it. Keep `timeout` pass-through where a caller bounds work. Rename the "Elevation"-vocabulary test files (`IntegrationTests/Tests/FoundationModelsMultitoolIntegrationTests/ElevationTests.swift`, `Support/ShellElevationRunner.swift`) to the background vocabulary, and update the pending-envelope test cases: they become always-handle cases.

## Acceptance Criteria
- [ ] `rg 'waitSeconds' Sources Tests IntegrationTests` in FoundationModelsMultitool returns no match.
- [ ] `rg -il 'elevat' Sources Tests IntegrationTests` returns no match.
- [ ] The Multitool test suite and IntegrationTests are green.

## Tests
- [ ] Updated existing suites; no new behavior. Run `swift test` in `../FoundationModelsMultitool` — green.

## Workflow
- Use `/tdd` — run the suites before and after each file group. #long-running #cleanup