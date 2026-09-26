import Foundation
import FoundationModels
import struct MLXLMCommon.RejectedToolCallError
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises the submission-boundary hook of task w77k41m, renamed by task
/// ^f33q8gw: ``SubmissionBoundaryTool``.
/// eventplan.md § "Consolidation of the siblings" gives MultiTool's contract —
/// "The surface never changes in place. A change means rebuild and swap. ...
/// MultiTool swaps it in atomically at the next boundary — the same boundary
/// where the outbox merges in events." Router owns that boundary: the start of
/// each submission. This hook is how a mounted tool observes it.
///
/// Everything runs against stubs — no MLX, no network, no GPU. The probe tool
/// and the backend share one ``CallOrderLog``, so a test can prove the hook
/// fires before the model sees the composed prompt, not only that it fires.
@Suite("SubmissionBoundaryTool: the clock tick before each submission of a session")
struct SubmissionBoundaryToolTests {
    // MARK: - Shared order log

    /// Records each observation of a session, in the order it happened, shared
    /// by a ``SubmissionBoundaryProbeTool`` and an ``OrderRecordingBackend`` so
    /// a test can read one combined timeline across both.
    private actor CallOrderLog {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

    // MARK: - Log entries

    /// The log entry of one ``SubmissionBoundaryTool/submissionWillBegin()`` call.
    private static let hookEntry = "submissionWillBegin"

    /// The log entry of one model call of the backend.
    private static let modelCallEntry = "respond"

    /// The log of one submission: the hook call, then the model call.
    private static let oneSubmission = [hookEntry, modelCallEntry]

    // MARK: - Test tools

    /// A `Tool` conforming to ``SubmissionBoundaryTool`` that records each
    /// `submissionWillBegin()` call into the shared ``CallOrderLog``.
    private final class SubmissionBoundaryProbeTool: Tool, SubmissionBoundaryTool, Sendable {
        let name = "submission-boundary-probe"
        let description = "test-only tool that records each submissionWillBegin() call"
        let log: CallOrderLog

        init(log: CallOrderLog) {
            self.log = log
        }

        func submissionWillBegin() async {
            await log.record(SubmissionBoundaryToolTests.hookEntry)
        }

        func call(arguments: AmbientToolArguments) async throws -> String {
            "handled: \(arguments.value)"
        }
    }

    /// A plain `Tool` with no ``SubmissionBoundaryTool`` conformance, mounted
    /// beside ``SubmissionBoundaryProbeTool`` to prove a mixed tool list calls
    /// only the conforming tool.
    private struct NonConformingTool: Tool {
        let name = "submission-boundary-non-conformer"
        let description = "test-only tool with no submission-boundary conformance"

        func call(arguments: AmbientToolArguments) async throws -> String {
            "plain: \(arguments.value)"
        }
    }

    // MARK: - Stub backend recording call order

    /// Wraps a ``StubSessionBackend``, and also records each
    /// `respond(to:maxTokens:)` call into the shared ``CallOrderLog`` — so a
    /// test can prove the hook fires before the model call, not only that
    /// it fires.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time, `log` is an actor,
    /// and ``rejectionsLeft`` is behind a lock.
    private final class OrderRecordingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        private let inner = StubSessionBackend()
        private let log: CallOrderLog

        /// How many of the next calls throw a rejected tool call before they
        /// answer. A rejected tool call makes the session run a continuation
        /// submission of the same answer.
        private let rejectionsLeft: Mutex<Int>

        init(log: CallOrderLog, rejectedCallCount: Int) {
            self.log = log
            self.rejectionsLeft = Mutex(rejectedCallCount)
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            await log.record(SubmissionBoundaryToolTests.modelCallEntry)
            try throwIfRejecting()
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        /// Throws a rejected tool call, as `MLXLanguageModel` does when it
        /// cannot parse a tool call, while ``rejectionsLeft`` is not zero.
        ///
        /// - Throws: `RejectedToolCallError` for each rejection left.
        private func throwIfRejecting() throws {
            let rejects = rejectionsLeft.withLock { left in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
            if rejects {
                throw RejectedToolCallError(RejectingLanguageModel.Executor.rejection)
            }
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            inner.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            await log.record(SubmissionBoundaryToolTests.modelCallEntry)
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

        /// How many calls of the vended backend throw a rejected tool call
        /// before they answer.
        private let rejectedCallCount: Int

        init(log: CallOrderLog, rejectedCallCount: Int) {
            self.log = log
            self.rejectedCallCount = rejectedCallCount
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            OrderRecordingBackend(log: log, rejectedCallCount: rejectedCallCount)
        }
    }

    // MARK: - Fixtures

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "SubmissionBoundaryToolTests"

    /// The detail of the terminal of the background run whose mail starts a
    /// submission.
    private static let settledRunDetail = "the background job finished"

    /// Builds a fresh router + resolved profile + vended session over an
    /// ``OrderRecordingBackend`` sharing `log`, mounting `tools`.
    ///
    /// - Parameters:
    ///   - log: The order log the tools and the backend share.
    ///   - tools: The tools the session mounts.
    ///   - rejectedCallCount: How many backend calls throw a rejected tool
    ///     call before they answer.
    /// - Returns: The session and the temp directory the caller removes.
    /// - Throws: Whatever profile resolution throws.
    private static func makeSession(
        log: CallOrderLog, tools: [any Tool], rejectedCallCount: Int = 0
    ) async throws -> (session: RoutedSession, dir: URL) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let container = OrderRecordingLLMContainer(log: log, rejectedCallCount: rejectedCallCount)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(tools: tools)
        return (session, dir)
    }

    // MARK: - Tests

    @Test("one respond() answer fires submissionWillBegin() once, before the model sees the composed prompt")
    @MainActor
    func oneRespondFiresOneCallBeforeTheModelCall() async throws {
        let log = CallOrderLog()
        let probe = SubmissionBoundaryProbeTool(log: log)
        let (session, dir) = try await Self.makeSession(log: log, tools: [probe])
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "hello")

        let events = await log.events
        #expect(events == Self.oneSubmission)
    }

    @Test("two respond() answers fire submissionWillBegin() twice, once for each submission")
    @MainActor
    func twoAnswersFireTwoCalls() async throws {
        let log = CallOrderLog()
        let probe = SubmissionBoundaryProbeTool(log: log)
        let (session, dir) = try await Self.makeSession(log: log, tools: [probe])
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "first")
        _ = try await session.respond(to: "second")

        let events = await log.events
        #expect(events == Self.oneSubmission + Self.oneSubmission)
    }

