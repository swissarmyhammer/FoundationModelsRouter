import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization
import TelemetryTestSupport
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
///
/// The router of each test gives a `ManualRunClock` to the run plane of each
/// session, and the stall watch runs on that clock. A test that checks a
/// report waits until the call holds and the watch sleeps, advances the clock
/// past the interval, and then reads the report. A test that checks that no
/// report comes does not advance the clock. No test waits for a time.
@Suite("Generation stall diagnostic")
struct GenerationStallDiagnosticTests {
    // MARK: - Stalling backend

    /// A ``LanguageModelSessionBackend`` that produces `fragmentsBeforeStall`
    /// stream chunks and then suspends until a test releases it — a decode that
    /// stops making progress while the model call is still in flight.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time, and the event and
    /// the semaphore are themselves `Sendable`.
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
        let suspended = AwaitedEvent()

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

        func cachedInputTokenCount() -> Int? {
            inner.cachedInputTokenCount()
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

    /// The two steps of one element of the stream of a ``ToolAnswerBackend``:
    /// the backend reports that the session asks for the next element, and
    /// then waits until the test lets it give that element.
    ///
    /// The session asks for the next element only after it noted the element
    /// before it. So when ``asked`` gives a permit, the test reads the state
    /// of the watch after that note, at a point of a fixed order.
    private final class AppendHandshake: Sendable {
        /// Gets one permit each time the session asks for the next element.
        let asked = AsyncSemaphore(value: 0)

        /// Gives one permit each time the test lets the backend give the
        /// next element.
        let proceed = AsyncSemaphore(value: 0)

        /// Reports the request of the session, and waits until the test lets
        /// the backend go on.
        func pass() async {
            asked.signal()
            await proceed.wait()
        }
    }

    /// The position of the next element in the stream of one call of a
    /// ``ToolAnswerBackend``.
    private final class StreamCursor: Sendable {
        /// The position, under a lock.
        private let position = Mutex(0)

        /// Takes the position of the next element, and moves past it.
        ///
        /// - Returns: The position of the element.
        func take() -> Int {
            position.withLock { position in
                defer { position += 1 }
                return position
            }
        }
    }

    /// A ``LanguageModelSessionBackend`` whose stream reports appends with no
    /// text, as the snapshots of a tool-using submission do: each append is a
    /// fragment with empty text and a ``GenerationProgressKind`` such as
    /// ``GenerationProgressKind/toolCall``. After the last append the stream
    /// either writes one line of text and finishes, or suspends until a test
    /// releases it.
    ///
    /// The stream makes each element only when the session asks for it. With
    /// a ``AppendHandshake``, the stream also waits for the test before each
    /// append and before the element after the last append.
    ///
    /// Plain `Sendable`: every stored property is a `let` of a `Sendable` type.
    private final class ToolAnswerBackend: LanguageModelSessionBackend, Sendable {
        /// The plain stub every behaviour other than the stream delegates to.
        private let inner = StubSessionBackend()

        /// The appends the stream reports, in order.
        let appends: [GenerationProgressKind]

        /// Whether the stream suspends on ``release`` after its last append.
        let holdsAfterLastAppend: Bool

        /// The steps the stream waits for before each element, or `nil` for
        /// a stream that waits for no step.
        let handshake: AppendHandshake?

        /// Awaited after the last append when ``holdsAfterLastAppend`` is set.
        let release = AsyncSemaphore(value: 0)

        /// The text the stream writes after its last append, when it does not hold.
        static let answer = "tool answer text"

        /// Creates a tool-using backend.
        ///
        /// - Parameters:
        ///   - appends: The appends the stream reports, in order.
        ///   - holdsAfterLastAppend: Whether the stream suspends after its last append.
        ///   - handshake: The steps the stream waits for before each element,
        ///     or `nil` (the default) for none.
        init(appends: [GenerationProgressKind], holdsAfterLastAppend: Bool, handshake: AppendHandshake? = nil) {
            self.appends = appends
            self.holdsAfterLastAppend = holdsAfterLastAppend
            self.handshake = handshake
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
            let cursor = StreamCursor()
            return AsyncThrowingStream(unfolding: { [self] in
                await element(at: cursor.take())
            })
        }

        /// The element at `position` of the stream: an append, then the text
        /// or the hold after the last append, then the end.
        ///
        /// - Parameter position: The position of the element.
        /// - Returns: The element, or `nil` at the end of the stream.
        private func element(at position: Int) async -> ResponseFragment? {
            guard position <= appends.count else { return nil }
            await handshake?.pass()
            if position < appends.count {
                return ResponseFragment(text: "", progress: appends[position])
            }
            if holdsAfterLastAppend {
                await release.wait()
                return nil
            }
            return ResponseFragment(text: Self.answer)
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

        func cachedInputTokenCount() -> Int? {
            inner.cachedInputTokenCount()
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

    /// The reporting interval every stalling test installs. The clock of the
    /// session moves only when the test advances it, so the value is only the
    /// distance that the test advances.
    private static let testReportInterval: Duration = .milliseconds(50)

    /// How far the test of a tool invocation advances the clock before the
    /// invocation. It is shorter than ``testReportInterval``, so no tick
    /// comes before the invocation.
    private static let timeBeforeToolInvocation: Duration = .milliseconds(25)

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
    /// - Returns: The session, its backend, the clock of its run plane, and
    ///   the temp directory to remove.
    /// - Throws: What ``makeSession(over:reportInterval:)`` throws, or when
    ///   the container vended no backend. Before it throws, it removes the
    ///   temp directory.
    private static func makeStallingSession(
        fragmentsBeforeStall: Int = 0,
        reportInterval: Duration? = testReportInterval
    ) async throws -> (session: any RoutedSession, backend: StallingBackend, clock: ManualRunClock, dir: URL) {
        let container = StallingLLMContainer(fragmentsBeforeStall: fragmentsBeforeStall)
        let (session, clock, dir) = try await makeSession(over: container, reportInterval: reportInterval)
        let backend = try await RouterTestFixtures.removingDirectoryOnThrow(
            dir, alsoOnThrow: { await session.close() }
        ) {
            try #require(container.lastBackend)
        }
        return (session, backend, clock, dir)
    }

    /// Builds a fresh router, resolved profile, and vended session over
    /// `container`, with `reportInterval` installed when it is not `nil`. The
    /// router gives a new `ManualRunClock` to the run plane of the session.
    ///
    /// - Parameters:
    ///   - container: The container the router loads.
    ///   - reportInterval: The stall reporting interval to install on the
    ///     vended session, or `nil` to install none.
    /// - Returns: The session, the clock of its run plane, and the temp
    ///   directory to remove.
    /// - Throws: What the resolve of the profile throws. Before it throws, it
    ///   removes the temp directory.
    private static func makeSession(
        over container: some LoadedLLMContainer,
        reportInterval: Duration?
    ) async throws -> (session: any RoutedSession, clock: ManualRunClock, dir: URL) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let clock = ManualRunClock()
        await router.useRunClock(clock)
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(dir) {
            try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        }
        let session = profile.standard.makeSession()
        if let reportInterval {
            await session.setGenerationStallReportInterval(reportInterval)
        }
        return (session, clock, dir)
    }

    /// Opens each hold of the stream of `backend`, and then closes `session`.
    ///
    /// A test calls it from a `defer`, so the session closes also when the
    /// test throws (rule T1). No hold ends on a cancel
    /// (``AsyncSemaphore/wait()``), and a close waits for the end of the
    /// stream, so the holds open first. One stream asks for at most one step
    /// more than its appends, so that count of steps opens each step that can
    /// wait. A permit that no wait takes does nothing.
    ///
    /// - Parameters:
    ///   - session: The session to close.
    ///   - backend: The backend whose holds to open.
    private static func close(_ session: any RoutedSession, openingHoldsOf backend: ToolAnswerBackend) async {
        if let handshake = backend.handshake {
            for _ in 0...backend.appends.count {
                handshake.proceed.signal()
            }
        }
        backend.release.signal()
        await session.close()
    }

    /// The count of the waits on ``StallingBackend/release`` in one answer:
    /// the one model call of the answer waits one time.
    private static let releaseWaitsPerAnswer = 1

    /// Releases the held model call of `backend`, and then closes `session`.
    ///
    /// A test calls it from a `defer`, so the session closes also when the
    /// test throws (rule T1). The hold does not end on a cancel
    /// (``AsyncSemaphore/wait()``), and a close waits for the end of the
    /// model call, so the release comes first. A test that released the call
    /// already leaves a permit that no wait takes, which does nothing.
    ///
    /// - Parameters:
    ///   - session: The session to close.
    ///   - backend: The backend whose model call to release.
    private static func close(_ session: any RoutedSession, releasing backend: StallingBackend) async {
        await SessionFixtureLifecycle.close(
            [session], releasing: [backend.release], permits: releaseWaitsPerAnswer)
    }

    /// Moves `clock` by `interval` once the model call holds and its watch
    /// sleeps, so the next tick of the watch comes at a point of a fixed
    /// order.
    ///
    /// - Parameters:
    ///   - clock: The clock of the session.
    ///   - held: The event the backend signals when the model call holds.
    ///   - interval: How far to move the clock. The default is
    ///     ``testReportInterval``.
    ///   - answer: The task of the answer that makes the model call and
    ///     starts the watch. Its end is the failure event of the wait for
    ///     `held` and of the wait for the watch on the clock.
    /// - Throws: ``ConditionNeverHeld`` when the test task was cancelled
    ///   first, or the error of `#require` when the answer ended before the
    ///   model call held or before the watch slept.
    private static func advance(
        _ clock: ManualRunClock, onceHeld held: AwaitedEvent, by interval: Duration = testReportInterval,
        endingOnEndOf answer: Task<String, any Error>
    ) async throws {
        try await RecordedWaitResult.wait(for: held, endingOnEndOf: answer)
        try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: answer)
        clock.advance(by: interval)
    }

    /// The first stall report on `feed`.
    ///
    /// Each element of the feed is an event that the session sends, so the
    /// wait ends on the report itself and has no wall clock (task ^v4zh807).
    /// The iteration ends at the first report, or when the feed ends, and the
    /// result is then `nil`.
    ///
    /// - Parameter feed: The session-wide feed, subscribed before the answer
    ///   starts.
    /// - Returns: The first report, or `nil` when the feed ended first.
    private static func firstStall(on feed: AsyncStream<SessionEvent>) async -> GenerationStall? {
        for await event in feed {
            guard case .generationStalled(let stall) = event else { continue }
            return stall
        }
        return nil
    }

    // MARK: - The signal a `respond` caller can see

    @Test(
        "a respond answer that stops progressing reports a stall on the session-wide feed")
    @MainActor
    func respondAnswerReportsAStallOnTheSessionWideFeed() async throws {
        let (session, backend, clock, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, releasing: backend) }

        let feed = await session.streamSessionEvents().events
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await Self.advance(clock, onceHeld: backend.suspended, endingOnEndOf: answerTask)
        let reported = await Self.firstStall(on: feed)
        backend.release.signal()
        _ = try await answerTask.value

        let stall = try #require(reported)
        // The honest half: a `respond` answer's backend hands back one whole
        // string, so there is no increment to time and the report says so.
        #expect(stall.visibility == .wholeAnswer)
        // The call made no progress from its start, and the clock moved one
        // interval after the start.
        #expect(stall.timeWithoutProgress == Self.testReportInterval)
        #expect(stall.timeInFlight == Self.testReportInterval)
    }

    @Test("a stalling answer is still given — the report bounds nothing")
    @MainActor
    func aStallingAnswerIsStillGiven() async throws {
        let (session, backend, clock, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, releasing: backend) }

        let feed = await session.streamSessionEvents().events
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await Self.advance(clock, onceHeld: backend.suspended, endingOnEndOf: answerTask)
        #expect(await Self.firstStall(on: feed) != nil)

        backend.release.signal()
        let answer = try await answerTask.value

        #expect(answer == "stub response")
    }

