---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3seh090s0319k26wd0mb9rk
  text: 'Research: `swift package --manifest-cache local update FoundationModelsExtras` in root and IntegrationTests resolves Extras main at c5ca65a (42ca5b5 is its parent). Only one site names `InMemoryLogHandler.Entry`: `EnterRecordTests.text(of:key:)`. `LogAssertions.swift` reads `logRecords` with no type name, so it compiles with no change. IntegrationTests has no `logRecords` use. RED: `swift build --build-tests` failed with "cannot convert value of type ''TelemetryCapture.LogRecord'' to expected argument type ''InMemoryLogHandler.Entry''". Change: the parameter type is now `TelemetryCapture.LogRecord`, and the unused `import InMemoryLogging` is removed. The build writes "warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle" from the build system; it is not from a source file.'
  timestamp: 2026-09-30T15:21:58.816276+00:00
- actor: claude-code
  id: 01m3sgcyzxpzaxwp7zcv1v7d3c
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/EnterRecordTests.swift. Extras resolves at c5ca65a (after 42ca5b5) in Package.resolved and IntegrationTests/Package.resolved. `swift test` exit 0: 1427 tests in 178 suites (2 known issues), 23 tests in 11 suites, 19 tests in 3 suites. `swift test --package-path IntegrationTests --filter FoundationModelsRouterIntegrationTests`: 49 tests in 22 suites passed. `--filter FoundationModelsRouterEvalIntegrationTests`: 1 test in 1 suite passed. Only warning line is the known build-system "missing creator for mutated node" for mlx-swift_Cmlx.bundle.
    - next: review. The CI box stays open until a push.
  timestamp: 2026-09-30T15:54:43.581623+00:00
- actor: claude-code
  id: 01m3sghsctbs6jn73wbsxybsxd
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (8c57251): 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. 1 file reviewed. 2 .kanban files are excluded by .reviewignore.
    - next: The task is in done. The acceptance item "CI is green on the pushed commit" is not checked. Push the commit and check CI.
  timestamp: 2026-09-30T15:57:21.690686+00:00
position_column: done
position_ordinal: ffffffbd80
title: 'Adopt Extras 42ca5b5: TelemetryCapture log records are TelemetryCapture.LogRecord'
---
## What
FoundationModelsExtras 42ca5b5 changes TelemetryTestSupport:
- `TelemetryCapture.Context.logRecords` now gives `[TelemetryCapture.LogRecord]`, not `[InMemoryLogHandler.Entry]`.
- `LogRecord` has `level`, `message`, `error`, `metadata` and a new `label` (the label of the logger that wrote the record). It is `Equatable` and `Sendable`.

Router CI resolves Extras main (Package.resolved is not in git), so Router CI does not compile until the Router changes.

## Steps
- Stop this repo's sourcekit-lsp, then `swift package --manifest-cache local update FoundationModelsExtras` in the root and in `IntegrationTests`. Confirm the revision is 42ca5b5 or later.
- Change each use of `InMemoryLogHandler.Entry` that reads `logRecords` to `TelemetryCapture.LogRecord`. A known site: `EnterRecordTests`, `text(of record: InMemoryLogHandler.Entry, ...)`.
- Do not add assertions on `label` in this task.

## Acceptance Criteria
- [x] No Router code names `InMemoryLogHandler.Entry` for a `logRecords` value.
- [x] `swift test` and `swift test --package-path IntegrationTests` pass on Extras 42ca5b5 or later.
- [ ] CI is green on the pushed commit.
#model-pool