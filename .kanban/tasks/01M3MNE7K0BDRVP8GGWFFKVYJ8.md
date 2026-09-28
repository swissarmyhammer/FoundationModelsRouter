---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3n50kwp3a8rffc1bttzxv6g
  text: |-
    Research (implement, iteration 1):
    - Extras is at 6c399a4. `TracedCall.run(_:ofKind:tracer:logger:attributes:metadata:_:)` is `nonisolated(nonsending)`. It opens the span with `withSpan`, sets the attributes, logs `enter <spanName>` at `TracedCall.enterLevel` (`.info`) with the caller metadata plus `trace.id` and `span.id` (from `SpanIdentity(context:tracer:)`, public), and writes nothing on exit. `ExtrasTelemetry` (the `trace.id`/`span.id` keys and the `enter ` prefix) is internal to Extras, so the router vocabulary must spell the same keys and message.
    - Submission: a manual span (`startSpan` in `beginSubmission`, ended in `endSubmission`). `TracedCall.run` ends its span when its body returns, so it does not fit a span that one method opens and another method ends. Decision: `beginSubmission` writes the same record (same message, same level, same `trace.id`/`span.id` keys through `SpanIdentity`) through the session logger. The call is synchronous: no new suspension point on the pump.
    - Load: `withLoadSpan` runs inside the admission job of `ModelPool.admit`. That job runs on the worker task of a `GenerationQueue` (`Task.detached`), so a task-local log routing (the `TelemetryCapture` handler, and the swift-log `Logger.current`) does not reach it. The router already carries the `ServiceContext` and the metrics factory by hand. `Logger.current` is not usable: its unbound default is a `Logger(label: "")` with the handler of its first read. Decision: the router gets an explicit logger (internal `useLogger(_:)`, `nil` by default), the same shape as the session explicit logger of ^rag2e91. The resolve and the load read it through `RouterTelemetry.logger(_:explicit:)`; with no explicit logger, a module logger is made at the call. A test gives `TelemetryCapture.Context.logger` to the router, as the load span tests give an explicit tracer to the router.
    - The resolve record is written on the caller task, so a module logger reaches a capture with no explicit logger too.
    - `W3CInMemoryTracer` makes W3C ids, and its finished spans have the same `traceID`/`spanID`, so a test can match each record to its span.
  timestamp: 2026-09-28T23:18:46.934333+00:00
- actor: claude-code
  id: 01m3n5j4qs5p06j0bdds4zh2wc
  text: |-
    Implementation (iteration 1):
    - Why `TracedCall.run` does not fit the submission span: `beginSubmission` opens the span with `startSpan`, and `endSubmission` ends it later, in a different method. `TracedCall.run` opens the span with `withSpan` and ends it when its body returns, so it can hold only a span whose whole life is one closure. Thus `beginSubmission` writes the same record next to the `startSpan` call: `RouterTelemetry.EnterRecord.write(for:named:tracer:to:)` logs `enter <span name>` at `TracedCall.enterLevel`, with `trace.id` and `span.id` from `SpanIdentity(context:tracer:)` (public in Extras), through the session logger. The call is synchronous: no new suspension point on the pump.
    - Resolve and load use `TracedCall.run` through one private helper, `Router.withEnteredSpan(_:attributes:body:)`. The span names, the kind `.client`, the attributes and the parent links do not change: `TracedCall.run` uses `withSpan` with `ServiceContext.current`, and the admission job still binds the `ServiceContext` of the resolve span.
    - Each record also has `FoundationModelsRouter.span.name` (`LogMetadataKey.spanName`). New log category `Enter`.
    - Router explicit logger: `Router.explicitLogger` (`private(set)`, `nil` by default) and internal `useLogger(_:)`. The resolve and the load read it through `RouterTelemetry.logger(.enter, explicit:)`.
    - Tests: `EnterRecordTests` (5 tests) with `TelemetryCapture`, a scripted session over a stub loader, and a `HeldSessionBackend` whose call sends a signal when it starts and waits for a release signal (no clock). New shared helper `SharedBackendContainer` (moved out of `SubmissionTracingTests`, with the backend type widened to `any LanguageModelSessionBackend`).
    - Fail-first proof: with `withEnteredSpan` changed back to a plain `withSpan` and the `EnterRecord.write` call removed, `swift test --filter EnterRecordTests` ran 5 tests and all 5 failed with 8 issues. With the implementation back, the filter `EnterRecordTests|SubmissionTracingTests|ResolveTracingTests|RouterTelemetryLoggingTests|TelemetryContentSafetyTests` ran 25 tests in 5 suites and all passed. The existing tracing tests have no change to what they assert.

    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Tracing/RouterTelemetry.swift, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorSubmissionEvents.swift, Tests/FoundationModelsRouterTests/EnterRecordTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/HeldSessionBackend.swift (new), Tests/FoundationModelsRouterTests/Helpers/SharedBackendContainer.swift (new), Tests/FoundationModelsRouterTests/SubmissionTracingTests.swift
    - next: /test
  timestamp: 2026-09-28T23:28:21.241957+00:00
