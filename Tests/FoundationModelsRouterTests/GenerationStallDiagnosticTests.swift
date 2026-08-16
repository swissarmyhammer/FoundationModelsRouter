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
/// reaches a caller on both routes — the turn's own
/// ``RoutedSession/streamEvents(to:maxTokens:)`` stream and the session-wide
/// ``RoutedSession/streamSessionEvents()`` feed a
/// ``RoutedSession/respond(to:maxTokens:)`` caller subscribes to. Second, the
/// report says honestly what the session could see: a streaming turn counts
/// real fragments, and a `respond` turn counts none, because the backend hands
/// it one whole string.
@Suite("Generation stall diagnostic")
struct GenerationStallDiagnosticTests {
    // MARK: - Stalling backend

    /// A ``LanguageModelSessionBackend`` that produces `fragmentsBeforeStall`
    /// stream chunks and then parks until a test releases it — a decode that
    /// stops making progress while the model call is still in flight.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time, and the two
    /// semaphores are themselves `Sendable`.
    private final class StallingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// The plain stub every non-stalling behaviour delegates to, so this
        /// backend only has to model the stall.
        private let inner = StubSessionBackend()

        /// Signalled once the model call has parked, so a test knows the stall
        /// has begun rather than guessing at it.
        let parked = AsyncSemaphore(value: 0)

        /// Awaited by the parked model call; signalling it lets the turn finish.
        let release = AsyncSemaphore(value: 0)

        /// How many stream chunks to produce before parking.
        let fragmentsBeforeStall: Int

        /// Creates a stalling backend.
        ///
        /// - Parameter fragmentsBeforeStall: How many stream chunks to produce
        ///   before the model call parks. Ignored on the non-streaming path,
        ///   which produces nothing at all.
        init(fragmentsBeforeStall: Int = 0) {
            self.fragmentsBeforeStall = fragmentsBeforeStall
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            parked.signal()
            await release.wait()
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            let fragmentsBeforeStall = fragmentsBeforeStall
            let parked = parked
            let release = release
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for index in 0..<fragmentsBeforeStall {
                        continuation.yield("chunk-\(index) ")
                    }
                    parked.signal()
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
        /// How many stream chunks each vended backend produces before parking.
        let fragmentsBeforeStall: Int

        /// The backend vended most recently — the one the session is driving.
        private(set) var lastBackend: StallingBackend?

        /// Creates a container.
        ///
        /// - Parameter fragmentsBeforeStall: How many stream chunks each vended
        ///   backend produces before parking.
        init(fragmentsBeforeStall: Int) {
            self.fragmentsBeforeStall = fragmentsBeforeStall
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StallingBackend(fragmentsBeforeStall: fragmentsBeforeStall)
            lastBackend = backend
            return backend
        }
    }

    // MARK: - Collector

