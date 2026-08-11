import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^n9tdq8c: one ``SessionConfiguration`` value drives
/// ``RoutedModel/makeSession(configuration:)``.
///
/// Everything runs against stubs — a plain stub ``LoadedLLMContainer`` over
/// ``StubSessionBackend`` — so the suite needs no network and no GPU. The
/// suite proves four facts: an empty configuration vends the same session the
/// zero-argument `makeSession()` vends, a fully configured value carries each
/// knob onto the vended session exactly as the nine-parameter call does, a
/// configuration with a grammar vends the guided session `makeGuidedSession`
/// vends, and the `Codable` slice round-trips with the tool names task
/// ^ne5g9jn persists.
@Suite("SessionConfiguration drives makeSession")
struct SessionConfigurationTests {
    // MARK: - Stub container

    /// Vends a plain ``StubSessionBackend`` for every session.
    private struct BasicLLMContainer: PlainTranscriptStubContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend()
        }
    }

    // MARK: - Fixtures

    /// A tiny JSON-schema grammar the xgrammar-subset validation accepts.
    private static let smallSchema = """
        {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
        """

    /// Builds a fresh router + resolved profile over the plain stub container.
    ///
    /// - Parameter dir: The per-test temp directory the router caches under.
    /// - Returns: The resolved profile, retained by the caller for the
    ///   session's whole lifetime.
    private static func makeProfile(cacheDir dir: URL) async throws -> LanguageModelProfile {
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(
                container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension)
        )
        return try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
    }

    // MARK: - The empty configuration is the zero-argument default

    @Test("makeSession(configuration:) with an empty configuration matches makeSession()")
    func emptyConfigurationMatchesZeroArgumentMakeSession() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionConfigurationTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = try await Self.makeProfile(cacheDir: dir)

        let configured = try #require(
            profile.standard.makeSession(configuration: SessionConfiguration())
                as? RoutedSessionActor)
        let reference = try #require(profile.standard.makeSession() as? RoutedSessionActor)

        #expect(configured.grammar == reference.grammar)
        #expect(configured.instructions == reference.instructions)
        #expect(configured.autoCompactionBudget == reference.autoCompactionBudget)
        #expect(configured.autoCompactionPrompt == reference.autoCompactionPrompt)
        #expect(configured.summarization == reference.summarization)
        #expect(configured.discoveryPriming == reference.discoveryPriming)
        #expect(configured.tools.isEmpty)
        #expect(configured.originalTools.isEmpty)
    }

    // MARK: - Every knob reaches the vended session

    @Test("a configured value carries each knob exactly as the nine-parameter call does")
    func configuredValueMatchesNineParameterCall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionConfigurationTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = try await Self.makeProfile(cacheDir: dir)

        let workingDirectory = dir.appendingPathComponent("work", isDirectory: true)
        let budget = TokenBudget(limit: 4096, trigger: 0.9, target: 0.6)
        let prompt = CompactionPrompt(name: "custom", text: "condense")
        let summarization = Summarization(
            keepRecentTurns: 2, maxChunkTokens: 500, summaryTokenRatio: 0.5)
        let priming = DiscoveryPriming(tool: "ambient-emitter", queryProperty: "value")
        let spawn = SessionSidecar.AgentSpawn(
            parentSessionId: ULID.generate(), parentToolCallId: "call-1")
        let tool = AmbientEventPostingTool()

        let configuration = SessionConfiguration(
            instructions: "system",
            workingDirectory: workingDirectory,
            tools: [tool],
            budget: budget,
            compactionPrompt: prompt,
            summarization: summarization,
            agentSpawn: spawn,
            discoveryPriming: priming
        )
        let configured = try #require(
            profile.standard.makeSession(configuration: configuration) as? RoutedSessionActor)
        let reference = try #require(
            profile.standard.makeSession(
                instructions: "system",
                workingDirectory: workingDirectory,
                tools: [tool],
                budget: budget,
                compactionPrompt: prompt,
                summarization: summarization,
                agentSpawn: spawn,
                discoveryPriming: priming
            ) as? RoutedSessionActor)

        #expect(configured.instructions == reference.instructions)
        #expect(configured.workingDirectory == reference.workingDirectory)
        #expect(configured.workingDirectory == workingDirectory)
        #expect(configured.autoCompactionBudget == budget)
        #expect(configured.autoCompactionPrompt == prompt)
        #expect(configured.summarization == summarization)
        #expect(configured.discoveryPriming == priming)
        #expect(configured.originalTools.count == 1)
        #expect((configured.originalTools.first as? AmbientEventPostingTool) === tool)
        #expect(configured.grammar == nil)
    }

    @Test("a per-session recordingRoot nests the session flat under that root")
    func recordingRootReachesTheVendedSession() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionConfigurationTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = try await Self.makeProfile(cacheDir: dir)

        let root = dir.appendingPathComponent("recordings", isDirectory: true)
        let session = try #require(
            profile.standard.makeSession(configuration: SessionConfiguration(recordingRoot: root))
                as? RoutedSessionActor)

        let expected = root.appendingPathComponent(session.id.description, isDirectory: true)
        #expect(session.recordingDirectory == expected)
    }

    // MARK: - A grammar makes the session guided

    @Test("a configuration with a grammar vends the session makeGuidedSession vends")
    func grammarConfigurationMatchesMakeGuidedSession() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SessionConfigurationTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = try await Self.makeProfile(cacheDir: dir)

        let grammar = Grammar.jsonSchema(Self.smallSchema)
        let configured = try #require(
            profile.standard.makeSession(configuration: SessionConfiguration(grammar: grammar))
                as? RoutedSessionActor)
        let guided = try #require(
            profile.standard.makeGuidedSession(grammar: grammar) as? RoutedSessionActor)

        #expect(configured.grammar == grammar)
        #expect(configured.grammar == guided.grammar)
    }

    // MARK: - Defaults

    @Test("SessionConfiguration() defaults every field to the makeSession default")
    func emptyConfigurationDefaults() {
        let configuration = SessionConfiguration()
        #expect(configuration.instructions == nil)
        #expect(configuration.workingDirectory == nil)
        #expect(configuration.recordingRoot == nil)
        #expect(configuration.tools.isEmpty)
        #expect(configuration.budget == nil)
        #expect(configuration.compactionPrompt == .default)
        #expect(configuration.summarization == Summarization())
        #expect(configuration.agentSpawn == nil)
        #expect(configuration.discoveryPriming == nil)
        #expect(configuration.grammar == nil)
    }

    // MARK: - The Codable slice

    @Test("the Codable slice round-trips, with tools represented by name")
    func persistableSliceRoundTrips() throws {
        let configuration = SessionConfiguration(
            instructions: "system",
            workingDirectory: URL(fileURLWithPath: "/tmp/work", isDirectory: true),
            recordingRoot: URL(fileURLWithPath: "/tmp/recordings", isDirectory: true),
            tools: [AmbientEventPostingTool(), AmbientNonStringOutputTool()],
            budget: TokenBudget(limit: 4096, hardCeiling: 0.95, toolOutputLimit: 256),
            compactionPrompt: CompactionPrompt(name: "custom", text: "condense"),
            summarization: Summarization(
                keepRecentTurns: 2, maxChunkTokens: 500, summaryTokenRatio: 0.5),
            agentSpawn: SessionSidecar.AgentSpawn(
                parentSessionId: ULID.generate(), parentToolCallId: "call-1"),
            discoveryPriming: DiscoveryPriming(tool: "ambient-emitter", queryProperty: "value"),
            grammar: .ebnf("root ::= \"yes\" | \"no\"")
        )

        let persistable = configuration.persistable
        #expect(persistable.toolNames == configuration.tools.map { $0.name })
        #expect(persistable.instructions == configuration.instructions)
        #expect(persistable.workingDirectory == configuration.workingDirectory)
        #expect(persistable.recordingRoot == configuration.recordingRoot)
        #expect(persistable.budget == configuration.budget)
        #expect(persistable.compactionPrompt == configuration.compactionPrompt)
        #expect(persistable.summarization == configuration.summarization)
        #expect(persistable.agentSpawn == configuration.agentSpawn)
        #expect(persistable.discoveryPriming == configuration.discoveryPriming)
        #expect(persistable.grammar == configuration.grammar)

        let encoded = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(SessionConfiguration.Persistable.self, from: encoded)
        #expect(decoded == persistable)
    }

    @Test("an empty configuration's Codable slice round-trips")
    func emptyPersistableSliceRoundTrips() throws {
        let persistable = SessionConfiguration().persistable
        #expect(persistable.toolNames.isEmpty)

        let encoded = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(SessionConfiguration.Persistable.self, from: encoded)
        #expect(decoded == persistable)
    }
}
