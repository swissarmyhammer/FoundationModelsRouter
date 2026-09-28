---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mvw8asfqj5d3yjvavqg5sn
  text: |-
    Research (implement, iteration 1):
    - Extras at 70ad74d has `TelemetryCapture` (product `TelemetryTestSupport`). It routes log records through a handler that reads a task-local at log time. A detached task gets no capture.
    - The session pump is `Task.detached` (a cancellation invariant; keep it). Thus a log call on the pump (repetition stop, generation stall) does not reach a capture through the global handler. swift-log itself says: capture the logger explicitly across a detached boundary.
    - Decision on the logger lifetime: no `static let` logger. `RouterTelemetry.makeLogger(_:)` makes a logger at each call. A session also has an explicit logger (`nil` by default), set with `useLogger(_:)`, and a fork copies it, as `setGenerationStallReportInterval(_:)` does. A test gives `TelemetryCapture.Context.logger` to the session. This is the "explicit" way that the `TelemetryCapture` documentation names.
    - swift-log 1.15.1 and swift-metrics 2.11.0 are the Extras pins.
    - The design file (rule 3) says each name starts with the module name, thus each log metadata key starts with `FoundationModelsRouter.`.
  timestamp: 2026-09-28T20:39:06.841342+00:00
- actor: claude-code
  id: 01m3mxzjdbfazhcgw9kkrc4xpc
  text: |-
    Implementation (iteration 1), done in a fork:
    - Package.swift: swift-log `from: "1.15.1"` (the Extras pin). `Logging` is on the library target, the unit test target and the three executables. `TelemetryTestSupport` is on the unit test target. No swift-otel.
    - `RouterTracing` is now `RouterTelemetry` (file `Tracing/RouterTelemetry.swift`). The type is internal, so it has no deprecated typealias. It adds `LogCategory`, `LogMetadataKey` (each key starts with `FoundationModelsRouter.`), `makeLogger(_:)`, `logger(_:explicit:)` and `errorMetadata(_:)` (the error type and `NSError` code, never the description). The no-content rule now covers log messages and log metadata values.
    - Logger lifetime decision: no stored logger. A logger of the module is made at each log call (`RouterTelemetry.makeLogger`). A session also has an explicit logger (`explicitLogger`, `useLogger(_:)`, `sessionLogger(_:)`). A fork copies it. Reason: the pump is `Task.detached`, so the task-local routing of `TelemetryCapture` does not reach its records. An explicit logger does reach them. Each log call is synchronous and adds no suspension point.
    - Every log site is ported: a constant message, with each value as metadata. Each site that logged an error description now logs `errorMetadata(error)`. `appendJSONLine` takes `failureMessage` and `failureMetadata` in place of the `describeFailure` closure. `Compactor.log` logs the case name and the token counts.
    - The three executables call `LoggingSystem.bootstrap(StreamLogHandler.standardError)` first.
    - Resolve facts: `swift package resolve` moved Extras to origin/main 4a733cd. That commit does NOT contain the OTel work (70ad74d is not its ancestor), so I set Package.resolved back to 70ad74d. Also, TelemetryCapture needs swift-distributed-tracing 1.5.0 (`withTracer`), but the Extras manifest says `from: 1.4.1`, so I resolved tracing to 1.5.0. IntegrationTests/Package.resolved has the same pins.
    - Checks: `swift build --build-tests` has no errors. The targeted suites (Telemetry layout, RouterTelemetryLogging, TranscriptEntryMapper, TranscriptReconstruction, RepetitionStop, GenerationStall, JSONLAppend, SpanContentSafety, SubmissionTracing) ran 104 tests and all passed. The IntegrationTests build passes. `ToolCallRepetitionStopTests` failed one time (`stop.newLines == 1`) and passed on the next run: it is flaky.
  timestamp: 2026-09-28T21:15:52.619472+00:00
position_column: doing
position_ordinal: '80'
title: 'OTel router A: replace os.Logger with swift-log, and rename RouterTracing to one telemetry vocabulary with log metadata keys'
---
## What
Design approved by the user on 2026-09-28 (swissarmyhammer session; full text `/private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md`). Rules for the router, a library: use only the APIs `Tracing` (swift-distributed-tracing), `Logging` (swift-log) and `Metrics` (swift-metrics); never depend on swift-otel; remove all `os.Logger` use and do not keep unified-logging output; one vocabulary file for the package; no content (prompt text, response text, tool arguments, tool output, embed input text) in a span attribute, a log message, a log metadata value or a metric dimension.

