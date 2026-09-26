import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^9bxas0w: the safety bound on a chain of answers that mail
/// alone starts (`generation-queue.md`, section 5.4).
///
/// Mail causes the next submission of a session with no caller call. A model
/// that starts one more background run in each submission thus gets one more
/// delivery for each run, with no end. The pump counts the answers in a row
/// that mail alone starts. At ``SessionConfiguration/mailOnlyAnswerLimit`` it
/// holds the mail in the outbox for the next caller message, and it sends
/// ``SessionEvent/mailDeliveryPaused(_:)``.
///
/// Everything runs against a scripted backend that calls a real background
/// tool of the session, so the suite needs no network and no GPU.
@Suite("The bound on a chain of answers that mail alone starts")
struct MailOnlyAnswerLimitTests {
    // MARK: - Backend

    /// A scripted model that starts one background run in each of its first
    /// calls, as a model does that asks a background status tool after each
    /// result.
    ///
    /// Each call that starts a run calls the first composed
    /// ``LatchedBackgroundToolRunner`` of the session. Its gate is open, so the
    /// run settles at once, and its terminal is mail that starts the next
    /// submission. The pump drives this backend with no caller call, so every
    /// mutable field is behind one `Mutex`.
    final class RunStartingBackend: LanguageModelSessionBackend {
        /// The backend that answers each call and records its prompt.
        private let inner = StubSessionBackend()

        /// The session's own composed tool list.
        private let tools: [any Tool]

        /// How many of the first calls start a run, or `nil` for every call.
        private let runStartingCalls: Int?

        /// The number of calls so far.
        private let callCount = Mutex(0)

        /// Makes a backend over `tools`.
        ///
        /// - Parameters:
        ///   - tools: The session's composed tool list.
        ///   - runStartingCalls: How many of the first calls start a run, or
        ///     `nil` for every call.
        init(tools: [any Tool], runStartingCalls: Int?) {
            self.tools = tools
            self.runStartingCalls = runStartingCalls
        }

        /// The prompt of each call so far, in call order.
        var prompts: [String] { inner.receivedPrompts }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            let ordinal = callCount.withLock { count in
                count += 1
                return count
            }
            if runStartingCalls.map({ ordinal <= $0 }) ?? true {
                try await startRun(prompt: prompt)
            }
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        /// Calls the first composed background tool, which starts one run.
        ///
        /// - Parameter prompt: The prompt of the call, which the tool receives
        ///   as its argument.
        /// - Throws: What the tool throws.
        private func startRun(prompt: String) async throws {
            let mounted = try #require(
                tools.lazy.compactMap {
                    ToolFailureDelivery.throwingTool(of: $0) as? BackgroundToolRunner<BackgroundFixtureArguments>
                }.first)
            _ = try await mounted.call(arguments: BackgroundFixtureArguments(value: prompt))
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            inner.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
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

    /// Vends one ``RunStartingBackend`` for the session a test makes, with the
    /// composed tool list of that session.
    ///
    /// `@unchecked Sendable` invariant: `lastBackend` is written one time,
    /// under its own lock, inside `makeSession(instructions:tools:)`, and a
    /// test reads it after the vend returns.
    final class RunStartingContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// How many of the first calls of each vended backend start a run, or
        /// `nil` for every call.
        private let runStartingCalls: Int?

        /// The backend the last vend made.
        private let vended = Mutex<RunStartingBackend?>(nil)

        /// Makes a container.
        ///
        /// - Parameter runStartingCalls: How many of the first calls of each
        ///   vended backend start a run, or `nil` for every call.
        init(runStartingCalls: Int?) {
            self.runStartingCalls = runStartingCalls
        }

        /// The backend the last vend made, or `nil` before a vend.
        var lastBackend: RunStartingBackend? { vended.withLock { $0 } }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeSession(instructions: instructions, tools: [])
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            let backend = RunStartingBackend(tools: tools, runStartingCalls: runStartingCalls)
            vended.withLock { $0 = backend }
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    /// One session over a ``RunStartingBackend``, with what a test reads.
    struct Fixture: Sendable {
        /// The session under test.
        let session: any RoutedSession

        /// The backend the session runs on.
        let backend: RunStartingBackend

        /// The feed of the session's events.
        let events: SessionEventLog

        /// The task that drains ``events``.
        let drain: Task<Void, Never>

        /// The router that keeps the models of the session resident.
        let router: Router

        /// The temporary directory the router caches under.
        let directory: URL
    }

    // MARK: - Constants

    /// The limit each test session has: small, so a test runs few submissions.
    private static let limit = 3