- actor: claude-code
  id: 01m3n63cmhtm3f97mq6zrhz4wg
  text: |-
    ### test — green
    - evidence: `swift test --manifest-cache local` (one full run, exit 0): 1414 tests in 179 suites passed (2 known issues), 22 tests in 10 suites passed, 19 tests in 3 suites passed. Clean build `swift build --build-tests` with a separate `--scratch-path`: no compiler warning from this package (only vendored checkout warnings, the SwiftPM mlx-swift bundle note and a swift-nio cache note). `swift build --build-tests --package-path IntegrationTests`: build complete.
    - next: /commit
  timestamp: 2026-09-28T23:37:46.385160+00:00
- actor: claude-code
  id: 01m3n6j5jthdcvsh6wh3s365n1
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (c99037f) — 1 finding (1 confirmed, 0 refuted): Sources/FoundationModelsRouter/Router.swift:206 (completeness/public-output-contract)
    - next: implement the finding

    ### finish iteration 1 — findings
    - implement: changed — RouterTelemetry.EnterRecord, Router.withEnteredSpan(_:attributes:body:) over TracedCall.run for resolve and load, the submission record next to startSpan, Router explicit logger, EnterRecordTests (5 tests), HeldSessionBackend and SharedBackendContainer helpers.
    - test: green — swift test: 1414 + 22 + 19 tests passed (2 known issues), exit 0; the clean build with a separate scratch path has no compiler warning from this package; IntegrationTests builds.
    - commit: changed — c99037f feat(telemetry): write one "enter" log record when a submission, load or resolve span starts (^ffkvyj8)
    - review: findings — 1 (Router.swift:206 completeness/public-output-contract)
  timestamp: 2026-09-28T23:45:50.682171+00:00
- actor: claude-code
  id: 01m3n6nqyf8zm15haqh82k7ckx
  text: |-
    ### implement — changed
    - evidence: the finding Router.swift:206 (completeness/public-output-contract). `Router.useLogger(_:)` is now `public`, as the finding says, with documentation for a host: with no explicit logger the router makes a module logger at each call; give an explicit logger when the records must reach a logger that a task-local context selects, because the loads run in an admission job on a task of its own. `explicitLogger` stays `private(set)`. `Logger` is from swift-log, which the library target already depends on. 1 file: Sources/FoundationModelsRouter/Router.swift. `swift build --build-tests`: build complete, no error.
    - next: /test
  timestamp: 2026-09-28T23:47:47.791963+00:00
- actor: claude-code
  id: 01m3n6xdqcrzj2c9vme3aqx9ja
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (d15e47f) — 0 findings, 0 confirmed, 0 refuted; the prior finding (Router.swift:206 completeness/public-output-contract) is corrected and checked.
    - next: none; the review moved the task to done.

    ### finish iteration 2 — clean
    - implement: changed — `Router.useLogger(_:)` is public, with host documentation.
    - test: green — swift test: 1414 + 22 + 19 tests passed (2 known issues), exit 0.
    - commit: changed — d15e47f fix(telemetry): make Router.useLogger(_:) public, as its documentation says (^ffkvyj8)
    - review: clean — 0 findings; the review moved the task to done.
  timestamp: 2026-09-28T23:51:59.468535+00:00
depends_on:
- 01M3MND1G818WNMRPDFRAG2E91
position_column: done
position_ordinal: ffffffb580
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

## Review Findings (2026-09-28 18:38)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Router.swift:206` `completeness/public-output-contract` — useLogger is documented as the public API for configuring explicitLogger, but is not marked public, making it inaccessible to callers outside the module. The documentation at lines 55–61 states 'Set it with ``useLogger(_:)``', but the method lacks the public keyword, breaking the documented contract for public API users. Mark useLogger as `public func useLogger(_ logger: Logger)` to match the public-facing documentation contract.