Blocked by FoundationModelsExtras tasks 01M3MN838VZ4QX57C3965XMGKV (^65xmgkv, swift-log and swift-metrics as API; use the same version pins) and 01M3MN8N9P4RPET2V5JZ6JQD9G (^z6jqd9g, `TelemetryTestSupport` with `TelemetryCapture`, which records log records for the tests below). Both must be on Extras `main`.

- `Package.swift`: add the swift-log package; add product `Logging` to the library target. No swift-otel anywhere, also not in `Examples/` or `Tools/` (they are not the executables the design names).
- Vocabulary: rename `enum RouterTracing` (`Sources/FoundationModelsRouter/Tracing/RouterTracing.swift`) to `RouterTelemetry` (file `Tracing/RouterTelemetry.swift`), because it now covers spans, metrics and logs. Keep `SpanName`, `AttributeKey`, `CompactionTrigger`, `SessionOrigin`, `tracer(explicit:)`. If `RouterTracing` is public, keep a deprecated public typealias. Add `LogMetadataKey`, prefixed with the module name. Extend the written no-content rule (lines 17-24) to log messages and log metadata values.
- Replace the module logger factory (`FoundationModelsRouter.swift:28-29`, `makeModuleLogger(category:)`) with a `Logging.Logger` factory (label `FoundationModelsRouter.<category>`). Remove `import os` from the 19 source files. Port the 29 call sites (for example `TranscriptEntryMapper.swift:114,158,207,333,382,421,519`, `RoutedSessionActorAnswerExecution.swift:224`, `Compactor.swift:278`, `PersistableStructuredSegment.swift:92`, `Sinks.swift:156,174`, `JSONLAppend.swift:111`). Put each interpolated value into log metadata with a vocabulary key.
- No content: at each site that logs `String(describing: error)` or `error.localizedDescription` (for example AnswerExecution:225, TranscriptEntryMapper:519, PersistableStructuredSegment:92, Compactor:278), log the error TYPE and a safe code, not a description that can carry model content. `RejectedToolCallRetry.swift:80` logs a tool name: a name is safe, keep it as metadata.
- Tests: `Tests/FoundationModelsRouterTests/Helpers/LogAssertions.swift` uses `OSLogStore`. Replace it with a capture through `TelemetryCapture` (or a small swift-log test handler if the Extras helper does not fit), and change its callers (`TranscriptEntryMapperTests.swift:677,777,802,839`, `TranscriptReconstructionTests.swift:1120`, `RepetitionStopTests.swift:137`, `GenerationStallDiagnosticTests.swift:506`) with no change to what they assert.

- Executables (design rule 6): the swift-log default handler writes to stdout. After the move to swift-log, each executable of the repo (`MultiModelGeneration` and `CompactionDemo` in `Examples/`, `RecordCompactionFixture` in `Tools/`) calls `LoggingSystem.bootstrap` with a stderr handler (for example `StreamLogHandler.standardError`) one time at startup, before any log call, so that its stdout (for example the fixture output) has no log lines. They do NOT get swift-otel.

Facts from the Extras OTel work (swissarmyhammer session, 2026-09-28). Extras OTel A-D are done locally; do not start this task until they are on Extras `origin/main`:
- `TelemetryCapture` (product `TelemetryTestSupport`) uses the task-local `withTracer` and `withMetricsFactory`, and it bootstraps logging only one time. A TEST process that uses it must NOT call `LoggingSystem.bootstrap` itself. (The executables still bootstrap to stderr; they are not test processes.)
- A logger or a metric that is made before the first capture does not go to the capture. Thus a `static let` logger (for example one made by `makeModuleLogger(category:)` and stored in a static) that a test touches before the capture starts is lost. Make the loggers per call or per instance, or make sure that the capture starts first; record the choice in a task comment.

## Acceptance Criteria
- [ ] Each executable of the repo bootstraps logging to stderr at startup; its stdout carries no log lines.
- [ ] No `import os`, `os.Logger`, `OSLog`, `OSLogStore` or `OSSignposter` in `Sources/`, `Tests/`, `IntegrationTests/`, `Examples/` or `Tools/`.
- [ ] Every log call uses `Logging.Logger`, and every interpolated value is log metadata with a `RouterTelemetry.LogMetadataKey`.
- [ ] No log message or metadata value carries model content.
- [ ] No swift-otel dependency in any `Package.swift` of the repo.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] The tests that used `assertLogged` pass through the new capture with no change to what they assert.
- [ ] A package-layout test checks that no `Package.swift` in the repo names swift-otel.
- [ ] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel #cross-repo