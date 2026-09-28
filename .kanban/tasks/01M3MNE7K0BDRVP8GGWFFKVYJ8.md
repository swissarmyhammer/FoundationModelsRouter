---
assignees:
- claude-code
depends_on:
- 01M3MND1G818WNMRPDFRAG2E91
position_column: todo
position_ordinal: ad80
title: 'OTel router D: write one "enter" log record when a submission, load or resolve span starts'
---
## What
Design approved by the user on 2026-09-28 (rule 8, hang detection): a span on a call that can suspend for a long time also writes one "enter" log record when it starts, so a hang shows in the logs even when the span never ends and is never exported.

Blocked by Extras task 01M3MN91YK71YVJ9C7WYKGZ2AA (^ykgz2aa): `TracedCall.run<Output>(_ spanName:, ofKind: SpanKind = .internal, tracer: (any Tracer)? = nil, logger: Logger, attributes: (inout SpanAttributes) -> Void, metadata: Logger.Metadata = [:], _ body: (any Span) async throws -> Output)`, which opens the span and logs `enter <spanName>` with metadata such as `span.name`, `trace.id`, `span.id`, and writes nothing on exit. Read the final API in the Extras checkout. Depends on router task 01M3MND1G818WNMRPDFRAG2E91 (swift-log and the vocabulary).

The spans that can suspend a long time:
- Submission: a manual span, `startSpan(RouterTelemetry.SpanName.submission, ..., ofKind: .client)` at `Session/RoutedSessionActorSubmissionEvents.swift:45`, ended at :118. It is not a closure span, so `TracedCall.run` may not fit; if not, write the same "enter" record with the same metadata keys next to the `startSpan` call, and record why in a task comment.
- Model load: `withSpan(RouterTelemetry.SpanName.load, ofKind: .client)` in `withLoadSpan` (`Router.swift:752-764`).
- Resolve: `withSpan(RouterTelemetry.SpanName.resolve, ofKind: .client)` at `Router.swift:184`.
Use `TracedCall.run` for load and resolve. Keep the span names, kinds and attributes the same, and keep the tracing context that ^est00wa passes into the admission job (load spans stay children of the resolve span).

Note: the user decided (2026-09-28) that the tool span becomes `FoundationModelsExtras.tool` (Extras task ^c91jnmp). Router task 01M3MNVA906R6Y1P17JBG4G0NA updates the router references. Do not change the tool span in this task.

The "enter" record carries no content (rule 4): only the span name, ids, and the vocabulary attributes that are already safe.

Facts from the Extras OTel work (swissarmyhammer session, 2026-09-28; do not start until Extras OTel A-D are on Extras `origin/main`):
- `TracedCall.run` gets the trace id and span id for the "enter" record from the `traceparent` that the tracer injects. `InMemoryTracer` does not inject, so with it the records have no ids. A test that checks the ids needs a tracer that injects W3C `traceparent`. `TelemetryCapture` uses `InMemoryTracer` today, which injects only its own id keys. Extras task 01M3MV1R3D52RAMFNFKWTS388B (^wts388b, Extras OTel E) makes `TelemetryCapture` bind a W3C-capable recording tracer by default. It is a BLOCKER for each id check in this task: it must be on Extras `origin/main` before this task starts. Do not write a test tracer of your own for this. UPDATE 2026-09-28: ^wts388b is on Extras `origin/main` (6c399a4). `TelemetryCapture.Context.tracer` is now a `W3CInMemoryTracer`, and the enter records of `TracedCall.run` in a capture have `trace.id` and `span.id`. Code that needs the `InMemoryTracer` type uses `context.tracer.inMemoryTracer`; code that uses it as `any Tracer` or reads `finishedSpans` still compiles. Resolve Extras at 6c399a4 or later before this task starts.
- The task-local `withTracer` of `TelemetryCapture` reaches `RouterTelemetry.tracer(explicit: nil)` (`InstrumentationSystem.tracer` checks the task-local instrument first), so the router's spans go to the capture with no router change.
- The tool span is opened in Extras (`ToolCallSpan.withSpan`, internal; its body now gets a `ToolCallSpan.Call` value). This task does not change it.

## Acceptance Criteria
- [ ] Each submission, load and resolve writes exactly one "enter" log record when it starts, with the span name and ids as metadata, and nothing when it ends.
- [ ] The span names, kinds, attributes and parent links do not change.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Unit tests with a log capture and a scripted session and stub loader: one "enter" record for each submission, load and resolve; a submission whose backend never returns still has its "enter" record (use a real signal, not the clock); the existing tracing tests pass with no change to what they assert.
- [ ] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel #cross-repo