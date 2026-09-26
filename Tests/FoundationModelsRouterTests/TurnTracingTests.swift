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
/// ``SpanContentSafetyTests``, which names no span and therefore already
/// measures this one.
///
/// Everything runs over stubs — a stub ``ModelLoader``, a
/// ``StubSessionBackend`` with canned usage counts, and an `InMemoryTracer` —
/// so the suite needs no network, no GPU and no bootstrapped tracing backend.
@Suite("Submission tracing")
struct TurnTracingTests {
    /// The span name every submission opens.
    private static let spanName = RouterTracing.SpanName.submission

    /// The `submission.cause` value of a submission that carries a caller
    /// message.
    private static let messageCause = SubmissionStart.Cause.message.rawValue

    /// The number of the second submission of a session. The session numbers
    /// its submissions 1, 2, 3, and so on.
    private static let secondSubmissionNumber: UInt64 = 2

    /// The token counts one successful stub turn meters.
    private static let turnUsage = (input: 11, output: 7)

    /// The canned text the stub backend answers every turn with.
    private static let cannedAnswer = "stub answer"

    /// The prompt every driven turn carries.
    private static let prompt = "drive one turn"

    /// A container that vends one caller-supplied backend for every session it
    /// makes, so a test can set the backend's metered usage up front and can
    /// flip ``StubSessionBackend/shouldThrow`` on it after the session exists.
    ///
    /// It conforms to ``LoadedLLMContainer`` directly, and not to
    /// ``PlainTranscriptStubContainer``, because that protocol's
    /// `makeSession(transcript:)` builds a fresh backend, which would leave the
    /// test holding a backend the session no longer runs on.
    private struct SharedBackendContainer: LoadedLLMContainer {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// The backend every session this container vends runs on.
        let backend: StubSessionBackend

        /// Vends ``backend``.
        ///
        /// - Parameter instructions: The session's system instructions, unread:
        ///   the shared backend was built before this call.
        /// - Returns: ``backend``.
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            backend
        }

