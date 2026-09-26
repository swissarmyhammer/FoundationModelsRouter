import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^z6xcmnh's recorded decision: a generation that makes no
/// observable progress is **reported**, never bounded. The session logs a line
/// and emits ``SessionEvent/generationStalled(_:)``; it cancels nothing, fails
/// nothing, and changes no answer.
///
/// The suite pins the two things the report has to get right. First, the signal
/// reaches a caller on both routes — the answer's own
/// ``RoutedSession/streamEvents(to:maxTokens:)`` stream and the session-wide
/// ``RoutedSession/streamSessionEvents()`` feed a
/// ``RoutedSession/respond(to:maxTokens:)`` caller subscribes to. Second, the
/// report says honestly what the session could see: a streaming answer counts
/// real fragments, and a `respond` answer counts none, because the backend
/// hands it one whole string.
@Suite("Generation stall diagnostic")
struct GenerationStallDiagnosticTests {
    // MARK: - Stalling backend

    /// A ``LanguageModelSessionBackend`` that produces `fragmentsBeforeStall`
    /// stream chunks and then suspends until a test releases it — a decode that
    /// stops making progress while the model call is still in flight.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time, and the two
    /// semaphores are themselves `Sendable`.
    private final class StallingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// The plain stub every non-stalling behaviour delegates to, so this
        /// backend only has to model the stall.
        private let inner = StubSessionBackend()

        /// Signalled once the whole-answer model call has suspended, so a test
        /// knows the stall has begun rather than guessing at it.
        ///
        /// The streaming call signals nothing of the kind. What a streaming test
        /// is about is what the *session* observed, and the session's own
        /// ``SessionEvent/textDelta(_:)`` says that; a backend-side flag says
        /// only that a chunk was written into a buffer nobody has read yet.
        let suspended = AsyncSemaphore(value: 0)

        /// Awaited by the suspended model call; signalling it lets the answer
        /// finish.
        let release = AsyncSemaphore(value: 0)

        /// How many stream chunks to produce before suspending.
        let fragmentsBeforeStall: Int

        /// Creates a stalling backend.
        ///
        /// - Parameter fragmentsBeforeStall: How many stream chunks to produce
        ///   before the model call suspends. Ignored on the non-streaming path,
        ///   which produces nothing at all.
        init(fragmentsBeforeStall: Int = 0) {
            self.fragmentsBeforeStall = fragmentsBeforeStall
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            suspended.signal()
            await release.wait()
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            let fragmentsBeforeStall = fragmentsBeforeStall
            let release = release
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for index in 0..<fragmentsBeforeStall {
                        continuation.yield("chunk-\(index) ")
                    }
                    await release.wait()
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await respond(to: prompt, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            inner.makeFork()
        }

        func transcriptEntries() -> [Transcript.Entry] {
            inner.transcriptEntries()
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            inner.usageTokenCounts()
        }
    }

    /// Vends one retained ``StallingBackend`` per session.
    ///
    /// `@unchecked Sendable` invariant: `lastBackend` is written once,
    /// synchronously, inside `makeSession(instructions:)` — called from the
    /// synchronous session-vending path — and read only by the test task after
    /// that vend returns, so the write and every read happen in order.
    private final class StallingLLMContainer: PlainTranscriptStubContainer, @unchecked Sendable {
        /// How many stream chunks each vended backend produces before suspending.
        let fragmentsBeforeStall: Int

        /// The backend vended most recently — the one the session is driving.
        private(set) var lastBackend: StallingBackend?

        /// Creates a container.
        ///
        /// - Parameter fragmentsBeforeStall: How many stream chunks each vended
        ///   backend produces before suspending.
        init(fragmentsBeforeStall: Int) {
            self.fragmentsBeforeStall = fragmentsBeforeStall
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StallingBackend(fragmentsBeforeStall: fragmentsBeforeStall)
            lastBackend = backend
            return backend
        }
    }