    @Test("a tool with no SubmissionBoundaryTool conformance gets no call, and a mixed list calls only the conformer")
    @MainActor
    func nonConformingToolGetsNoCall() async throws {
        let log = CallOrderLog()
        let probe = SubmissionBoundaryProbeTool(log: log)
        let plain = NonConformingTool()
        let (session, dir) = try await Self.makeSession(log: log, tools: [plain, probe])
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "hello")

        let events = await log.events
        #expect(events == Self.oneSubmission)
    }

    @Test("a continuation submission of an answer fires submissionWillBegin() again, before its own model call")
    @MainActor
    func aContinuationSubmissionFiresItsOwnCall() async throws {
        let log = CallOrderLog()
        let probe = SubmissionBoundaryProbeTool(log: log)
        let (session, dir) = try await Self.makeSession(log: log, tools: [probe], rejectedCallCount: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The first submission throws a rejected tool call. The session sends
        // the rejection back to the model in a continuation submission of the
        // same answer.
        _ = try await session.respond(to: "hello")

        let events = await log.events
        #expect(events == Self.oneSubmission + Self.oneSubmission)
    }

    @Test("a submission that mail started, with no caller message, fires submissionWillBegin() before its model call")
    @MainActor
    func aSubmissionThatMailStartedFiresACall() async throws {
        let log = CallOrderLog()
        let probe = SubmissionBoundaryProbeTool(log: log)
        let (session, dir) = try await Self.makeSession(log: log, tools: [probe])
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await session.respond(to: "hello")
        let latch = RunLatch()
        await latch.open()
        let token = await trackFakeRun(on: session.mailbox, latch: latch, detailOnSettle: Self.settledRunDetail)
        let terminal = try await MountFixtures.settledTerminal(of: token, in: session.mailbox)

        // No caller asks: the terminal of the settled run is mail, and the
        // mail itself starts the next submission.
        await session.outbox.post(event: terminal)

        let expected = Self.oneSubmission + Self.oneSubmission
        #expect(await BoundedWait.conditionReached("the mail submission reaching the backend") { await log.events == expected })
        #expect(await session.becomesIdle())
    }
}