    /// The prompts of one chain: the caller answer, then `limit` answers that
    /// mail alone started.
    private static let promptsOfOneChain = limit + 1

    /// The prompt of the first caller message, which starts the chain.
    private static let firstPrompt = "start the status checks"

    /// The prompt of the caller message after the chain stopped.
    private static let nextPrompt = "what is the status now"

    /// The output of each background run.
    private static let runOutput = "the status check is done"

    // MARK: - Fixtures

    /// Makes a session with `limit`, over a backend that starts a run in each
    /// of its first `runStartingCalls` calls, and watches its events.
    ///
    /// - Parameters:
    ///   - limit: The ``SessionConfiguration/mailOnlyAnswerLimit`` of the session.
    ///   - runStartingCalls: How many of the first calls start a run, or `nil`
    ///     for every call.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(limit: Int = Self.limit, runStartingCalls: Int?) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "MailOnlyAnswerLimitTests")
        let container = RunStartingContainer(runStartingCalls: runStartingCalls)
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directory)
        let gate = RunLatch()
        await gate.open()
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(
                tools: [LatchedBackgroundToolRunner(name: "status_check", gate: gate, output: runOutput)],
                mailOnlyAnswerLimit: limit))
        let backend = try #require(container.lastBackend)
        let (events, drain) = await SessionEventLog.watch(session)
        return Fixture(
            session: session, backend: backend, events: events, drain: drain, router: router, directory: directory)
    }

    /// Waits, bounded, until the session sent `count` pause events.
    ///
    /// - Parameters:
    ///   - count: How many pause events to wait for.
    ///   - fixture: The fixture whose events are watched.
    /// - Returns: `true` when the events arrived inside the bound.
    private static func pausesArrive(_ count: Int, on fixture: Fixture) async -> Bool {
        await BoundedWait.conditionReached("\(count) mail delivery pauses on the session feed") {
            await fixture.events.mailDeliveryPauses.count == count
        }
    }

    /// Waits, bounded, until the pump of the session ends.
    ///
    /// - Parameter fixture: The fixture whose pump is watched.
    /// - Returns: `true` when the pump ended inside the bound.
    private static func pumpStops(on fixture: Fixture) async -> Bool {
        await BoundedWait.conditionReached("the pump of the session ending") {
            await fixture.session.isPumpRunning == false
        }
    }

    /// The mail that waits in the outbox of the session.
    ///
    /// - Parameter fixture: The fixture whose outbox is read.
    /// - Returns: The pending mail events, in outbox order.
    private static func waitingMail(of fixture: Fixture) async -> [SessionOutbox.PendingEvent] {
        await fixture.session.outbox.pending().events
    }

    /// Ends the fixture: stops the event drain and removes the directory.
    ///
    /// - Parameter fixture: The fixture to end.
    private static func tearDown(_ fixture: Fixture) {
        fixture.drain.cancel()
        try? FileManager.default.removeItem(at: fixture.directory)
        withExtendedLifetime(fixture.router) {}
    }

    // MARK: - The bound

    @Test("an endless chain of mail-only answers stops at the limit, and the session sends the pause event")
    func anEndlessChainStopsAtTheLimit() async throws {
        let fixture = try await Self.makeFixture(runStartingCalls: nil)
        defer { Self.tearDown(fixture) }

        _ = try await fixture.session.respond(to: Self.firstPrompt)

        // The caller answer, then `limit` answers that mail alone started.
        #expect(await Self.pausesArrive(1, on: fixture))
        #expect(await Self.pumpStops(on: fixture))
        #expect(fixture.backend.prompts.count == Self.promptsOfOneChain)
        // The mail of the last run waits, held: its progress report and its
        // terminal.
        let held = await Self.waitingMail(of: fixture)
        #expect(held.filter { $0.event.kind == .completed }.count == 1)
        #expect(held.allSatisfy { $0.isHeld })
        let pause = try #require(await fixture.events.mailDeliveryPauses.first)
        #expect(pause == MailDeliveryPause(limit: Self.limit, heldMail: held.map(\.event)))
    }

    @Test("the mail that the bound holds rides the next caller message")
    func theHeldMailRidesTheNextCallerMessage() async throws {
        // The last run starts in the last answer that mail started, so the
        // bound holds its mail, and the next caller answer starts no run.
        let fixture = try await Self.makeFixture(runStartingCalls: Self.promptsOfOneChain)
        defer { Self.tearDown(fixture) }
        _ = try await fixture.session.respond(to: Self.firstPrompt)
        #expect(await Self.pausesArrive(1, on: fixture))
        #expect(await Self.pumpStops(on: fixture))
        let held = try #require(await Self.waitingMail(of: fixture).first { $0.event.kind == .completed })

        _ = try await fixture.session.respond(to: Self.nextPrompt)

        let nextCallerPrompt = try #require(fixture.backend.prompts.dropFirst(Self.promptsOfOneChain).first)
        #expect(nextCallerPrompt.contains(OperationEventSegment.renderedLine(for: held.event)))
        #expect(nextCallerPrompt.hasSuffix(Self.nextPrompt))
        #expect(await Self.waitingMail(of: fixture).isEmpty)
    }

    @Test("a caller message starts the count again, so mail again starts answers up to the limit")
    func aCallerMessageStartsTheCountAgain() async throws {
        let fixture = try await Self.makeFixture(runStartingCalls: nil)
        defer { Self.tearDown(fixture) }
        _ = try await fixture.session.respond(to: Self.firstPrompt)
        #expect(await Self.pausesArrive(1, on: fixture))
        #expect(await Self.pumpStops(on: fixture))

        _ = try await fixture.session.respond(to: Self.nextPrompt)

        // The second chain pauses too: one pause for each chain.
        let pausesOfTwoChains = 2
        #expect(await Self.pausesArrive(pausesOfTwoChains, on: fixture))
        #expect(await Self.pumpStops(on: fixture))
        #expect(fixture.backend.prompts.count == Self.promptsOfOneChain + Self.promptsOfOneChain)
    }

    @Test("a chain of mail-only answers that reaches the limit, and no further, runs whole with no pause")
    func aChainUpToTheLimitRunsWhole() async throws {
        let fixture = try await Self.makeFixture(runStartingCalls: Self.limit)
        defer { Self.tearDown(fixture) }

        _ = try await fixture.session.respond(to: Self.firstPrompt)

        // Each of the first `limit` calls started a run, and the mail of each
        // run started one more answer.
        #expect(
            await BoundedWait.conditionReached("every settled run delivered in an answer of its own") {
                fixture.backend.prompts.count == Self.promptsOfOneChain
            })
        #expect(await Self.pumpStops(on: fixture))
        #expect(await Self.waitingMail(of: fixture).isEmpty)
        #expect(await fixture.events.mailDeliveryPauses.isEmpty)
        #expect(fixture.backend.prompts.dropFirst().allSatisfy { $0.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) })
    }

    @Test("a limit of zero holds all mail for the next caller message")
    func aLimitOfZeroHoldsAllMail() async throws {
        let fixture = try await Self.makeFixture(limit: 0, runStartingCalls: nil)
        defer { Self.tearDown(fixture) }

        _ = try await fixture.session.respond(to: Self.firstPrompt)

        #expect(await Self.pausesArrive(1, on: fixture))
        #expect(await Self.pumpStops(on: fixture))
        #expect(fixture.backend.prompts == [Self.firstPrompt])
        let held = await Self.waitingMail(of: fixture)
        #expect(!held.isEmpty)
        #expect(held.allSatisfy { $0.isHeld })
    }

    // MARK: - The setting

    @Test("a session configuration that names no limit carries the named default")
    func theConfigurationCarriesTheDefault() {
        #expect(SessionConfiguration().mailOnlyAnswerLimit == SessionConfiguration.defaultMailOnlyAnswerLimit)
    }

    @Test("the sidecar form of a configuration keeps the limit")
    func thePersistableFormKeepsTheLimit() throws {
        let persistable = SessionConfiguration(mailOnlyAnswerLimit: Self.limit).persistable
        let decoded = try JSONDecoder().decode(
            SessionConfiguration.Persistable.self, from: JSONEncoder().encode(persistable))
        #expect(decoded.mailOnlyAnswerLimit == Self.limit)
    }

    @Test("a sidecar written before the limit existed decodes with no limit, which a restore reads as the default")
    func anOldSidecarDecodesWithNoLimit() throws {
        let encoded = try JSONEncoder().encode(SessionConfiguration().persistable)
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "mailOnlyAnswerLimit")
        let decoded = try JSONDecoder().decode(
            SessionConfiguration.Persistable.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.mailOnlyAnswerLimit == nil)
    }
}

extension SessionEventLog {
    /// Every mail delivery pause delivered so far, in delivery order.
    var mailDeliveryPauses: [MailDeliveryPause] {
        events.compactMap { event in
            guard case .mailDeliveryPaused(let pause) = event else { return nil }
            return pause
        }
    }
}
