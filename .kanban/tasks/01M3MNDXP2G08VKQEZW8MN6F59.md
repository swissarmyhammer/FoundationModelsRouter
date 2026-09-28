---
assignees:
- claude-code
depends_on:
- 01M3MND1G818WNMRPDFRAG2E91
position_column: todo
position_ordinal: ac80
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
- [ ] The content-safety test checks span attributes, log messages, log metadata values and metric dimensions, with the Extras helper.
- [ ] It records at least one span, one log record and one metric, so it cannot pass with nothing to check.
- [ ] It passes, and it fails if a test-only change logs the prompt text (check this one time, then remove the change; record the result in a task comment).

## Tests
- [ ] The test above.
- [ ] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel #cross-repo