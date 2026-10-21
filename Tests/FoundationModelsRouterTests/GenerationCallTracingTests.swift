import Foundation
import FoundationModels
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Task ^radwshb: each generation call of a submission opens one span, a
/// child of the span of its submission, with the usage, the times, the stop
/// reason and the tool calls of that one call.
///
/// The suite drives a real `LanguageModelSession` over a
/// ``MeteredToolLoopLanguageModel`` whose calls report scripted usage, and
/// reads the spans back from an `InMemoryTracer`.
@Suite("Generation call tracing: one span for each generation call, under its submission")
struct GenerationCallTracingTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "GenerationCallTracingTests"

    /// The working context of the metered session.
    private static let contextTokens = 1_000

    /// The prompt of every answer. The metered model never reads it.
    private static let prompt = "look things up, then tell me what you found"

    /// The pace of each scripted call: a short prefill and decode, so the
    /// session sees the first token of each call.
    private static let pacing = MeteredCallPacing(prefill: .milliseconds(20), decode: .milliseconds(20))

    /// Three calls of one tool loop: two that ask for the tool, then the call
    /// that answers. Each later call reuses the context of the call before.
    private static let calls = [
        MeteredGenerationCall(tokensIn: 100, tokensOut: 30, tokensCached: 0, pacing: pacing),
        MeteredGenerationCall(tokensIn: 200, tokensOut: 50, tokensCached: 130, pacing: pacing),
        MeteredGenerationCall(tokensIn: 300, tokensOut: 70, tokensCached: 250, pacing: pacing),
    ]

    /// The span name of each generation call.
    private static let callSpanName = RouterTelemetry.SpanName.generationCall

    /// Drives one answer over ``calls`` with `tracer`, and returns the
    /// finished spans of its submission and of its generation calls.
    ///
    /// - Parameter tracer: The tracer the session reports to.
    /// - Returns: The one submission span and the generation call spans, in
    ///   the order they finished.
    /// - Throws: Whatever the fixture or the answer throws, or when the
    ///   tracer holds no submission span or more than one.
    private static func driveAnswer(
        tracer: InMemoryTracer
    ) async throws -> (submission: FinishedInMemorySpan, calls: [FinishedInMemorySpan]) {
        let fixture = try await MeteredToolLoopSessionFixture.make(
            calls: calls, context: contextTokens, tempDirPrefix: tempDirPrefix, tracer: tracer)
        defer { await fixture.end() }
        for try await _ in await fixture.session.streamEvents(to: prompt, maxTokens: nil) {}
        let submissions = tracer.finishedSpans.filter { $0.operationName == RouterTelemetry.SpanName.submission }
        try #require(submissions.count == 1)
        let submission = try #require(submissions.first)
        return (submission, tracer.finishedSpans.filter { $0.operationName == callSpanName })
    }

    /// The integer attribute `key` of each span of `spans`, in order.
    ///
    /// - Parameters:
    ///   - key: The attribute key.
    ///   - spans: The spans to read.
    /// - Returns: The value of each span, or `nil` where the span has none.
    private static func ints(for key: String, of spans: [FinishedInMemorySpan]) -> [Int64?] {
        spans.map { span in
            guard case .int64(let value) = span.attributes.get(key) else { return nil }
            return value
        }
    }

    @Test("a submission of three generation calls opens three call spans, each a child of the submission span")
    func eachCallOpensOneSpanUnderTheSubmission() async throws {
        let tracer = InMemoryTracer()

        let spans = try await Self.driveAnswer(tracer: tracer)

        #expect(spans.calls.count == Self.calls.count)
        #expect(spans.calls.allSatisfy { $0.parentSpanID == spans.submission.spanID })
        #expect(spans.calls.allSatisfy { $0.kind == .internal })
    }

    @Test("each call span carries the tokens in, cached and out of its own call")
    func eachCallSpanCarriesItsTokens() async throws {
        let tracer = InMemoryTracer()

        let spans = try await Self.driveAnswer(tracer: tracer)

        #expect(Self.ints(for: RouterTelemetry.AttributeKey.tokensIn, of: spans.calls) == [100, 200, 300])
        #expect(Self.ints(for: RouterTelemetry.AttributeKey.tokensCached, of: spans.calls) == [0, 130, 250])
        #expect(Self.ints(for: RouterTelemetry.AttributeKey.tokensOut, of: spans.calls) == [30, 50, 70])
    }

    @Test("each call span carries its time to first token, its decode time, its stop reason and its tool calls")
    func eachCallSpanCarriesItsTimesAndItsStop() async throws {
        let tracer = InMemoryTracer()

        let spans = try await Self.driveAnswer(tracer: tracer)

        let firstTokenTimes = Self.ints(for: RouterTelemetry.AttributeKey.timeToFirstTokenMs, of: spans.calls)
        let decodeTimes = Self.ints(for: RouterTelemetry.AttributeKey.decodeMs, of: spans.calls)
        #expect(firstTokenTimes.allSatisfy { time in time.map { $0 >= 0 } ?? false })
        #expect(decodeTimes.allSatisfy { time in time.map { $0 >= 0 } ?? false })
        #expect(Self.ints(for: RouterTelemetry.AttributeKey.toolCallCount, of: spans.calls) == [1, 1, 0])
        #expect(
            spans.calls.map { $0.attributes.get(RouterTelemetry.AttributeKey.finishReason) }
                == Array(repeating: .string("\(FinishReason.completed)"), count: Self.calls.count))
    }
}
