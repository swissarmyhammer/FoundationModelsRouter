---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3wh9amsfbqq8kzk9a700me0
  text: |-
    Research:
    - The four spans open through `RouterTelemetry.tracer(explicit:).withSpan`. `withSpan` calls `recordError` when the body throws.
    - The Extras pattern (`TracedCall.run`, private `recordFailure(of:on:)`) catches the error in the body, returns a `Result`, and throws after `withSpan`. `ExtrasTelemetry.errorType(of:)` is internal to Extras, so the Router keeps its own form `"\(type(of: error))"` from `recordSubmissionError`.
    - The sync `withSessionSpan` is `rethrows`, and the factory `makeRoutedSessionActor` calls it with a closure that does not throw. A `Result` that is thrown after `withSpan` is not legal in a `rethrows` function. Plan: one shared helper in RouterTelemetry with typed throws `throws(Failure)`, a sync form and an async form. Then a closure that does not throw infers `Never` and the factory keeps no `try`.
    - `withCompactionSpan` and `withForkSpan` are private. The tests drive them directly, so they become internal.
    - Existing tests that expect `span.errors.count == 1` (CompactionTracingTests, EmbedTracingTests) must change to `failureType`, as SubmissionTracingTests did in dafb88af.
  timestamp: 2026-10-01T20:07:56.313983+00:00
- actor: claude-code
  id: 01m3whsa8r00y2rqssdsnn2w2c
  text: |-
    Implementation landed (not committed).

    - New file `Sources/FoundationModelsRouter/Tracing/RouterTelemetrySpan.swift`: `RouterTelemetry.recordFailure(of:on:)` (error status + `AttributeKey.errorType`) and `RouterTelemetry.withSpan(_:ofKind:tracer:_:)`, a sync form and an async form with `isolation: isolated (any Actor)? = #isolation`. Both use typed throws `throws(Failure)`: the body catches its error, records the failure, returns a `Result`, and the helper throws after `withSpan`. This is the Extras `TracedCall.run` pattern without the "enter" log record.
    - Session (both `withSessionSpan` forms), compact, fork and embed spans now open through the helper. `recordSubmissionError` calls `recordFailure(of:on:)`, so one function writes the error type.
    - `withSessionSpan` changed from `rethrows` to `throws(Failure)`. Reason: a `rethrows` function cannot throw a stored `Result` error. With typed throws, the factory `makeRoutedSessionActor` passes a closure that does not throw, `Failure` infers `Never`, and the call needs no `try`.
    - `withCompactionSpan` and `withForkSpan` changed from `private` to internal, so that the tests drive them directly with a body that throws.
    - Discovery: an async closure with an explicit `throws(Failure)` signature must also say `async` (`{ span async throws(Failure) in ... }`). Without it, Swift reads the closure as sync and gives "'async' call in a function that does not support concurrency".
    - Tests: new `TelemetryContentSafetyTests+FailedSpans.swift` (4 tests). New helper `Helpers/ThrowingEmbeddingContainer.swift` (moved from a private type in EmbedTracingTests, now with a configurable error) and `HandBuiltProfileFixtures.makeEmbedder`. EmbedTracingTests and CompactionTracingTests now assert `failureType` in place of `errors.count == 1`, as SubmissionTracingTests did in dafb88af.
    - RED: the new tests failed with "telemetry carries the forbidden text ... at: span FoundationModelsRouter.compact error: ..." and `failureType == nil`. GREEN: all pass.
    - Full `swift test`: 1456 tests in 183 suites passed (2 known issues, from earlier `withKnownIssue` tests), plus 23 and 19 tests in the other targets. Build has no warnings.

    Note for the task description: all three checklist items are done. The `update task` call to tick them gave an output too large to read, so check the boxes on the card.
  timestamp: 2026-10-01T20:16:40.216064+00:00
- actor: claude-code
  id: 01m3whskr5r8tpex5nf72dpv4w
  text: |-
    Correction to the previous comment: the description update did apply. All three checklist items are ticked on the card.

    ### implement — changed
    - evidence: `swift test` gave 1456 tests in 183 suites passed (2 known issues from earlier tests) plus 23 + 19 in the other targets, and no build warnings. Files: Sources/FoundationModelsRouter/Tracing/RouterTelemetrySpan.swift (new), Tracing/RouterTelemetry.swift, RoutedEmbedder.swift, Session/RoutedSessionActor.swift, Session/RoutedSessionActorCompaction.swift, Session/RoutedSessionActorForking.swift, Session/RoutedSessionActorSubmissionEvents.swift; Tests: TelemetryContentSafetyTests+FailedSpans.swift (new), Helpers/ThrowingEmbeddingContainer.swift (new), Helpers/HandBuiltProfileFixtures.swift, TelemetryContentSafetyTests.swift, EmbedTracingTests.swift, CompactionTracingTests.swift, ForkTracingTests.swift
    - next: review
  timestamp: 2026-10-01T20:16:49.925096+00:00
- actor: claude-code
  id: 01m3whvg8k1res7bm7pj5dvatz
  text: |-
    ### test — green
    - evidence: swift test, exit 0 — 1456 tests in 183 suites passed, 0 failed; 23 tests in 11 suites passed; 19 tests in 3 suites passed. 2 known issues are withKnownIssue checks that already existed (RealModelHarness, BoundedWait).
    - next: review
  timestamp: 2026-10-01T20:17:51.891854+00:00
position_column: doing
position_ordinal: '80'
title: Session, compact, fork and embed spans record the full error description through withSpan
---
## Problem

`withSpan` of swift-distributed-tracing calls `span.recordError(error)` when the body throws (`.build/checkouts/swift-distributed-tracing/Sources/Tracing/TracerProtocol.swift`). swift-otel exports that error as an exception event with `exception.message = String(describing: error)`. An error description can hold content: a path, a part of a prompt or a tool argument.

FoundationModelsExtras 50fd4a5 removed this path from `TracedCall.run`. In the Router, commit dafb88af (^ez2g5gw) removed it from the submission span (`recordSubmissionError`, `AttributeKey.errorType`). These Router spans still open with `withSpan` and record the full error:

- `RouterTelemetry.SpanName.session` in `Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift` (two overloads).
- `RouterTelemetry.SpanName.compact` in `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift`.
- `RouterTelemetry.SpanName.fork` in `Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift`.
- `RouterTelemetry.SpanName.embed` in `Sources/FoundationModelsRouter/RoutedEmbedder.swift`.

The doc comments of these functions say "`withSpan` records the error on the span".

## Work

- [x] Each span above gets the error status and only the `error.type` attribute when its body throws, never the error description. Follow the Extras `TracedCall.run` pattern: catch the error in the body, set the status and the type, return the error as a value so that `withSpan` records nothing, then throw it.
- [x] Update the doc comments that say "`withSpan` records the error".

## Tests

- [x] For each of session, compact, fork and embed: a body that throws an error with content gives a span with the error status and `failureType`, and `TelemetryCapture` finds no content in any span, log record or metric (extend `TelemetryContentSafetyTests`).

Found during ^arqwppv.