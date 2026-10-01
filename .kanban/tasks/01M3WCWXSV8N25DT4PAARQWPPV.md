---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3wf8z45rgc8267ccqb0ynmz
  text: |-
    Research: commit dafb88af (^ez2g5gw) already did the work of this card. Each item, compared with the current code:
    - Package.resolved pins FoundationModelsExtras at 50fd4a5aeac0aede8f4e3d4783946c7afa1af784.
    - The submission span records only the error status and `error.type` (`recordSubmissionError` in `RoutedSessionActorSubmissionEvents.swift`, `RouterTelemetry.AttributeKey.errorType`). It does not record the `RejectedToolCallError` description.
    - ResolveTracingTests, ToolTracingTests and SubmissionTracingTests read `failureType` (`Tests/FoundationModelsRouterTests/Helpers/FinishedInMemorySpan+Failure.swift`), not `span.errors`.
    - `swift test` (no local change): 1451 tests in 183 suites passed (2 known issues, both expected `withKnownIssue` in BoundedWaitTests and RealModelHarnessTests), 23 tests in 11 suites passed, 19 tests in 3 suites passed. All 4 named tests (6 expectations) pass: "a resolve that fits nothing records the failure on its span and opens no load span", "a loader failure is recorded on the load span that raised it and on the resolve span", "a tool call that throws keeps its span, with the error recorded, while the answer goes on" (2 cases), "no span, log record or metric carries prompt, response, tool or embed-input text".

    Discovery: the session, compact, fork and embed spans still open with `withSpan`. `withSpan` calls `span.recordError(error)` (swift-distributed-tracing `Sources/Tracing/TracerProtocol.swift`), so these spans record the full error description. This card does not name these spans, and no test of this card fails because of them. New task ^4dtkb15 records this work.
  timestamp: 2026-10-01T19:32:47.365269+00:00
- actor: claude-code
  id: 01m3wf90zwrzw6b42s0gy2e6gv
  text: |-
    ### implement — no-change
    - evidence: no file changed. `swift test`: 1451 tests / 183 suites passed (2 expected known issues), 23 / 11 passed, 19 / 3 passed. The 6 expectations of the card pass with Extras at 50fd4a5. dafb88af (^ez2g5gw) did the work.
    - next: review. The leak in the session, compact, fork and embed spans is open in ^4dtkb15.
  timestamp: 2026-10-01T19:32:49.276153+00:00
position_column: doing
position_ordinal: '80'
title: Tracing tests fail with FoundationModelsExtras 50fd4a5 (span error recording changed)
---
## Problem

`swift test` fails 6 expectations in 3 suites when the package resolves FoundationModelsExtras `main` at 50fd4a5. The failures exist without any local change (checked with `git stash` on 2026-10-01, during ^ez2g5gw).

Failing tests:

- `ResolveTracingTests`: "a resolve that fits nothing records the failure on its span and opens no load span" (`span.errors.count == 1`), and "a loader failure is recorded on the load span that raised it and on the resolve span" (`resolveSpan.errors.count == 1`, `loadSpans[0].errors.count == 1`).
- `ToolTracingTests`: "a tool call that throws keeps its span, with the error recorded, while the answer goes on" (`span.errors.count == 1`, two rows).
- `TelemetryContentSafetyTests`: "no span, log record or metric carries prompt, response, tool or embed-input text". The span `FoundationModelsRouter.submission` error carries `RejectedToolCallError(... rawTextPreview: "...SECRET-ARGUMENT-VALUE...")`.

## Cause (to confirm)

Extras commits after 42ca5b5:

- cdfe98d `feat(telemetry)!: make TelemetryCapture read span links, span events, recorded errors, the span status message and log record errors`
- 50fd4a5 `fix(telemetry)!: record only the error type on the span of TracedCall.run, never the error description`

The Router code or tests must follow these breaking changes. The content-safety failure shows that a Router span records the full `RejectedToolCallError` description, which holds the tool arguments.

## Note

The local `Package.resolved` (not tracked) pinned Extras at 3de1179, and the build failed (`MLXModelLoader`, `ModelLoadProgress` not found). `swift package update FoundationModelsExtras` moved it to 50fd4a5.

## Tests

- The 6 expectations above pass with Extras at 50fd4a5 or later.