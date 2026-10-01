---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
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

- [ ] Each span above gets the error status and only the `error.type` attribute when its body throws, never the error description. Follow the Extras `TracedCall.run` pattern: catch the error in the body, set the status and the type, return the error as a value so that `withSpan` records nothing, then throw it.
- [ ] Update the doc comments that say "`withSpan` records the error".

## Tests

- [ ] For each of session, compact, fork and embed: a body that throws an error with content gives a span with the error status and `failureType`, and `TelemetryCapture` finds no content in any span, log record or metric (extend `TelemetryContentSafetyTests`).

Found during ^arqwppv.