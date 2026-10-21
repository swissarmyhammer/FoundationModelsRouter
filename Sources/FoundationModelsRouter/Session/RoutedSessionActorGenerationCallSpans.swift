import FoundationModels
import Tracing

extension GenerationCallEntryKind {
    /// How many tool calls the call that appended the last of `entries`
    /// asked for: the calls of that entry when it is a `.toolCalls` entry,
    /// and 0 in every other case.
    ///
    /// - Parameter entries: The entries the attempt appended, in transcript
    ///   order.
    /// - Returns: The count of the tool calls of the last entry.
    static func toolCallCount(leftBy entries: [Transcript.Entry]) -> Int {
        guard case .toolCalls(let calls) = entries.last else { return 0 }
        return calls.count
    }
}

/// ``RoutedSessionActor``'s span of each generation call (task ^radwshb):
/// one ``RouterTelemetry/SpanName/generationCall`` span for each call that
/// the ledger of an attempt reports, a child of the span of the running
/// submission.
///
/// The session knows the counts, the stop and the tool calls of a call only
/// when the call ended, so the span is written then: it starts at the start
/// of the call, which lies the duration of the call before now, and it ends
/// now. A span that opened at the start of the call would carry no more.
extension RoutedSessionActor {
    /// Nanoseconds in one second, the unit of a tracer instant.
    private static let nanosecondsPerSecond: Double = 1e9

    /// Writes the span of one generation call that ended now, as a child of
    /// the span of the running submission. With no running submission it
    /// writes nothing.
    ///
    /// The span carries no content: counts, times in milliseconds, the name
    /// of the finish reason, and a count of tool calls.
    ///
    /// - Parameters:
    ///   - usage: The usage report of the call.
    ///   - duration: How long the call ran, up to now.
    ///   - toolCallCount: How many tool calls the call asked for.
    func traceGenerationCall(_ usage: GenerationCallUsage, duration: Duration, toolCallCount: Int) {
        guard let submission = runningSubmission?.span else { return }
        let endedAt = DefaultTracerClock.now
        let span = RouterTelemetry.tracer(explicit: tracer).startSpan(
            RouterTelemetry.SpanName.generationCall, context: submission.context, ofKind: .internal,
            at: Self.instant(duration, before: endedAt))
        Self.describe(usage, duration: duration, toolCallCount: toolCallCount, on: span)
        span.end(at: endedAt)
    }

    /// The tracer instant that lies `duration` before `instant`, or the
    /// start of the epoch when `duration` reaches past it.
    ///
    /// - Parameters:
    ///   - duration: How far before `instant`. A negative duration counts as
    ///     zero.
    ///   - instant: The later instant.
    /// - Returns: The earlier instant.
    private static func instant(
        _ duration: Duration, before instant: DefaultTracerClock.Instant
    ) -> DefaultTracerClock.Instant {
        let nanoseconds = UInt64(max(duration.seconds, 0) * nanosecondsPerSecond)
        return DefaultTracerClock.Instant(
            nanosecondsSinceEpoch: instant.nanosecondsSinceEpoch - min(nanoseconds, instant.nanosecondsSinceEpoch))
    }

    /// Writes the attributes of one generation call on its span: its tokens
    /// in, cached and out, its whole time, whether the session saw its first
    /// output token, its prefill and decode times when it did, its finish
    /// reason and its tool calls.
    ///
    /// - Parameters:
    ///   - usage: The usage report of the call.
    ///   - duration: How long the call ran.
    ///   - toolCallCount: How many tool calls the call asked for.
    ///   - span: The span of the call.
    private static func describe(
        _ usage: GenerationCallUsage, duration: Duration, toolCallCount: Int, on span: any Span
    ) {
        span.attributes[RouterTelemetry.AttributeKey.tokensIn] = usage.tokensIn
        span.attributes[RouterTelemetry.AttributeKey.tokensOut] = usage.tokensOut
        if let tokensCached = usage.tokensCached {
            span.attributes[RouterTelemetry.AttributeKey.tokensCached] = tokensCached
        }
        span.attributes[RouterTelemetry.AttributeKey.callMs] = duration.wholeMilliseconds
        span.attributes[RouterTelemetry.AttributeKey.firstTokenSeen] = usage.firstTokenSeen
        if let timeToFirstToken = usage.timeToFirstToken {
            span.attributes[RouterTelemetry.AttributeKey.timeToFirstTokenMs] = timeToFirstToken.wholeMilliseconds
        }
        if let decodeTime = usage.decodeTime {
            span.attributes[RouterTelemetry.AttributeKey.decodeMs] = decodeTime.wholeMilliseconds
        }
        span.attributes[RouterTelemetry.AttributeKey.finishReason] = "\(usage.finishReason)"
        span.attributes[RouterTelemetry.AttributeKey.toolCallCount] = toolCallCount
    }
}
