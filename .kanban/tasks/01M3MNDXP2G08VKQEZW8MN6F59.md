---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3n3tre76b8thnka17333cf1
  text: |-
    Research (implement, iteration 1):
    - Extras is at 6c399a4. `TelemetryCapture.run(forbidding:sourceLocation:_:)` gives a `Context` with `tracer` (a `W3CInMemoryTracer`, which is a `Tracer`), `logger`, `metricsFactory` (a `TestMetrics`), `spans`, `logRecords` and `metricRecords`. The leak check reads span names, span attributes, log messages, log metadata values and metric labels and dimensions.
    - `TelemetryTestSupport` is already on the unit test target (task A). The helpers `useCaptureLogger(for:)` and `useCaptureMetrics(for:)` already exist (LogAssertions.swift, MetricAssertions.swift).
    - The scripted session writes no log on its usual path. A rejected tool call retry logs through `sessionLogger(.rejectedToolCall)`, which uses the explicit logger. `RejectingLanguageModel` drives that path (as `RejectedToolCallRetryTests` does). Decision: the test also drives one answer over a `RejectingLanguageModel` session in the same capture, and I move the fixture of `RejectedToolCallRetryTests` to a shared helper so that the two suites use one builder.
    - Gap found: Extras records `FoundationModelsExtras.tool.calls` and `.duration` from `MetricsSystem.factory` at the end of the call. The tool call runs under the detached pump, so that factory is the global one, not the explicit factory of the session. Thus the Extras tool metrics do not reach the capture. Decision: the pump binds the explicit metrics factory of the session with `withMetricsFactory` around each job (the answer and the caller compaction). `withMetricsFactory` is `nonisolated(nonsending)`, so it does not leave the actor. With no explicit factory, the pump binds nothing.
    - `Compactor.log` (a compaction shortfall) uses a module logger, not the session logger, so a shortfall on the pump does not reach a capture. Not in the scope of this task; the rejected retry gives the log record.
  timestamp: 2026-09-28T22:58:06.407692+00:00
- actor: claude-code
  id: 01m3n47fchtn18e8c9kr25r1y5
  text: |-
    Fail-first proof (implement, iteration 1):
    - TDD red: before the pump binding, `swift test --filter TelemetryContentSafetyTests` ran 1 test and failed with 1 issue: the expectation of the `FoundationModelsExtras.tool.calls` metric with `tool.name = marker-lookup` (TelemetryContentSafetyTests.swift:96). The span and log expectations passed. After the binding, the filter `TelemetryContentSafetyTests|RejectedToolCallRetryTests` ran 3 tests in 2 suites and all passed.
    - Check that the test can fail: I added a test-only line in `recoverFailedAttempt` (RoutedSessionActorAnswerExecution.swift): `sessionLogger(.rejectedToolCall).warning("FAIL-FIRST \(ownPrompt)")`. `swift test --filter TelemetryContentSafetyTests` ran 1 test and failed with 1 issue: `telemetry carries the forbidden text "rejected-call-prompt-3b1d" at: log warning: FAIL-FIRST rejected-call-prompt-3b1d`. I removed the line; `git diff` of that file is empty.
  timestamp: 2026-09-28T23:05:03.121865+00:00
- actor: claude-code
  id: 01m3n47v09ayht7406d1pmns7s
  text: |-
    ### implement — changed
    - evidence: 14 files — Sources: Session/RoutedSessionActorMetrics.swift (`withSessionMetricsFactory(_:)`), Session/RoutedSessionActorPump.swift (the pump binds the explicit factory around each job), Session/RoutedSessionActor.swift (doc), Session/RejectedToolCallRetry.swift (`retryLogMessage`), Tracing/RouterTelemetry.swift (doc). Tests: SpanContentSafetyTests.swift renamed to TelemetryContentSafetyTests.swift (suite renamed; spans, logs and metrics through `TelemetryCapture.run(forbidding:)`), Helpers/RejectingSessionFixture.swift (new, shared by RejectedToolCallRetryTests), Helpers/ExtrasTelemetryNames.swift (new, shared by ToolTracingTests), Helpers/RejectingLanguageModel.swift (`rejectedArgumentValue`), RejectedToolCallRetryTests.swift, and the suite name in the docs of Compaction/Fork/SessionCreation/Submission/ToolTracingTests. Package.swift did not change: `TelemetryTestSupport` was already on the unit test target only.
    - next: /test
  timestamp: 2026-09-28T23:05:15.017763+00:00
