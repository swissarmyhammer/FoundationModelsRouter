---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
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
- [ ] No Router code names `InMemoryLogHandler.Entry` for a `logRecords` value.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass on Extras 42ca5b5 or later.
- [ ] CI is green on the pushed commit.
#model-pool