    // MARK: - Tool-using backend

    /// A ``LanguageModelSessionBackend`` whose stream reports appends with no
    /// text, as the snapshots of a tool-using submission do: each append is a
    /// fragment with empty text and a ``GenerationProgressKind`` such as
    /// ``GenerationProgressKind/toolCall``. After the last append the stream
    /// either writes one line of text and finishes, or suspends until a test
    /// releases it.
    ///
    /// Plain `Sendable`: every stored property is a `let` of a `Sendable` type.
    private final class ToolAnswerBackend: LanguageModelSessionBackend, Sendable {
        /// The plain stub every behaviour other than the stream delegates to.
        private let inner = StubSessionBackend()

        /// The appends the stream reports, in order.
        let appends: [GenerationProgressKind]

        /// The pause before each append.
        let pause: Duration

        /// Whether the stream suspends on ``release`` after its last append.
        let holdsAfterLastAppend: Bool

        /// Awaited after the last append when ``holdsAfterLastAppend`` is set.
        let release = AsyncSemaphore(value: 0)

        /// The text the stream writes after its last append, when it does not hold.
        static let answer = "tool answer text"

        /// Creates a tool-using backend.
        ///
        /// - Parameters:
        ///   - appends: The appends the stream reports, in order.
        ///   - pause: The pause before each append.
        ///   - holdsAfterLastAppend: Whether the stream suspends after its last append.
        init(appends: [GenerationProgressKind], pause: Duration, holdsAfterLastAppend: Bool) {
            self.appends = appends
            self.pause = pause
            self.holdsAfterLastAppend = holdsAfterLastAppend
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            inner.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func streamResponseFragments(
            to prompt: String, maxTokens: Int?
        ) -> AsyncThrowingStream<ResponseFragment, Error> {
            let appends = appends
            let pause = pause
            let holdsAfterLastAppend = holdsAfterLastAppend
            let release = release
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for kind in appends {
                        try await Task.sleep(for: pause)
                        continuation.yield(ResponseFragment(text: "", progress: kind))
                    }
                    if holdsAfterLastAppend {
                        await release.wait()
                    } else {
                        continuation.yield(ResponseFragment(text: Self.answer))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await respond(to: prompt, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            inner.makeFork()
        }

        func transcriptEntries() -> [Transcript.Entry] {
            inner.transcriptEntries()
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            inner.usageTokenCounts()
        }
    }

    /// Vends one retained ``ToolAnswerBackend`` per session.
    ///
    /// Plain `Sendable`: its one stored property is a `let` of a `Sendable` type.
    private final class ToolAnswerLLMContainer: PlainTranscriptStubContainer, Sendable {
        /// The backend this container vends.
        let backend: ToolAnswerBackend

        /// Creates a container that vends `backend`.
        ///
        /// - Parameter backend: The backend to vend.
        init(backend: ToolAnswerBackend) {
            self.backend = backend
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            backend
        }
    }

    // MARK: - Fixtures

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "GenerationStallDiagnosticTests"

    /// The reporting interval every stalling test installs.
    ///
    /// Two orders of magnitude under ``BoundedWait/ceilingNanoseconds``, so a
    /// report a loaded machine delays still lands well inside the bound the
    /// waiting test gives it.
    private static let testReportInterval: Duration = .milliseconds(50)

    /// A reporting interval no test answer can reach — installed by the
    /// negative test, so an answer that finishes normally is proved to report
    /// nothing rather than merely to have outrun a short clock.
    private static let unreachableReportInterval: Duration = .seconds(600)

    /// The prompt every test answer sends.
    private static let prompt = "generate something"

    /// Builds a fresh router, resolved profile, and vended session over a
    /// ``StallingBackend``.
    ///
    /// - Parameters:
    ///   - fragmentsBeforeStall: How many stream chunks the backend produces
    ///     before suspending.
    ///   - reportInterval: The stall reporting interval to install on the
    ///     vended session, or `nil` to install none.
    /// - Returns: The session, its backend, and the temp directory to remove.
    private static func makeStallingSession(
        fragmentsBeforeStall: Int = 0,
        reportInterval: Duration? = testReportInterval
    ) async throws -> (session: RoutedSession, backend: StallingBackend, dir: URL) {
        let container = StallingLLMContainer(fragmentsBeforeStall: fragmentsBeforeStall)
        let (session, dir) = try await makeSession(over: container, reportInterval: reportInterval)
        let backend = try #require(container.lastBackend)
        return (session, backend, dir)
    }

    /// Builds a fresh router, resolved profile, and vended session over
    /// `container`, with `reportInterval` installed when it is not `nil`.
    ///
    /// - Parameters:
    ///   - container: The container the router loads.
    ///   - reportInterval: The stall reporting interval to install on the
    ///     vended session, or `nil` to install none.
    /// - Returns: The session, and the temp directory to remove.
    private static func makeSession(
        over container: some LoadedLLMContainer,
        reportInterval: Duration?
    ) async throws -> (session: RoutedSession, dir: URL) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        if let reportInterval {
            await session.setGenerationStallReportInterval(reportInterval)
        }
        return (session, dir)
    }

    // MARK: - The signal a `respond` caller can see

    @Test("a respond answer that stops progressing reports a stall on the session-wide feed")
    @MainActor
    func respondAnswerReportsAStallOnTheSessionWideFeed() async throws {
        let (session, backend, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await SessionEventLog.watch(session)
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await BoundedWait.awaitSignal(backend.suspended, named: "the model call suspended")

        let reported = await BoundedWait.conditionReached("a stall report") {
            await !log.stalls.isEmpty
        }
        backend.release.signal()
        _ = try await answerTask.value
        drain.cancel()

        #expect(reported)
        let stall = try #require(await log.stalls.first)
        // The honest half: a `respond` answer's backend hands back one whole
        // string, so there is no increment to time and the report says so.
        #expect(stall.visibility == .wholeAnswer)
        #expect(stall.timeWithoutProgress > .zero)
        #expect(stall.timeInFlight >= stall.timeWithoutProgress)
    }

    @Test("a stalling answer is still given — the report bounds nothing")
    @MainActor
    func aStallingAnswerIsStillGiven() async throws {
        let (session, backend, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await SessionEventLog.watch(session)
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await BoundedWait.awaitSignal(backend.suspended, named: "the model call suspended")
        _ = await BoundedWait.conditionReached("a stall report") { await !log.stalls.isEmpty }

        backend.release.signal()
        let answer = try await answerTask.value
        drain.cancel()

        #expect(answer == "stub response")
    }

    // MARK: - The signal a streaming caller can see

    @Test(
        "a streaming answer reports the stall against the fragments it counted",
        .timeLimit(.minutes(1)))
    @MainActor
    func streamingAnswerReportsTheStallAgainstCountedFragments() async throws {
        let producedFragments = 2
        let (session, backend, dir) = try await Self.makeStallingSession(
            fragmentsBeforeStall: producedFragments)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Read the answer's own stream here, rather than drain it into a log
        // this test then polls: each element is a suspension the answer itself
        // resumes, so a loaded machine makes this test slower and never red.
        //
        // Which report the test takes is the whole claim. The session counts a
        // fragment before it publishes the matching ``SessionEvent/textDelta(_:)``
        // — see ``RoutedSessionActor``'s streaming body — so a
        // ``SessionEvent/generationStalled(_:)`` seen *after* every `.textDelta`
        // was measured against every fragment the answer produced. A report the
        // session made while a chunk was still unread counts fewer, honestly, and
        // is a different report; a stalled generation reports again on each
        // further interval, so the one this test is about always follows.
        var countedFragments = 0
        var stall: GenerationStall?
        let stream = await session.streamEvents(to: Self.prompt)
        for try await event in stream {
            switch event {
            case .textDelta:
                countedFragments += 1
            case .generationStalled(let reported)
            where stall == nil && countedFragments == producedFragments:
                stall = reported
                // Only now may the model call end: the report this test is about
                // has been made, and it is a report about a call still in flight.
                backend.release.signal()
            default:
                continue
            }
        }

        #expect(countedFragments == producedFragments)
        let reported = try #require(stall)
        #expect(reported.visibility == .fragments(observed: producedFragments))
    }

    // MARK: - A healthy answer reports nothing

    @Test("an answer that finishes reports no stall")
    @MainActor
    func anAnswerThatFinishesReportsNoStall() async throws {
        let (session, backend, dir) = try await Self.makeStallingSession(
            reportInterval: Self.unreachableReportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await SessionEventLog.watch(session)
        // Released up front, so the backend never suspends and the answer runs
        // straight through.
        backend.release.signal()
        _ = try await session.respond(to: Self.prompt)
        drain.cancel()

        #expect(await log.stalls.isEmpty)
    }

    // MARK: - Off until the host installs an interval (task ^m8pcyck)

    @Test(
        "a session with no interval installed reports nothing after five seconds of silence",
        .timeLimit(.minutes(1)))
    @MainActor
    func aSessionWithNoIntervalReportsNothing() async throws {
        let silence: Duration = .seconds(5)
        let (session, backend, dir) = try await Self.makeStallingSession(reportInterval: nil)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await SessionEventLog.watch(session)
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await BoundedWait.awaitSignal(backend.suspended, named: "the model call suspended")
        try await Task.sleep(for: silence)
        let stallsDuringSilence = await log.stalls

        backend.release.signal()
        _ = try await answerTask.value
        drain.cancel()

        #expect(await session.installedGenerationStallReportInterval == .zero)
        #expect(stallsDuringSilence.isEmpty)
    }

    @Test(
        "a session with a one-second interval reports a stall after one second",
        .timeLimit(.minutes(1)))
    @MainActor
    func aOneSecondIntervalReportsAfterOneSecond() async throws {
        let reportInterval: Duration = .seconds(1)
        let (session, backend, dir) = try await Self.makeStallingSession(reportInterval: reportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await SessionEventLog.watch(session)
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await BoundedWait.awaitSignal(backend.suspended, named: "the model call suspended")
        let reported = await BoundedWait.conditionReached("a stall report") { await !log.stalls.isEmpty }

        backend.release.signal()
        _ = try await answerTask.value
        drain.cancel()

        #expect(reported)
        let stall = try #require(await log.stalls.first)
        #expect(stall.timeWithoutProgress >= reportInterval)
    }

    @Test("a fork starts with the stall report interval of its parent")
    @MainActor
    func aForkStartsWithTheIntervalOfItsParent() async throws {
        let reportInterval: Duration = .seconds(1)
        let (session, dir) = try await Self.makeSession(
            over: StallingLLMContainer(fragmentsBeforeStall: 0), reportInterval: reportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }

        let child = try await session.fork(workingDirectory: nil)

        #expect(await child.installedGenerationStallReportInterval == reportInterval)
    }

    // MARK: - The log a consumer with no subscription still sees

    @Test("a stall is logged, so a consumer that subscribed to nothing still sees it")
    @MainActor
    func aStallIsLogged() async throws {
        let start = Date()
        let (session, backend, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await SessionEventLog.watch(session)
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await BoundedWait.awaitSignal(backend.suspended, named: "the model call suspended")
        _ = await BoundedWait.conditionReached("a stall report") { await !log.stalls.isEmpty }

        backend.release.signal()
        _ = try await answerTask.value
        drain.cancel()

        try assertLogged(containing: "generation has made no progress", since: start)
    }

    // MARK: - Tool calls and snapshots are progress (task ^4799jxg)

    @Test(
        "an answer that makes tool calls with no text for longer than the interval reports no stall",
        .timeLimit(.minutes(1)))
    @MainActor
    func toolCallsWithNoTextReportNoStall() async throws {
        // The appends are close together and the interval is far wider than
        // one pause, but the whole run of appends outlasts the interval. A
        // watchdog that timed only text fragments reports a stall here.
        let reportInterval: Duration = .milliseconds(400)
        let pause: Duration = .milliseconds(20)
        let appendCount = 40
        let appends = (0..<appendCount).map { $0.isMultiple(of: 2) ? GenerationProgressKind.toolCall : .toolResult }
        let backend = ToolAnswerBackend(appends: appends, pause: pause, holdsAfterLastAppend: false)
        let (session, dir) = try await Self.makeSession(
            over: ToolAnswerLLMContainer(backend: backend), reportInterval: reportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }

        let start = ContinuousClock.now
        var stalls: [GenerationStall] = []
        var text = ""
        for try await event in await session.streamEvents(to: Self.prompt) {
            switch event {
            case .generationStalled(let stall):
                stalls.append(stall)
            case .textDelta(let delta):
                text += delta
            default:
                continue
            }
        }

        #expect(start.duration(to: .now) > reportInterval)
        #expect(stalls.isEmpty)
        #expect(text == ToolAnswerBackend.answer)
    }

    @Test(
        "an answer that stops after a tool result reports a stall that names the tool result",
        .timeLimit(.minutes(1)))
    @MainActor
    func anAnswerThatStopsAfterAToolResultNamesIt() async throws {
        let backend = ToolAnswerBackend(
            appends: [.toolCall, .toolResult], pause: .zero, holdsAfterLastAppend: true)
        let (session, dir) = try await Self.makeSession(
            over: ToolAnswerLLMContainer(backend: backend), reportInterval: Self.testReportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A report made before the tool result reached the watch names an
        // earlier append. The report this test is about names the tool result,
        // and a stalled generation reports again on each interval, so it follows.
        var stall: GenerationStall?
        for try await event in await session.streamEvents(to: Self.prompt) {
            guard case .generationStalled(let reported) = event,
                stall == nil, reported.lastProgress == .toolResult
            else { continue }
            stall = reported
            backend.release.signal()
        }

        let reported = try #require(stall)
        #expect(reported.visibility == .fragments(observed: 0))
        #expect(reported.description.contains("since the last tool result"))
    }

    @Test(
        "a respond answer measures its stall from the last tool invocation record",
        .timeLimit(.minutes(1)))
    @MainActor
    func aRespondAnswerMeasuresFromTheLastToolInvocation() async throws {
        let (session, backend, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        let actor = try #require(session as? RoutedSessionActor)

        let (log, drain) = await SessionEventLog.watch(session)
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await BoundedWait.awaitSignal(backend.suspended, named: "the model call suspended")

        let open = ToolInvocationRecord(
            tool: "search", op: "search", correlationID: "tool-run", sessionID: session.id, openedAt: Date())
        await actor.deliver(invocation: open)
        await actor.deliver(invocation: open.closed(at: Date()))

        let reported = await BoundedWait.conditionReached("a stall report that names the tool result") {
            await log.stalls.contains { $0.lastProgress == .toolResult }
        }
        backend.release.signal()
        _ = try await answerTask.value
        drain.cancel()

        #expect(reported)
        let stall = try #require(await log.stalls.first { $0.lastProgress == .toolResult })
        #expect(stall.visibility == .wholeAnswer)
        #expect(stall.timeInFlight > stall.timeWithoutProgress)
    }

    @Test("a stall report names the kind of its last append")
    func aStallReportNamesItsLastAppend() {
        let stall = GenerationStall(
            timeWithoutProgress: .seconds(45), timeInFlight: .seconds(90),
            visibility: .fragments(observed: 3), lastProgress: .toolResult)
        #expect(
            stall.description
                == "generation has made no progress for 45.0s since the last tool result (3 fragments so far, 90.0s in flight)"
        )
    }
}
