import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The arguments a discovery tool whose single string-valued property is named
/// `query` takes — the shape `MultiTool`'s own `findAPIs` has, and the one the
/// motivating consumer primes with.
@Generable
struct DiscoveryQueryArguments {
    /// The natural-language query the tool searches with.
    let query: String
}

/// The arguments a discovery tool whose single string-valued property is named
/// `topic` takes — deliberately *not* `query`, so a test can prove
/// ``DiscoveryPriming/queryProperty`` is honored rather than a hardcoded
/// property name.
@Generable
struct DiscoveryTopicArguments {
    /// The natural-language topic the tool searches with.
    let topic: String
}

/// A discovery tool that records every query it is called with and returns one
/// canned result — the "real call producing real output" a priming seed is
/// built from, with no live inference involved.
final class RecordingDiscoveryTool: Tool, Sendable {
    let name: String
    let description = "test-only discovery tool that records its queries and returns a canned result"

    /// The canned result every call returns.
    private let output: String

    /// Backing storage for ``queries``.
    private let recordedQueries = Mutex<[String]>([])

    /// Every query this tool has been called with, in call order — the proof
    /// that priming ran a genuine call rather than templating an output.
    var queries: [String] { recordedQueries.withLock { $0 } }

    /// Creates the fixture.
    ///
    /// - Parameters:
    ///   - name: The tool's mounted name.
    ///   - output: The canned result every call returns.
    init(name: String = "findAPIs", output: String) {
        self.name = name
        self.output = output
    }

    func call(arguments: DiscoveryQueryArguments) async throws -> String {
        recordedQueries.withLock { $0.append(arguments.query) }
        return output
    }
}

/// A discovery tool whose argument property is `topic` rather than `query`.
final class TopicDiscoveryTool: Tool, Sendable {
    let name = "findTopics"
    let description = "test-only discovery tool taking a differently-named string argument"

    /// Backing storage for ``topics``.
    private let recordedTopics = Mutex<[String]>([])

    /// Every topic this tool has been called with, in call order.
    var topics: [String] { recordedTopics.withLock { $0 } }

    func call(arguments: DiscoveryTopicArguments) async throws -> String {
        recordedTopics.withLock { $0.append(arguments.topic) }
        return "topics for \(arguments.topic)"
    }
}

/// A discovery tool that always fails — the fixture behind the "never block the
/// turn" path.
final class FailingDiscoveryTool: Tool, Sendable {
    /// The failure every call raises.
    enum Failure: Error, Equatable {
        /// The discovery backend was unreachable.
        case unreachable
    }

    let name = "findAPIs"
    let description = "test-only discovery tool that always fails"

    func call(arguments: DiscoveryQueryArguments) async throws -> String {
        throw Failure.unreachable
    }
}

/// A discovery tool whose `Output` is not `String`, so its result has no
/// recoverable text to seed a `.toolOutput` segment from.
final class NonTextDiscoveryTool: Tool, Sendable {
    let name = "findAPIs"
    let description = "test-only discovery tool whose output is not String"

    func call(arguments: DiscoveryQueryArguments) async throws -> NonStringToolOutput {
        NonStringToolOutput(text: "signatures for \(arguments.query)")
    }
}

/// Exercises pre-discovery seeding (`^s4405wc`): the opt-in that makes a turn's
/// first tool call deterministic by executing a mounted discovery tool
/// host-side and building the turn's transcript as
/// prompt → toolCalls → toolOutput before generation runs.
@Suite("Pre-discovery seeding via transcript construction")
struct DiscoveryPrimingTests {
    // MARK: - Observation

    /// The shared observation log a chain of ``PrimingObservingBackend``s
    /// writes into.
    ///
    /// One log outlives every backend in the chain, because
    /// `replacingTranscript(_:)` vends a *new* backend (as the protocol
    /// requires) and a test needs both the reseed it observed and the
    /// generation call the successor served.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time, serialized by its
    /// turn lock, and tests read the log only after the driving turn returned.
    private final class PrimingLog: @unchecked Sendable {
        /// Every entry list handed to `replacingTranscript(_:)`, in call order.
        private(set) var reseeds: [[Transcript.Entry]] = []

        /// The serving backend's own transcript as each generation call
        /// observed it, in call order — what the backend had *before*
        /// generation appended anything of its own.
        private(set) var entriesAtGeneration: [[Transcript.Entry]] = []

        /// Every prompt submitted to a generation entry point, in call order.
        private(set) var submittedPrompts: [String] = []

        /// Records one `replacingTranscript(_:)` reseed.
        ///
        /// - Parameter entries: The entries the new backend was seeded from.
        func noteReseed(_ entries: [Transcript.Entry]) {
            reseeds.append(entries)
        }

