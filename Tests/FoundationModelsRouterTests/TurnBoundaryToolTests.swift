import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task w77k41m's turn-boundary hook: ``TurnBoundaryTool``.
/// eventplan.md § "Consolidation of the siblings" gives MultiTool's contract —
/// "The surface never changes in place. A change means rebuild and swap. ...
/// MultiTool swaps it in atomically at the next turn boundary — the same
/// boundary where the outbox folds in events." Router owns that boundary, and
/// this hook is how a mounted tool observes it.
///
/// Everything runs against stubs — no MLX, no network, no GPU. The probe tool
/// and the backend share one ``CallOrderLog``, so a test can prove the hook
/// fires before the model ever sees the composed prompt, not merely that it
/// fires at all.
@Suite("TurnBoundaryTool: the session's turn-boundary clock tick")
struct TurnBoundaryToolTests {
    // MARK: - Shared order log

    /// Records each observation a turn made, in the order it happened, shared
    /// by a ``TurnBoundaryProbeTool`` and an ``OrderRecordingBackend`` so a
    /// test can read one combined timeline across both.
    private actor CallOrderLog {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

    // MARK: - Test tools

    /// A `Tool` conforming to ``TurnBoundaryTool`` that records each
    /// `turnWillBegin()` call into the shared ``CallOrderLog``.
    private final class TurnBoundaryProbeTool: Tool, TurnBoundaryTool, Sendable {
        let name = "turn-boundary-probe"
        let description = "test-only tool that records each turnWillBegin() call"
        let log: CallOrderLog

        init(log: CallOrderLog) {
            self.log = log
        }

        func turnWillBegin() async {
            await log.record("turnWillBegin")
        }

        func call(arguments: AmbientToolArguments) async throws -> String {
            "handled: \(arguments.value)"
        }
    }

    /// A plain `Tool` with no ``TurnBoundaryTool`` conformance, mounted
    /// alongside ``TurnBoundaryProbeTool`` to prove a mixed tool list calls
    /// only the conforming tool.
    private struct NonConformingTool: Tool {
        let name = "turn-boundary-non-conformer"
        let description = "test-only tool with no turn-boundary conformance"

        func call(arguments: AmbientToolArguments) async throws -> String {
            "plain: \(arguments.value)"
        }
    }

    // MARK: - Stub backend recording call order

    /// Wraps a ``StubSessionBackend``, additionally recording each
    /// `respond(to:maxTokens:)` call into the shared ``CallOrderLog`` — so a
    /// test can prove the hook fires before the model call, not merely that
    /// it fires.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time, and `log` is
    /// itself an actor.
    private final class OrderRecordingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let inner = StubSessionBackend()
        private let log: CallOrderLog

        init(log: CallOrderLog) {
            self.log = log
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            await log.record("respond")
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            inner.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            await log.record("respond")
            return try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            inner.makeFork()
        }

        func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
            inner.makeFork(tools: tools)
        }

        func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
            inner.replacingTranscript(transcript)
        }

        func transcriptEntries() -> [Transcript.Entry] {
            inner.transcriptEntries()
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            inner.usageTokenCounts()
        }
    }

    /// Vends one retained ``OrderRecordingBackend`` per session, sharing the
    /// caller's ``CallOrderLog``.
    private final class OrderRecordingLLMContainer: PlainTranscriptStubContainer, @unchecked Sendable {
        private let log: CallOrderLog

        init(log: CallOrderLog) {
            self.log = log
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            OrderRecordingBackend(log: log)
        }
    }

    // MARK: - Fixtures

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "TurnBoundaryToolTests"

    /// Builds a fresh router + resolved profile + vended session over an
    /// ``OrderRecordingBackend`` sharing `log`, mounting `tools`.
    private static func makeSession(log: CallOrderLog, tools: [any Tool]) async throws -> (
        session: RoutedSession, dir: URL
    ) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let container = OrderRecordingLLMContainer(log: log)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(tools: tools)
        return (session, dir)
    }

    // MARK: - Tests

    @Test("one respond() turn fires turnWillBegin() once, before the model sees the composed prompt")
    @MainActor
    func oneRespondFiresOneCallBeforeTheModelCall() async throws {
        let log = CallOrderLog()
        let probe = TurnBoundaryProbeTool(log: log)
        let (session, dir) = try await Self.makeSession(log: log, tools: [probe])
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "hello")

        let events = await log.events
        #expect(events == ["turnWillBegin", "respond"])
    }

    @Test("two respond() turns fire turnWillBegin() twice, once per turn")
    @MainActor
    func twoTurnsFireTwoCalls() async throws {
        let log = CallOrderLog()
        let probe = TurnBoundaryProbeTool(log: log)
        let (session, dir) = try await Self.makeSession(log: log, tools: [probe])
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")

        let events = await log.events
        #expect(events == ["turnWillBegin", "respond", "turnWillBegin", "respond"])
    }

    @Test("a tool with no TurnBoundaryTool conformance gets no call, and a mixed list calls only the conformer")
    @MainActor
    func nonConformingToolGetsNoCall() async throws {
        let log = CallOrderLog()
        let probe = TurnBoundaryProbeTool(log: log)
        let plain = NonConformingTool()
        let (session, dir) = try await Self.makeSession(log: log, tools: [plain, probe])
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "hello")

        let events = await log.events
        #expect(events == ["turnWillBegin", "respond"])
    }
}