        /// Vends ``backend``.
        ///
        /// - Parameter transcript: The transcript to seed from, unread: the
        ///   shared backend carries its own history.
        /// - Returns: ``backend``.
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            backend
        }
    }

    /// Everything one driven turn needs, and everything a test reads back off
    /// it.
    private struct TurnFixture {
        /// The session the test drives its turn on.
        let session: RoutedSession

        /// The backend that session runs on, so a test can make a later turn
        /// fail.
        let backend: StubSessionBackend

        /// The resolved profile, so a test can name the model the turn ran on.
        let profile: LanguageModelProfile

        /// The router that resolved the profile, so a test can name its
        /// recording root.
        let router: Router

        /// The temp directory the router cached into, which the caller must
        /// remove.
        let directory: URL
    }

    /// Builds a router, a resolved profile and a session over one shared
    /// ``StubSessionBackend``.
    ///
    /// - Parameters:
    ///   - tracer: The tracer every handle of the resolved profile carries, or
    ///     `nil` to read `InstrumentationSystem.tracer` at call time.
    ///   - usageIncrement: The token counts the backend meters on each
    ///     successful turn, or `nil` to report no usage at all.
    /// - Returns: The fixture the test drives and reads back.
    /// - Throws: Whatever profile resolution throws.
    private static func makeFixture(
        tracer: (any Tracer)?,
        usageIncrement: (input: Int, output: Int)? = turnUsage
    ) async throws -> TurnFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "TurnTracingTests")
        let backend = StubSessionBackend(responseText: cannedAnswer, usageIncrement: usageIncrement)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: SharedBackendContainer(backend: backend),
                dimension: RouterTestFixtures.stubDimension
            ),
            tracer: tracer
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return TurnFixture(
            session: profile.standard.makeSession(),
            backend: backend,
            profile: profile,
            router: router,
            directory: directory)
    }

    /// The finished submission spans the tracer holds, in the order they
    /// finished.
    ///
    /// Filtered by name rather than counted over the whole tracer: the
    /// fixture's own ``Router/resolve(profile:reporting:)`` reports to the
    /// same tracer, and it opens a resolve span with one load span under it
    /// for each slot it loads.
    ///
    /// - Parameter tracer: The tracer the submissions reported to.
    /// - Returns: The finished submission spans.
    private static func submissionSpans(reportedTo tracer: InMemoryTracer) -> [FinishedInMemorySpan] {
        tracer.finishedSpans.filter { $0.operationName == spanName }
    }

    /// The one submission span that one answer of one submission opened.
    ///
    /// - Parameter tracer: The tracer the submission reported to.
    /// - Returns: The single finished submission span.
    /// - Throws: When the tracer holds no submission span, or more than one.
    private static func singleSpan(reportedTo tracer: InMemoryTracer) throws -> FinishedInMemorySpan {
        let spans = submissionSpans(reportedTo: tracer)
        try #require(spans.count == 1)
        return try #require(spans.first)
    }

    @Test("one respond call opens one client submission span carrying the documented attributes")
    func respondOpensOneSubmissionSpanWithAttributes() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: Self.prompt)
        #expect(answer == Self.cannedAnswer)

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .client)
        #expect(
            span.attributes.get(RouterTracing.AttributeKey.routerId)
                == .string(fixture.router.id.description))
        #expect(
            span.attributes.get(RouterTracing.AttributeKey.sessionId)
                == .string(fixture.session.id.description))
        #expect(
            span.attributes.get(RouterTracing.AttributeKey.modelRef)
                == .string(fixture.profile.standard.chosen.stringValue))
        #expect(span.attributes.get(RouterTracing.AttributeKey.submissionId) == .string(SubmissionID(1).description))
        #expect(span.attributes.get(RouterTracing.AttributeKey.submissionCause) == .string(Self.messageCause))
        #expect(span.errors.isEmpty)
    }

    @Test("a good submission carries the token counts its usage snapshot measured")
    func goodSubmissionCarriesMeasuredTokenCounts() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.session.respond(to: Self.prompt)

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(
            span.attributes.get(RouterTracing.AttributeKey.tokensIn) == .int64(Int64(Self.turnUsage.input)))
        #expect(
            span.attributes.get(RouterTracing.AttributeKey.tokensOut) == .int64(Int64(Self.turnUsage.output)))
    }

    @Test("two answers on one session open one submission span each, numbered in their session")
    func eachSubmissionOpensItsOwnSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.session.respond(to: Self.prompt)
        _ = try await fixture.session.respond(to: Self.prompt)

        let spans = Self.submissionSpans(reportedTo: tracer)
        #expect(
            spans.map { $0.attributes.get(RouterTracing.AttributeKey.submissionId) }
                == [.string(SubmissionID(1).description), .string(SubmissionID(Self.secondSubmissionNumber).description)])
        #expect(
            spans.allSatisfy {
                $0.attributes.get(RouterTracing.AttributeKey.submissionCause) == .string(Self.messageCause)
            })
    }

    @Test("one streamed answer opens one submission span whose cause is a message")
    func streamedAnswerOpensOneSubmissionSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var streamed = ""
        for try await chunk in await fixture.session.streamResponse(to: Self.prompt) {
            streamed += chunk
        }
        #expect(streamed == Self.cannedAnswer)

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.attributes.get(RouterTracing.AttributeKey.submissionCause) == .string(Self.messageCause))
        #expect(span.errors.isEmpty)
    }

    @Test("one sent message opens one submission span whose cause is a message")
    func sentMessageOpensOneSubmissionSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // `send` starts the submission, and no other call is necessary.
        await fixture.session.send(Self.prompt)
        #expect(await fixture.session.becomesIdle())

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.attributes.get(RouterTracing.AttributeKey.submissionCause) == .string(Self.messageCause))
        #expect(span.errors.isEmpty)
    }

    @Test("a submission that throws keeps its span, with the error recorded")
    func failedTurnRecordsItsErrorOnTheSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.backend.shouldThrow = true
        await #expect(throws: StubSessionBackend.StubError.boom) {
            _ = try await fixture.session.respond(to: Self.prompt)
        }

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.errors.count == 1)
    }

    @Test("a turn with no tracer injected and no backend bootstrapped answers normally")
    func untracedTurnAnswersNormally() async throws {
        let fixture = try await Self.makeFixture(tracer: nil)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: Self.prompt)
        #expect(answer == Self.cannedAnswer)
    }
}
