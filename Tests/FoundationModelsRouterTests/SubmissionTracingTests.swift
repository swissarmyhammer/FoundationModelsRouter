import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^kbnbp4a and task ^x7cxsg3: every submission of a session
/// opens one OpenTelemetry span through `swift-distributed-tracing`.
///
/// One chokepoint carries the span, so every surface that sends a message is
/// held to the same contract: ``RoutedSession/respond(to:maxTokens:)``,
/// ``RoutedSession/streamResponse(to:maxTokens:)``,
/// ``RoutedSession/streamEvents(to:maxTokens:)`` and
/// ``RoutedSession/send(_:)-(Transcript.Prompt)``. This suite holds that
/// contract: the operation name, the span kind, the identity attributes, the
/// id of the submission, the cause of the submission, the measured token
/// counts, and the error record on a submission that throws.
///
/// The rule that no attribute carries the caller's own content lives in
/// ``TelemetryContentSafetyTests``, which names no span and therefore already
/// measures this one.
///
/// Everything runs over stubs — a stub ``ModelLoader``, a
/// ``StubSessionBackend`` with canned usage counts, and an `InMemoryTracer` —
/// so the suite needs no network, no GPU and no bootstrapped tracing backend.
@Suite("Submission tracing")
struct SubmissionTracingTests {
    /// The span name every submission opens.
    private static let spanName = RouterTelemetry.SpanName.submission

    /// The `submission.cause` value of a submission that carries a caller
    /// message.
    private static let messageCause = SubmissionStart.Cause.message.rawValue

    /// The number of the second submission of a session. The session numbers
    /// its submissions 1, 2, 3, and so on.
    private static let secondSubmissionNumber: UInt64 = 2

    /// The token counts one successful stub submission meters.
    private static let submissionUsage = (input: 11, output: 7)

    /// The canned text the stub backend answers every submission with.
    private static let cannedAnswer = "stub answer"

    /// The prompt every driven answer carries.
    private static let prompt = "drive one answer"

    /// Builds a session over one shared ``StubSessionBackend`` that answers
    /// ``cannedAnswer`` and meters ``submissionUsage``.
    ///
    /// - Parameter tracer: The tracer every handle of the resolved profile
    ///   carries, or `nil` to read `InstrumentationSystem.tracer` at call time.
    /// - Returns: The fixture the test drives and reads back.
    /// - Throws: Whatever profile resolution throws.
    private static func makeFixture(tracer: (any Tracer)?) async throws -> StubBackendSessionFixture {
        try await StubBackendSessionFixture.make(
            tempDirPrefix: "SubmissionTracingTests", tracer: tracer, responseText: cannedAnswer,
            usageIncrement: submissionUsage)
    }

    /// The one submission span that one answer of one submission opened.
    ///
    /// - Parameter tracer: The tracer the submission reported to.
    /// - Returns: The single finished submission span.
    /// - Throws: When the tracer holds no submission span, or more than one.
    private static func singleSpan(reportedTo tracer: InMemoryTracer) throws -> FinishedInMemorySpan {
        let spans = tracer.finishedSubmissionSpans
        try #require(spans.count == 1)
        return try #require(spans.first)
    }

    @Test("one respond call opens one client submission span carrying the documented attributes")
    func respondOpensOneSubmissionSpanWithAttributes() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { await fixture.end() }

        let answer = try await fixture.session.respond(to: Self.prompt)
        #expect(answer == Self.cannedAnswer)

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .client)
        #expect(
            span.attributes.get(RouterTelemetry.AttributeKey.routerId)
                == .string(fixture.router.id.description))
        #expect(
            span.attributes.get(RouterTelemetry.AttributeKey.sessionId)
                == .string(fixture.session.id.description))
        #expect(
            span.attributes.get(RouterTelemetry.AttributeKey.modelRef)
                == .string(fixture.profile.standard.chosen.stringValue))
        #expect(span.attributes.get(RouterTelemetry.AttributeKey.submissionId) == .string(SubmissionID(1).description))
        #expect(span.attributes.get(RouterTelemetry.AttributeKey.submissionCause) == .string(Self.messageCause))
        #expect(span.errors.isEmpty)
    }

    @Test("a good submission carries the token counts its usage snapshot measured")
    func goodSubmissionCarriesMeasuredTokenCounts() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { await fixture.end() }

        _ = try await fixture.session.respond(to: Self.prompt)

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(
            span.attributes.get(RouterTelemetry.AttributeKey.tokensIn) == .int64(Int64(Self.submissionUsage.input)))
        #expect(
            span.attributes.get(RouterTelemetry.AttributeKey.tokensOut) == .int64(Int64(Self.submissionUsage.output)))
    }

    @Test("two answers on one session open one submission span each, numbered in their session")
    func eachSubmissionOpensItsOwnSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { await fixture.end() }

        _ = try await fixture.session.respond(to: Self.prompt)
        _ = try await fixture.session.respond(to: Self.prompt)

        let spans = tracer.finishedSubmissionSpans
        #expect(
            spans.map { $0.attributes.get(RouterTelemetry.AttributeKey.submissionId) }
                == [.string(SubmissionID(1).description), .string(SubmissionID(Self.secondSubmissionNumber).description)])
        #expect(
            spans.allSatisfy {
                $0.attributes.get(RouterTelemetry.AttributeKey.submissionCause) == .string(Self.messageCause)
            })
    }

    @Test("one streamed answer opens one submission span whose cause is a message")
    func streamedAnswerOpensOneSubmissionSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { await fixture.end() }

        var streamed = ""
        for try await chunk in await fixture.session.streamResponse(to: Self.prompt) {
            streamed += chunk
        }
        #expect(streamed == Self.cannedAnswer)

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.attributes.get(RouterTelemetry.AttributeKey.submissionCause) == .string(Self.messageCause))
        #expect(span.errors.isEmpty)
    }

    @Test("one sent message opens one submission span whose cause is a message")
    func sentMessageOpensOneSubmissionSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { await fixture.end() }

        // `send` starts the submission, and no other call is necessary.
        try fixture.session.send(Self.prompt)
        #expect(await fixture.session.becomesIdle())

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.attributes.get(RouterTelemetry.AttributeKey.submissionCause) == .string(Self.messageCause))
        #expect(span.errors.isEmpty)
    }

    @Test("a submission span carries the ids of the mail that the submission delivers")
    func submissionSpanCarriesTheMailIDs() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { await fixture.end() }

        let id = try fixture.session.send(Self.prompt)
        #expect(await fixture.session.becomesIdle())

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.attributes.get(RouterTelemetry.AttributeKey.submissionMailIds) == .stringArray([id.description]))
    }

    @Test("a submission that throws keeps its span, with the error recorded")
    func failedSubmissionRecordsItsErrorOnTheSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { await fixture.end() }

        fixture.backend.shouldThrow = true
        await #expect(throws: StubSessionBackend.StubError.boom) {
            _ = try await fixture.session.respond(to: Self.prompt)
        }

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.failureType == "\(StubSessionBackend.StubError.self)")
    }

    @Test("an answer with no tracer injected and no backend bootstrapped comes normally")
    func untracedAnswerComesNormally() async throws {
        let fixture = try await Self.makeFixture(tracer: nil)
        defer { await fixture.end() }

        let answer = try await fixture.session.respond(to: Self.prompt)
        #expect(answer == Self.cannedAnswer)
    }
}