        /// Records one generation call's prompt and pre-generation transcript.
        ///
        /// - Parameters:
        ///   - prompt: The prompt submitted to the backend.
        ///   - entries: The backend's transcript before generation ran.
        func noteGeneration(prompt: String, entries: [Transcript.Entry]) {
            submittedPrompts.append(prompt)
            entriesAtGeneration.append(entries)
        }
    }

    /// A backend that records what the session hands it — the transcript each
    /// reseed carries and the transcript each generation call starts from —
    /// while delegating all real behavior to a ``StubSessionBackend``.
    private final class PrimingObservingBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// The shared log every backend in this chain writes into.
        private let log: PrimingLog

        /// The delegate that supplies real stub behavior.
        private let inner: StubSessionBackend

        /// Creates a backend over a shared log.
        ///
        /// - Parameters:
        ///   - log: The shared observation log.
        ///   - inner: The stub delegate. Defaults to a fresh, empty one.
        init(log: PrimingLog, inner: StubSessionBackend = StubSessionBackend()) {
            self.log = log
            self.inner = inner
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            log.noteGeneration(prompt: prompt, entries: inner.transcriptEntries())
            return try await inner.respond(to: prompt, maxTokens: maxTokens)
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            log.noteGeneration(prompt: prompt, entries: inner.transcriptEntries())
            return inner.streamResponse(to: prompt, maxTokens: maxTokens)
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            log.noteGeneration(prompt: prompt, entries: inner.transcriptEntries())
            return try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend {
            makeFork(tools: [])
        }

        func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
            PrimingObservingBackend(
                log: log,
                inner: StubSessionBackend(entries: inner.transcriptEntries())
            )
        }

