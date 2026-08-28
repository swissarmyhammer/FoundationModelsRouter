import Foundation
import FoundationModels
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^kbnbp4a: every generation turn opens one OpenTelemetry span
/// through `swift-distributed-tracing`.
///
/// One chokepoint carries the span, so every surface that starts a turn is held
/// to the same contract: ``RoutedSession/respond(to:maxTokens:)``,
/// ``RoutedSession/streamResponse(to:maxTokens:)``,
/// ``RoutedSession/streamEvents(to:maxTokens:)`` and
/// ``RoutedSession/dispatchNextPrompt()``. This suite holds that contract: the
/// operation name, the span kind, the identity attributes, the entry point that
/// started the turn, the measured token counts, and the error record on a turn
/// that throws.
///
/// The rule that no attribute carries the caller's own content lives in
/// ``SpanContentSafetyTests``, which names no span and therefore already
/// measures this one.
///
/// Everything runs over stubs — a stub ``ModelLoader``, a
/// ``StubSessionBackend`` with canned usage counts, and an `InMemoryTracer` —
/// so the suite needs no network, no GPU and no bootstrapped tracing backend.
@Suite("Turn tracing")
struct TurnTracingTests {
    /// The span name every turn opens.
    private static let spanName = "FoundationModelsRouter.turn"

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

    /// The one span a driven turn opened.
    ///
    /// - Parameter tracer: The tracer the turn reported to.
    /// - Returns: The single finished span.
    /// - Throws: When the tracer holds no span, or more than one.
    private static func singleSpan(reportedTo tracer: InMemoryTracer) throws -> FinishedInMemorySpan {
        let spans = tracer.finishedSpans
        try #require(spans.count == 1)
        return try #require(spans.first)
    }

    @Test("one respond call opens one client turn span carrying the documented attributes")
    func respondOpensOneTurnSpanWithAttributes() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: Self.prompt)
        #expect(answer == Self.cannedAnswer)

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .client)
        #expect(span.attributes.get("router.id") == .string(fixture.router.id.description))
        #expect(span.attributes.get("session.id") == .string(fixture.session.id.description))
        #expect(
            span.attributes.get("model.ref")
                == .string(fixture.profile.standard.chosen.stringValue))
        #expect(span.attributes.get("turn.id") == .string("1"))
        #expect(span.attributes.get("turn.entry_point") == .string("respond"))
        #expect(span.errors.isEmpty)
    }

    @Test("a good turn carries the token counts its usage snapshot measured")
    func goodTurnCarriesMeasuredTokenCounts() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.session.respond(to: Self.prompt)

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.attributes.get("tokens.in") == .int64(Int64(Self.turnUsage.input)))
        #expect(span.attributes.get("tokens.out") == .int64(Int64(Self.turnUsage.output)))
    }

    @Test("one streamed turn opens one turn span naming the stream entry point")
    func streamedTurnOpensOneTurnSpan() async throws {
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
        #expect(span.attributes.get("turn.entry_point") == .string("stream"))
        #expect(span.errors.isEmpty)
    }

    @Test("one dispatched turn opens one turn span naming the dispatch entry point")
    func dispatchedTurnOpensOneTurnSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await Self.makeFixture(tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await fixture.session.enqueue(prompt: Self.prompt)
        let answer = try await fixture.session.dispatchNextPrompt()
        #expect(answer == Self.cannedAnswer)

        let span = try Self.singleSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.attributes.get("turn.entry_point") == .string("dispatch"))
        #expect(span.errors.isEmpty)
    }

    @Test("a turn that throws keeps its span, with the error recorded")
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