    // MARK: - The signal a streaming caller can see

    @Test(
        "a streaming answer reports the stall against the fragments it counted")
    @MainActor
    func streamingAnswerReportsTheStallAgainstCountedFragments() async throws {
        let producedFragments = 2
        let (session, backend, clock, dir) = try await Self.makeStallingSession(
            fragmentsBeforeStall: producedFragments)
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, releasing: backend) }

        // Read the answer's own stream here, rather than drain it into a log
        // this test then polls: each element is a suspension the answer itself
        // resumes, so a loaded machine makes this test slower and never red.
        //
        // The session counts a fragment before it publishes the matching
        // ``SessionEvent/textDelta(_:)`` — see ``RoutedSessionActor``'s
        // streaming body. So after the last `.textDelta` the watch counted
        // every fragment the answer produced, and only then does the test move
        // the clock. The one report of the watch comes after that point.
        //
        // The test reads the stream of the answer itself, so a second task
        // reads the end of the answer from the session-wide feed. That end is
        // the failure event of the wait for the watch on the clock.
        let feed = await session.streamSessionEvents().events
        let answerEnded = Task {
            for await event in feed where event.isAnswerEnd { return }
        }
        defer { answerEnded.cancel() }
        var countedFragments = 0
        var stall: GenerationStall?
        let stream = await session.streamEvents(to: Self.prompt)
        for try await event in stream {
            switch event {
            case .textDelta:
                countedFragments += 1
                if countedFragments == producedFragments {
                    try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: answerEnded)
                    clock.advance(by: Self.testReportInterval)
                }
            case .generationStalled(let reported) where stall == nil:
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
        // The test never advances the clock, so the watch never ticks: an
        // answer that finishes is proved to report nothing, and not to have
        // outrun a short clock.
        let (session, backend, _, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, releasing: backend) }

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
        "a session with no interval installed reports nothing after five seconds of silence")
    @MainActor
    func aSessionWithNoIntervalReportsNothing() async throws {
        let (session, backend, _, dir) = try await Self.makeStallingSession(reportInterval: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, releasing: backend) }

        let (log, drain) = await SessionEventLog.watch(session)
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await RecordedWaitResult.wait(for: backend.suspended, endingOnEndOf: answerTask)
        // With no interval, the watch of the call starts no timer. The test
        // does not wait for a time: it reads the installed interval, and then
        // the feed up to the end of the answer.
        #expect(await session.installedGenerationStallReportInterval == .zero)

        backend.release.signal()
        _ = try await answerTask.value
        // The feed gives each stall report of the answer before the end of
        // the answer. So when the end is on the feed, each report of the
        // silence is on the feed too.
        try await log.wait(until: { $0.contains(where: \.isAnswerEnd) })
        drain.cancel()

        #expect(await log.stalls.isEmpty)
    }

    @Test(
        "a session with a one-second interval reports a stall after one second")
    @MainActor
    func aOneSecondIntervalReportsAfterOneSecond() async throws {
        let reportInterval: Duration = .seconds(1)
        let (session, backend, clock, dir) = try await Self.makeStallingSession(reportInterval: reportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, releasing: backend) }

        let feed = await session.streamSessionEvents().events
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        try await Self.advance(clock, onceHeld: backend.suspended, by: reportInterval, endingOnEndOf: answerTask)
        let reported = await Self.firstStall(on: feed)

        backend.release.signal()
        _ = try await answerTask.value

        let stall = try #require(reported)
        #expect(stall.timeWithoutProgress == reportInterval)
    }

    @Test("a fork starts with the stall report interval of its parent")
    @MainActor
    func aForkStartsWithTheIntervalOfItsParent() async throws {
        let reportInterval: Duration = .seconds(1)
        let (session, _, dir) = try await Self.makeSession(
            over: StallingLLMContainer(fragmentsBeforeStall: 0), reportInterval: reportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await session.close() }

        let child = try await session.fork(workingDirectory: nil)
        defer { await child.close() }

        #expect(await child.installedGenerationStallReportInterval == reportInterval)
    }

    // MARK: - The log a consumer with no subscription still sees

    @Test("a stall is logged, so a consumer that subscribed to nothing still sees it")
    @MainActor
    func aStallIsLogged() async throws {
        let (session, backend, clock, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, releasing: backend) }

        let logs = try await TelemetryCapture.run(forbidding: []) { context in
            await session.useCaptureLogger(for: context.logger)
            let feed = await session.streamSessionEvents().events
            let answerTask = Task { try await session.respond(to: Self.prompt) }
            try await Self.advance(clock, onceHeld: backend.suspended, endingOnEndOf: answerTask)
            #expect(await Self.firstStall(on: feed) != nil)

            backend.release.signal()
            _ = try await answerTask.value
            return context
        }

        logs.expectLogged(
            containing: "generation stall",
            metadata: [RouterTelemetry.LogMetadataKey.generationStall: "generation has made no progress"])
    }

    // MARK: - Tool calls and snapshots are progress (task ^4799jxg)

    @Test(
        "an answer that makes tool calls with no text for longer than the interval reports no stall")
    @MainActor
    func toolCallsWithNoTextReportNoStall() async throws {
        // A watchdog that timed only text fragments measures the whole run of
        // appends from the start of the call. The watch of the session must
        // measure from the last append. The test reads the watch after each
        // append, so it needs no clock: a report measures from the instant
        // that the watch reads here. The test never advances the clock, so
        // the watch never ticks.
        let appendCount = 40
        let appends = (0..<appendCount).map { $0.isMultiple(of: 2) ? GenerationProgressKind.toolCall : .toolResult }
        let handshake = AppendHandshake()
        let backend = ToolAnswerBackend(appends: appends, holdsAfterLastAppend: false, handshake: handshake)
        let (session, _, dir) = try await Self.makeSession(
            over: ToolAnswerLLMContainer(backend: backend), reportInterval: Self.testReportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, openingHoldsOf: backend) }
        let actor = try #require(session as? RoutedSessionActor)

        let (log, drain) = SessionEventLog.collect(await session.streamEvents(to: Self.prompt))
        var watches: [GenerationStallWatch] = []
        for position in 0...appendCount {
            // The drain of the stream ends when the answer ends, so the wait
            // also ends on that end (rule T1).
            try await RecordedWaitResult.wait(forPermitOf: handshake.asked, endingOnEndOf: drain)
            // The session asks for this element only after it noted the
            // append before it.
            if position > 0 {
                watches.append(try #require(await actor.appliedStallWatch()))
            }
            handshake.proceed.signal()
        }
        try await drain.value

        let events = await log.events
        let text = events.compactMap { event -> String? in
            guard case .textDelta(let delta) = event else { return nil }
            return delta
        }.joined()
        #expect(watches.map(\.lastProgressKind) == appends)
        #expect(watches.allSatisfy { $0.measuredFrom == $0.lastProgressAt })
        #expect(watches.allSatisfy { $0.fragmentsObserved == 0 })
        #expect(await log.stalls.isEmpty)
        #expect(text == ToolAnswerBackend.answer)
    }

    @Test(
        "an answer that stops after a tool result reports a stall that names the tool result")
    @MainActor
    func anAnswerThatStopsAfterAToolResultNamesIt() async throws {
        let appends: [GenerationProgressKind] = [.toolCall, .toolResult]
        let handshake = AppendHandshake()
        let backend = ToolAnswerBackend(appends: appends, holdsAfterLastAppend: true, handshake: handshake)
        let (session, clock, dir) = try await Self.makeSession(
            over: ToolAnswerLLMContainer(backend: backend), reportInterval: Self.testReportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, openingHoldsOf: backend) }

        let (log, drain) = SessionEventLog.collect(await session.streamEvents(to: Self.prompt))
        // The drain of the stream ends when the answer ends, so each wait for
        // a request also ends on that end (rule T1).
        for _ in appends {
            try await RecordedWaitResult.wait(forPermitOf: handshake.asked, endingOnEndOf: drain)
            handshake.proceed.signal()
        }
        // The session asks for the element after the last append only after
        // it noted the tool result. Only then does the clock move. An answer
        // that ends with no watch on the clock ends the wait too.
        try await RecordedWaitResult.wait(forPermitOf: handshake.asked, endingOnEndOf: drain)
        try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: drain)
        clock.advance(by: Self.testReportInterval)
        try await log.wait(until: { events in
            events.contains { event in
                guard case .generationStalled = event else { return false }
                return true
            }
        })
        handshake.proceed.signal()
        backend.release.signal()
        try await drain.value

        let reported = try #require(await log.stalls.first)
        #expect(reported.lastProgress == .toolResult)
        #expect(reported.visibility == .fragments(observed: 0))
        #expect(reported.description.contains("since the last tool result"))
    }

    @Test(
        "a respond answer measures its stall from the last tool invocation record")
    @MainActor
    func aRespondAnswerMeasuresFromTheLastToolInvocation() async throws {
        let (session, backend, clock, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await Self.close(session, releasing: backend) }
        let actor = try #require(session as? RoutedSessionActor)

        let feed = await session.streamSessionEvents().events
        let answerTask = Task { try await session.respond(to: Self.prompt) }
        // The call holds for a while before its tool invocation. The clock
        // stays short of the interval, so no tick comes before the invocation.
        try await Self.advance(
            clock, onceHeld: backend.suspended, by: Self.timeBeforeToolInvocation, endingOnEndOf: answerTask)

        let open = ToolInvocationRecord(
            tool: "search", op: "search", correlationID: "tool-run", sessionID: session.id, openedAt: Date())
        await actor.deliver(invocation: open)
        await actor.deliver(invocation: open.closed(at: Date()))
        clock.advance(by: Self.testReportInterval)

        let reported = await Self.firstStall(on: feed)
        backend.release.signal()
        _ = try await answerTask.value

        let stall = try #require(reported)
        #expect(stall.lastProgress == .toolResult)
        #expect(stall.visibility == .wholeAnswer)
        // The time without progress starts at the tool result. The time in
        // flight starts at the start of the call, so it is longer by the time
        // before the invocation.
        #expect(stall.timeWithoutProgress == Self.testReportInterval)
        #expect(stall.timeInFlight == Self.timeBeforeToolInvocation + Self.testReportInterval)
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