        func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
            let entries = Array(transcript)
            log.noteReseed(entries)
            return PrimingObservingBackend(log: log, inner: StubSessionBackend(entries: entries))
        }

        func transcriptEntries() -> [Transcript.Entry] {
            inner.transcriptEntries()
        }

        func usageTokenCounts() -> (input: Int, output: Int)? {
            inner.usageTokenCounts()
        }
    }

    /// Vends ``PrimingObservingBackend``s over one shared ``PrimingLog``.
    ///
    /// `@unchecked Sendable`: ``log`` is an immutable reference, and the log
    /// itself carries the concurrency invariant (see ``PrimingLog``).
    private final class PrimingObservingContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The shared log every vended backend writes into.
        let log = PrimingLog()

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            PrimingObservingBackend(log: log, inner: StubSessionBackend(instructions: instructions))
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            PrimingObservingBackend(log: log, inner: StubSessionBackend(entries: Array(transcript)))
        }
    }

    // MARK: - Fixtures

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "DiscoveryPrimingTests"

    /// The prompt every turn in this suite submits.
    private static let prompt = "what are today's exchange rates"

    /// The canned discovery result the recording fixture returns.
    private static let discoveryOutput = "func rates(base: String) -> [String: Double]"

    /// One vended session plus everything a test needs to inspect it.
    private struct Fixture {
        /// The vended session under test.
        let session: RoutedSession

        /// The shared observation log its backends write into.
        let log: PrimingLog

        /// The recorder its turns append to.
        let recorder: InMemoryRecorder

        /// The per-test temp directory to clean up.
        let dir: URL
    }

    /// Builds a fresh router + resolved profile + vended session over a
    /// ``PrimingObservingBackend``.
    ///
    /// - Parameters:
    ///   - tools: The tools to mount on the session.
    ///   - priming: The priming opt-in, or `nil` to leave it off.
    /// - Returns: The fixture.
    private static func makeFixture(
        tools: [any Tool] = [],
        priming: DiscoveryPriming? = nil
    ) async throws -> Fixture {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let container = PrimingObservingContainer()
        let recorder = InMemoryRecorder()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(tools: tools, discoveryPriming: priming)
        return Fixture(session: session, log: container.log, recorder: recorder, dir: dir)
    }

    /// Drains an event stream into an array.
    ///
    /// - Parameter stream: The stream to drain.
    /// - Returns: Every event it yielded, in order.
    private static func collect(
        _ stream: AsyncThrowingStream<SessionEvent, Error>
    ) async throws -> [SessionEvent] {
        var events: [SessionEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    /// The priming failures among `events`, in order.
    ///
    /// - Parameter events: The events to filter.
    /// - Returns: Each ``SessionEvent/discoveryPrimingFailed(_:)`` payload.
    private static func primingFailures(in events: [SessionEvent]) -> [DiscoveryPrimingFailure] {
        events.compactMap { event in
            guard case .discoveryPrimingFailed(let failure) = event else { return nil }
            return failure
        }
    }

    // MARK: - Tests

    @Test("priming on: the backend receives prompt -> toolCalls -> toolOutput, carrying the tool's real output, before generation")
    @MainActor
    func primingSeedsTheTurnBeforeGeneration() async throws {
        let tool = RecordingDiscoveryTool(output: Self.discoveryOutput)
        let fixture = try await Self.makeFixture(
            tools: [tool],
            priming: DiscoveryPriming(tool: "findAPIs", queryProperty: "query")
        )
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try await fixture.session.respond(to: Self.prompt)

        // The discovery call was real: the tool itself saw the turn's prompt as
        // its query, exactly once.
        #expect(tool.queries == [Self.prompt])

        // The seeded transcript is what the generating backend started from.
        let seeded = try #require(fixture.log.entriesAtGeneration.first)
        let mapped = seeded.map { TranscriptEntryMapper.event(from: $0) }
        #expect(mapped.map(\.kind) == [.prompt, .toolCalls, .toolOutput])
        #expect(mapped[0].text == Self.prompt)

        let call = try #require(mapped[1].payload.toolCalls?.first)
        #expect(call.toolName == "findAPIs")
        let arguments = try DiscoveryQueryArguments(GeneratedContent(json: call.argumentsJSON))
        #expect(arguments.query == Self.prompt)

        // The output is the tool's own, and its entry id correlates with the
        // call that produced it — the same pairing an SDK-native call has.
        #expect(mapped[2].payload.toolName == "findAPIs")
        #expect(mapped[2].text == Self.discoveryOutput)
        #expect(mapped[2].payload.entryId == call.id)

        // Seeding happened through the transcript, not by rewriting the turn's
        // own prompt.
        #expect(fixture.log.submittedPrompts == [Self.prompt])
    }

    @Test("priming off: no reseed happens and the turn's transcript construction is unchanged")
    @MainActor
    func primingOffLeavesConstructionUnchanged() async throws {
        let tool = RecordingDiscoveryTool(output: Self.discoveryOutput)
        let fixture = try await Self.makeFixture(tools: [tool])
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try await fixture.session.respond(to: Self.prompt)

        #expect(tool.queries.isEmpty)
        #expect(fixture.log.reseeds.isEmpty)
        #expect(fixture.log.entriesAtGeneration == [[]])
        #expect(fixture.log.submittedPrompts == [Self.prompt])

        let events = await fixture.recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
    }

    @Test("seeded entries round-trip through the recording sidecar with no special-casing")
    @MainActor
    func seededEntriesRoundTripThroughRecording() async throws {
        let tool = RecordingDiscoveryTool(output: Self.discoveryOutput)
        let fixture = try await Self.makeFixture(
            tools: [tool],
            priming: DiscoveryPriming(tool: "findAPIs", queryProperty: "query")
        )
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try await fixture.session.respond(to: Self.prompt)

        // The turn's ordinary positional diff picked the seeded entries up as
        // the genuinely new entries they are: the seeded triple, then the
        // turn's own prompt and response.
        let events = await fixture.recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .toolCalls, .toolOutput, .prompt, .response])

        let toolCallsEvent = try #require(events.first { $0.kind == .toolCalls })
        let recordedCall = try #require(toolCallsEvent.entry?.toolCalls?.first)
        #expect(recordedCall.toolName == "findAPIs")

        let toolOutputEvent = try #require(events.first { $0.kind == .toolOutput })
        #expect(toolOutputEvent.entry?.toolName == "findAPIs")
        #expect(toolOutputEvent.text == Self.discoveryOutput)

        // Every recorded seeded entry rebuilds into a real `Transcript.Entry`
        // through the ordinary mapper — no seeded-entry branch exists to take.
        for event in events where event.kind == .toolCalls || event.kind == .toolOutput {
            let payload = try #require(event.entry)
            _ = try TranscriptEntryMapper.entry(from: payload, kind: event.kind)
        }
    }

    @Test("a failing discovery call never blocks the turn: it generates unseeded and the failure lands on the event stream")
    @MainActor
    func failingDiscoveryGeneratesUnseededAndSurfacesTheFailure() async throws {
        let fixture = try await Self.makeFixture(
            tools: [FailingDiscoveryTool()],
            priming: DiscoveryPriming(tool: "findAPIs", queryProperty: "query")
        )
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let events = try await Self.collect(await fixture.session.streamEvents(to: Self.prompt))

        #expect(fixture.log.reseeds.isEmpty)
        #expect(fixture.log.entriesAtGeneration == [[]])
        #expect(events.contains(.textDelta(StubSessionBackend().responseText)))

        let failures = Self.primingFailures(in: events)
        #expect(failures.count == 1)
        guard case .callFailed(let tool, _) = failures.first else {
            Issue.record("expected a .callFailed priming failure, got \(String(describing: failures.first))")
            return
        }
        #expect(tool == "findAPIs")
    }

    @Test("naming a tool that is not mounted surfaces the failure and generates unseeded")
    @MainActor
    func unmountedToolSurfacesTheFailure() async throws {
        let fixture = try await Self.makeFixture(
            tools: [RecordingDiscoveryTool(output: Self.discoveryOutput)],
            priming: DiscoveryPriming(tool: "notMounted", queryProperty: "query")
        )
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let events = try await Self.collect(await fixture.session.streamEvents(to: Self.prompt))

        #expect(fixture.log.reseeds.isEmpty)
        #expect(Self.primingFailures(in: events) == [.toolNotMounted(tool: "notMounted")])
    }

    @Test("a discovery tool whose output is not text surfaces the failure and generates unseeded")
    @MainActor
    func nonTextOutputSurfacesTheFailure() async throws {
        let fixture = try await Self.makeFixture(
            tools: [NonTextDiscoveryTool()],
            priming: DiscoveryPriming(tool: "findAPIs", queryProperty: "query")
        )
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let events = try await Self.collect(await fixture.session.streamEvents(to: Self.prompt))

        #expect(fixture.log.reseeds.isEmpty)
        #expect(Self.primingFailures(in: events) == [.toolOutputNotText(tool: "findAPIs")])
    }

    @Test("the argument property is the option's, not a hardcoded one — a tool taking `topic` primes just as well")
    @MainActor
    func primingIsGenericOverTheArgumentProperty() async throws {
        let tool = TopicDiscoveryTool()
        let fixture = try await Self.makeFixture(
            tools: [tool],
            priming: DiscoveryPriming(tool: "findTopics", queryProperty: "topic")
        )
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try await fixture.session.respond(to: Self.prompt)

        #expect(tool.topics == [Self.prompt])
        let seeded = try #require(fixture.log.entriesAtGeneration.first)
        let mapped = seeded.map { TranscriptEntryMapper.event(from: $0) }
        #expect(mapped.map(\.kind) == [.prompt, .toolCalls, .toolOutput])
        let call = try #require(mapped[1].payload.toolCalls?.first)
        let arguments = try DiscoveryTopicArguments(GeneratedContent(json: call.argumentsJSON))
        #expect(arguments.topic == Self.prompt)
        #expect(mapped[2].text == "topics for \(Self.prompt)")
    }

    @Test("naming the configured property wrong surfaces an arguments failure and generates unseeded")
    @MainActor
    func mismatchedArgumentPropertySurfacesTheFailure() async throws {
        let fixture = try await Self.makeFixture(
            tools: [RecordingDiscoveryTool(output: Self.discoveryOutput)],
            priming: DiscoveryPriming(tool: "findAPIs", queryProperty: "topic")
        )
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let events = try await Self.collect(await fixture.session.streamEvents(to: Self.prompt))

        #expect(fixture.log.reseeds.isEmpty)
        let failures = Self.primingFailures(in: events)
        guard case .argumentsRejected(let tool, let property, _) = failures.first else {
            Issue.record("expected an .argumentsRejected failure, got \(String(describing: failures.first))")
            return
        }
        #expect(tool == "findAPIs")
        #expect(property == "topic")
    }

    @Test("every turn primes: a second turn seeds its own discovery pair onto the accumulated transcript")
    @MainActor
    func everyTurnPrimesOnTopOfTheAccumulatedTranscript() async throws {
        let tool = RecordingDiscoveryTool(output: Self.discoveryOutput)
        let fixture = try await Self.makeFixture(
            tools: [tool],
            priming: DiscoveryPriming(tool: "findAPIs", queryProperty: "query")
        )
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        _ = try await fixture.session.respond(to: "first")
        _ = try await fixture.session.respond(to: "second")

        #expect(tool.queries == ["first", "second"])
        #expect(fixture.log.reseeds.count == 2)

        // The second turn's seed sits on top of the first turn's whole history
        // — the three entries it seeded plus the prompt/response the SDK
        // appended — never in place of it.
        let secondSeed = try #require(fixture.log.entriesAtGeneration.last)
        let kinds = secondSeed.map { TranscriptEntryMapper.event(from: $0).kind }
        #expect(kinds == [.prompt, .toolCalls, .toolOutput, .prompt, .response, .prompt, .toolCalls, .toolOutput])
    }

    @Test("a fork inherits its parent's priming opt-in")
    @MainActor
    func forkInheritsPriming() async throws {
        let tool = RecordingDiscoveryTool(output: Self.discoveryOutput)
        let fixture = try await Self.makeFixture(
            tools: [tool],
            priming: DiscoveryPriming(tool: "findAPIs", queryProperty: "query")
        )
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let forked = try await fixture.session.fork(workingDirectory: nil)
        _ = try await forked.respond(to: Self.prompt)

        #expect(tool.queries == [Self.prompt])
        let seeded = try #require(fixture.log.entriesAtGeneration.first)
        #expect(seeded.map { TranscriptEntryMapper.event(from: $0).kind } == [.prompt, .toolCalls, .toolOutput])
    }
}