- actor: claude-code
  id: 01m3n4g8wwx51nz6rjyxr1yry2
  text: |-
    ### test — green
    - evidence: `swift test --manifest-cache local` (one full run, exit 0): 1409 tests in 178 suites passed (2 known issues), 22 tests in 10 suites passed, 19 tests in 3 suites passed. Clean build `swift build --build-tests` with a separate `--scratch-path`: no compiler warning (only the SwiftPM "missing creator for mutated node" note of the mlx-swift bundle).
    - next: /commit
  timestamp: 2026-09-28T23:09:51.388555+00:00
depends_on:
- 01M3MND1G818WNMRPDFRAG2E91
position_column: doing
position_ordinal: '80'
title: 'OTel router C: the content-safety test covers spans, logs and metrics through the Extras TelemetryCapture helper'
---
## What
Design approved by the user on 2026-09-28 (rule 4: no content in a span attribute, a log message, a log metadata value or a metric dimension; rule 5: each package has a content-safety test that uses the shared Extras helper).

Blocked by Extras task 01M3MN8N9P4RPET2V5JZ6JQD9G (^z6jqd9g): product `TelemetryTestSupport` (`.product(name: "TelemetryTestSupport", package: "FoundationModelsExtras")`) with `TelemetryCapture.run(forbidding: [String], _ body: (TelemetryCapture.Context) async throws -> T)`; `Context` gives a `tracer`, a `logger` and the recorded spans, logs and metrics, and reports issues as `<span>.<key> = <value>`, `log <level>: <message>`, `log metadata <key> = <value>` or `metric <name> <label> = <value>`. Read the final API in the Extras checkout. Depends on router task 01M3MND1G818WNMRPDFRAG2E91 (swift-log). If router task B (metrics) is done first, the test covers the metrics too; if not, add the metric part to task B.

- `Tests/FoundationModelsRouterTests/SpanContentSafetyTests.swift` today uses an `InMemoryTracer` and checks span attributes only (:39-47, :83-92). Change it to run the same scripted session (a prompt, an answer with one tool call, a compaction, an embed with input `"embed-input-9c2e"`) inside `TelemetryCapture.run(forbidding:)`, with the capture's tracer, logger and metrics, and forbid the prompt text, the answer text, the tool arguments, the tool output and the embed input.
- The session must write logs and metrics during the run, so the test proves something: also drive at least one path that logs (for example a rejected tool call retry, or a compaction) and check that the capture recorded at least one log record and one metric.
- Rename the file and suite to `TelemetryContentSafetyTests` if it now covers all three signals.
- `Package.swift`: add `TelemetryTestSupport` to the unit test target only.

Facts from the Extras OTel work (swissarmyhammer session, 2026-09-28; do not start until Extras OTel A-D are on Extras `origin/main`):
- `TelemetryCapture` uses the task-local `withTracer` and `withMetricsFactory`, and bootstraps logging one time; the test process must not call `LoggingSystem.bootstrap` itself.
- A logger or metric made before the first capture does not go to the capture, so the test must start the capture before the router makes its loggers and metrics (task A and B make them per call or per instance).
- The tool span is now `FoundationModelsExtras.tool` (Extras `ExtrasTelemetry.swift`), and Extras records `FoundationModelsExtras.tool.calls` and `.duration` with dimensions `tool.name` and `tool.outcome`. The test checks these too, because the session's tool call makes them.

## Acceptance Criteria
- [x] The content-safety test checks span attributes, log messages, log metadata values and metric dimensions, with the Extras helper.
- [x] It records at least one span, one log record and one metric, so it cannot pass with nothing to check.
- [x] It passes, and it fails if a test-only change logs the prompt text (check this one time, then remove the change; record the result in a task comment).

## Tests
- [x] The test above.
- [x] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel #cross-repo