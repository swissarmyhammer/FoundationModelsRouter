import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises task ^yx6931z: the span of a submission that delivers run mail
/// is tied to the span of the sender of that mail.
///
/// The pump is a detached task, so no tracing context of a poster reaches it.
/// The stage of run mail keeps the context of the poster
/// (``SessionOutbox/MailCaller``). A submission whose mail has no caller
/// context of a user-type mail is a child of the first delivered mail with a
/// sender context, and each submission links to the sender span of each run
/// mail it delivers.
///
/// Everything runs over a ``StubSessionBackend`` and an `InMemoryTracer`, so
/// the suite needs no network and no GPU.
@Suite("The span of a submission that delivers run mail")
struct RunMailSubmissionTracingTests {
    /// The canned text the stub backend answers every submission with.
    private static let cannedAnswer = "stub answer"

    /// The prompt of each caller message.
    private static let prompt = "start the background job"

    /// The name of each span that posts run mail.
    private static let senderSpanName = "test.sender"

    /// The token counts one successful stub submission meters.
    private static let submissionUsage = (input: 11, output: 7)

    /// Builds a session over one shared ``StubSessionBackend`` that reports to
    /// `tracer`.
    ///
    /// - Parameter tracer: The tracer each span of the session goes to.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    private static func makeFixture(tracer: InMemoryTracer) async throws -> StubBackendSessionFixture {
        try await StubBackendSessionFixture.make(
            tempDirPrefix: "RunMailSubmissionTracingTests", tracer: tracer, responseText: cannedAnswer,
            usageIncrement: submissionUsage)
    }

    /// Posts the message of the run `token` to `session` inside a new span
    /// of `tracer`, as a tool body of another session posts it.
    ///
    /// - Parameters:
    ///   - token: The completion token of the run.
    ///   - session: The session whose outbox gets the mail.
    ///   - tracer: The tracer of the sender span.
    /// - Returns: The span context of the sender span.
    private static func postMessage(
        of token: String, to session: any RoutedSession, inSpanOf tracer: InMemoryTracer
    ) async throws -> InMemorySpanContext {
        let event = OperationEvent(
            tool: FakeRun.tool, op: FakeRun.op, correlationID: token, kind: .message, detail: "half done")
        return try #require(
            await tracer.withSpan(senderSpanName) { span in
                await session.outbox.post(event: event)
                return span.context.inMemorySpanContext
            })
    }

    /// The span ids that the links of `span` point to.
    ///
    /// - Parameter span: A finished span.
    /// - Returns: The span id of each link, in link order.
    private static func linkedSpanIDs(of span: FinishedInMemorySpan) -> [String] {
        span.links.compactMap { $0.context.inMemorySpanContext?.spanID }
    }

    @Test("a submission of run mail alone is a child of the sender span of that mail, and links to it")
    func runMailOnlySubmissionHasTheSenderAsParent() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { await fixture.end() }
        let latch = RunLatch()
        defer { await latch.open() }
        let token = await trackFakeRun(on: fixture.session.runPlane, latch: latch)
        // The first answer attaches the outbox, so later mail wakes the pump.
        _ = try await fixture.session.respond(to: Self.prompt)

        let sender = try await Self.postMessage(of: token, to: fixture.session, inSpanOf: tracer)
        #expect(await fixture.session.becomesIdle())

        let span = try #require(tracer.finishedSubmissionSpans(causedBy: .mail).first)
        #expect(span.traceID == sender.traceID)
        #expect(span.parentSpanID == sender.spanID)
        #expect(Self.linkedSpanIDs(of: span) == [sender.spanID])
    }

    @Test("a submission links to the sender span of each run mail that it delivers")
    func submissionLinksToEachRunMailSender() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { await fixture.end() }
        let latch = RunLatch()
        defer { await latch.open() }
        let first = await trackFakeRun(on: fixture.session.runPlane, latch: latch)
        let second = await trackFakeRun(on: fixture.session.runPlane, latch: latch)
        // No answer attached the outbox yet, so the mail waits for the next
        // caller message, and that message carries it.
        let firstSender = try await Self.postMessage(of: first, to: fixture.session, inSpanOf: tracer)
        let secondSender = try await Self.postMessage(of: second, to: fixture.session, inSpanOf: tracer)

        _ = try await fixture.session.respond(to: Self.prompt)

        let span = try #require(tracer.finishedSubmissionSpans(causedBy: .message).first)
        #expect(Self.linkedSpanIDs(of: span) == [firstSender.spanID, secondSender.spanID])
        // The caller message has no span, so the first sender is the parent.
        #expect(span.parentSpanID == firstSender.spanID)
    }
}