    /// Collects the events a session-wide subscription delivered, so the test
    /// task can read them while the turn producing them is still in flight.
    private actor EventLog {
        /// Every event delivered so far, in delivery order.
        private(set) var events: [SessionEvent] = []

        /// Appends one delivered event.
        ///
        /// - Parameter event: The event just delivered.
        func append(_ event: SessionEvent) {
            events.append(event)
        }

        /// Every stall report delivered so far, in delivery order.
        var stalls: [GenerationStall] {
            events.compactMap { event in
                guard case .generationStalled(let stall) = event else { return nil }
                return stall
            }
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

    /// A reporting interval no test turn can reach — installed by the negative
    /// test, so a turn that finishes normally is proved to report nothing
    /// rather than merely to have outrun a short clock.
    private static let unreachableReportInterval: Duration = .seconds(600)

    /// The prompt every test turn sends.
    private static let prompt = "generate something"

    /// Builds a fresh router, resolved profile, and vended session over a
    /// ``StallingBackend``.
    ///
    /// - Parameters:
    ///   - fragmentsBeforeStall: How many stream chunks the backend produces
    ///     before parking.
    ///   - reportInterval: The stall reporting interval to install on the
    ///     vended session.
    /// - Returns: The session, its backend, and the temp directory to remove.
    private static func makeStallingSession(
        fragmentsBeforeStall: Int = 0,
        reportInterval: Duration = testReportInterval
    ) async throws -> (session: RoutedSession, backend: StallingBackend, dir: URL) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let container = StallingLLMContainer(fragmentsBeforeStall: fragmentsBeforeStall)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        await session.installGenerationStallReportInterval(reportInterval)
        let backend = try #require(container.lastBackend)
        return (session, backend, dir)
    }

    /// Subscribes to `session`'s session-wide feed and drains it into a log.
    ///
    /// - Parameter session: The session to watch.
    /// - Returns: The log, and the draining task to cancel once the test is
    ///   done reading it.
    private static func watchSessionEvents(
        on session: RoutedSession
    ) async -> (log: EventLog, drain: Task<Void, Never>) {
        let log = EventLog()
        let stream = await session.streamSessionEvents()
        let drain = Task {
            for await event in stream {
                await log.append(event)
            }
        }
        return (log, drain)
    }

    // MARK: - The signal a `respond` caller can see

    @Test("a respond turn that stops progressing reports a stall on the session-wide feed")
    @MainActor
    func respondTurnReportsAStallOnTheSessionWideFeed() async throws {
        let (session, backend, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await Self.watchSessionEvents(on: session)
        let turn = Task { try await session.respond(to: Self.prompt) }
        try await BoundedWait.awaitSignal(backend.parked, named: "the model call parked")

        let reported = await BoundedWait.conditionReached("a stall report") {
            await !log.stalls.isEmpty
        }
        backend.release.signal()
        _ = try await turn.value
        drain.cancel()

        #expect(reported)
        let stall = try #require(await log.stalls.first)
        // The honest half: a `respond` turn's backend hands back one whole
        // string, so there is no increment to time and the report says so.
        #expect(stall.visibility == .wholeAnswer)
        #expect(stall.timeWithoutProgress > .zero)
        #expect(stall.timeInFlight >= stall.timeWithoutProgress)
    }

    @Test("a stalling turn is still answered — the report bounds nothing")
    @MainActor
    func aStallingTurnIsStillAnswered() async throws {
        let (session, backend, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await Self.watchSessionEvents(on: session)
        let turn = Task { try await session.respond(to: Self.prompt) }
        try await BoundedWait.awaitSignal(backend.parked, named: "the model call parked")
        _ = await BoundedWait.conditionReached("a stall report") { await !log.stalls.isEmpty }

        backend.release.signal()
        let answer = try await turn.value
        drain.cancel()

        #expect(answer == "stub response")
    }

    // MARK: - The signal a streaming caller can see

    @Test("a streaming turn reports the stall against the fragments it counted")
    @MainActor
    func streamingTurnReportsTheStallAgainstCountedFragments() async throws {
        let producedFragments = 2
        let (session, backend, dir) = try await Self.makeStallingSession(
            fragmentsBeforeStall: producedFragments)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = EventLog()
        let stream = await session.streamEvents(to: Self.prompt)
        let drain = Task {
            for try await event in stream {
                await log.append(event)
            }
        }
        try await BoundedWait.awaitSignal(backend.parked, named: "the model call parked")

        let reported = await BoundedWait.conditionReached("a stall report") {
            await !log.stalls.isEmpty
        }
        backend.release.signal()
        _ = try? await drain.value

        #expect(reported)
        let stall = try #require(await log.stalls.first)
        #expect(stall.visibility == .fragments(observed: producedFragments))
    }

    // MARK: - A healthy turn reports nothing

    @Test("a turn that finishes reports no stall")
    @MainActor
    func aTurnThatFinishesReportsNoStall() async throws {
        let (session, backend, dir) = try await Self.makeStallingSession(
            reportInterval: Self.unreachableReportInterval)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await Self.watchSessionEvents(on: session)
        // Released up front, so the backend never parks and the turn runs
        // straight through.
        backend.release.signal()
        _ = try await session.respond(to: Self.prompt)
        drain.cancel()

        #expect(await log.stalls.isEmpty)
    }

    // MARK: - The log a consumer with no subscription still sees

    @Test("a stall is logged, so a consumer that subscribed to nothing still sees it")
    @MainActor
    func aStallIsLogged() async throws {
        let start = Date()
        let (session, backend, dir) = try await Self.makeStallingSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (log, drain) = await Self.watchSessionEvents(on: session)
        let turn = Task { try await session.respond(to: Self.prompt) }
        try await BoundedWait.awaitSignal(backend.parked, named: "the model call parked")
        _ = await BoundedWait.conditionReached("a stall report") { await !log.stalls.isEmpty }

        backend.release.signal()
        _ = try await turn.value
        drain.cancel()

        try assertLogged(containing: "generation has produced", since: start)
    }
}
