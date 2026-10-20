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

    /// One session over a ``StubSessionBackend`` that reports to a tracer.
    private struct Fixture: SessionDirectoryFixture {
        /// The session under test.
        let session: any RoutedSession

        /// The tracer each span of the session goes to.
        let tracer: InMemoryTracer

        /// The resolved profile, kept alive while the session runs.
        let profile: LanguageModelProfile

        /// The temp directory the router caches into.
        let directory: URL
    }

    /// Builds a router, a resolved profile and a session that report to one
    /// `InMemoryTracer`.
    ///
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws. Before it throws, it
    ///   removes the temp directory (rule T1).
    private static func makeFixture() async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "RunMailSubmissionTracingTests")
        let tracer = InMemoryTracer()
        let backend = StubSessionBackend(responseText: cannedAnswer, usageIncrement: (input: 11, output: 7))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: SharedBackendContainer(backend: backend),
                dimension: RouterTestFixtures.stubDimension
            ),
            tracer: tracer
        )
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        }
        return Fixture(
            session: profile.standard.makeSession(), tracer: tracer, profile: profile, directory: directory)
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

    /// The finished submission spans whose cause is `cause`.
    ///
    /// - Parameters:
    ///   - cause: The cause of the submissions.
    ///   - tracer: The tracer the session reported to.
    /// - Returns: Those spans, in the order they finished.
    private static func submissionSpans(
        _ cause: SubmissionStart.Cause, reportedTo tracer: InMemoryTracer
    ) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter {
            $0.operationName == RouterTelemetry.SpanName.submission
                && $0.attributes.get(RouterTelemetry.AttributeKey.submissionCause) == .string(cause.rawValue)
        }
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
        let fixture = try await Self.makeFixture()
        defer { await fixture.end() }
        let latch = RunLatch()
        defer { await latch.open() }
        let token = await trackFakeRun(on: fixture.session.runPlane, latch: latch)
        // The first answer attaches the outbox, so later mail wakes the pump.
        _ = try await fixture.session.respond(to: Self.prompt)

        let sender = try await Self.postMessage(of: token, to: fixture.session, inSpanOf: fixture.tracer)
        #expect(await fixture.session.becomesIdle())

        let span = try #require(Self.submissionSpans(.mail, reportedTo: fixture.tracer).first)
        #expect(span.traceID == sender.traceID)
        #expect(span.parentSpanID == sender.spanID)
        #expect(Self.linkedSpanIDs(of: span) == [sender.spanID])
    }

    @Test("a submission links to the sender span of each run mail that it delivers")
    func submissionLinksToEachRunMailSender() async throws {
        let fixture = try await Self.makeFixture()
        defer { await fixture.end() }
        let latch = RunLatch()
        defer { await latch.open() }
        let first = await trackFakeRun(on: fixture.session.runPlane, latch: latch)
        let second = await trackFakeRun(on: fixture.session.runPlane, latch: latch)
        // No answer attached the outbox yet, so the mail waits for the next
        // caller message, and that message carries it.
        let firstSender = try await Self.postMessage(of: first, to: fixture.session, inSpanOf: fixture.tracer)
        let secondSender = try await Self.postMessage(of: second, to: fixture.session, inSpanOf: fixture.tracer)

        _ = try await fixture.session.respond(to: Self.prompt)

        let span = try #require(Self.submissionSpans(.message, reportedTo: fixture.tracer).first)
        #expect(Self.linkedSpanIDs(of: span) == [firstSender.spanID, secondSender.spanID])
        // The caller message has no span, so the first sender is the parent.
        #expect(span.parentSpanID == firstSender.spanID)
    }
}
