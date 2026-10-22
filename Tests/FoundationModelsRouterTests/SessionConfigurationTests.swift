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

        let configuredSession = profile.standard.makeSession(configuration: SessionConfiguration())
        let referenceSession = profile.standard.makeSession()
        defer { await SessionFixtureLifecycle.close([configuredSession, referenceSession]) }
        let configured = try #require(configuredSession as? RoutedSessionActor)
        let reference = try #require(referenceSession as? RoutedSessionActor)

        #expect(configured.grammar == reference.grammar)
        #expect(configured.instructions == reference.instructions)
        #expect(configured.autoCompactionBudget == reference.autoCompactionBudget)
        #expect(configured.autoCompactionPrompt == reference.autoCompactionPrompt)
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
        let priming = DiscoveryPriming(tool: "ambient-emitter", queryProperty: "value")
        let spawn = SessionRecord.AgentSpawn(
            parentSessionId: ULID.generate(), parentToolCallId: "call-1")
        let tool = AmbientEventPostingTool()

        let configuration = SessionConfiguration(
            instructions: "system",
            workingDirectory: workingDirectory,
            tools: [tool],
            compaction: CompactionSettings(budget: budget, prompt: prompt),
            agentSpawn: spawn,
            discoveryPriming: priming
        )
        let configuredSession = profile.standard.makeSession(configuration: configuration)
        let referenceSession = profile.standard.makeSession(
            instructions: "system",
            workingDirectory: workingDirectory,
            tools: [tool],
            budget: budget,
            compactionPrompt: prompt,
            agentSpawn: spawn,
            discoveryPriming: priming
        )
        defer { await SessionFixtureLifecycle.close([configuredSession, referenceSession]) }
        let configured = try #require(configuredSession as? RoutedSessionActor)
        let reference = try #require(referenceSession as? RoutedSessionActor)

        #expect(configured.instructions == reference.instructions)
        #expect(configured.workingDirectory == reference.workingDirectory)
        #expect(configured.workingDirectory == workingDirectory)
        #expect(configured.autoCompactionBudget == budget)
        #expect(configured.autoCompactionPrompt == prompt)
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
        let vended = profile.standard.makeSession(configuration: SessionConfiguration(recordingRoot: root))
        defer { await vended.close() }
        let session = try #require(vended as? RoutedSessionActor)

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
        let configuredSession = profile.standard.makeSession(configuration: SessionConfiguration(grammar: grammar))
        let guidedSession = profile.standard.makeGuidedSession(grammar: grammar)
        defer { await SessionFixtureLifecycle.close([configuredSession, guidedSession]) }
        let configured = try #require(configuredSession as? RoutedSessionActor)
        let guided = try #require(guidedSession as? RoutedSessionActor)

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
        #expect(configuration.compaction.budget == nil)
        #expect(configuration.compaction.prompt == .default)
        #expect(configuration.compaction.toolOutputProtection == nil)
        #expect(configuration.agentSpawn == nil)
        #expect(configuration.discoveryPriming == nil)
        #expect(configuration.grammar == nil)
        #expect(configuration.userPresence == .interactive)
    }

    // MARK: - The Codable slice

    /// Makes a configuration that sets every field the Codable slice records.
    ///
    /// - Returns: A configuration with no field at its default.
    private static func makeFullConfiguration() -> SessionConfiguration {
        SessionConfiguration(
            instructions: "system",
            workingDirectory: URL(fileURLWithPath: "/tmp/work", isDirectory: true),
            recordingRoot: URL(fileURLWithPath: "/tmp/recordings", isDirectory: true),
            tools: [AmbientEventPostingTool(), AmbientNonStringOutputTool()],
            compaction: CompactionSettings(
                budget: TokenBudget(limit: 4096, hardCeiling: 0.95, toolOutputLimit: 256),
                prompt: CompactionPrompt(name: "custom", text: "condense")),
            agentSpawn: SessionRecord.AgentSpawn(
                parentSessionId: ULID.generate(), parentToolCallId: "call-1"),
            discoveryPriming: DiscoveryPriming(tool: "ambient-emitter", queryProperty: "value"),
            grammar: .ebnf("root ::= \"yes\" | \"no\""),
            inlineSettleGrace: 0.25,
            userPresence: .headless
        )
    }

    @Test("the Codable slice round-trips, with tools represented by name")
    func persistableSliceRoundTrips() throws {
        let configuration = Self.makeFullConfiguration()

        let persistable = configuration.persistable
        #expect(persistable.toolNames == configuration.tools.map { $0.name })
        #expect(persistable.instructions == configuration.instructions)
        #expect(persistable.workingDirectory == configuration.workingDirectory)
        #expect(persistable.recordingRoot == configuration.recordingRoot)
        #expect(persistable.budget == configuration.compaction.budget)
        #expect(persistable.compactionPrompt == configuration.compaction.prompt)
        #expect(persistable.agentSpawn == configuration.agentSpawn)
        #expect(persistable.discoveryPriming == configuration.discoveryPriming)
        #expect(persistable.grammar == configuration.grammar)
        #expect(persistable.inlineSettleGrace == configuration.inlineSettleGrace)
        #expect(persistable.restoredUserPresence == configuration.userPresence)

        let encoded = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(SessionConfiguration.Persistable.self, from: encoded)
        #expect(decoded == persistable)
        #expect(decoded.restoredUserPresence == configuration.userPresence)
    }

    @Test("an empty configuration's Codable slice round-trips")
    func emptyPersistableSliceRoundTrips() throws {
        let persistable = SessionConfiguration().persistable
        #expect(persistable.toolNames.isEmpty)

        let encoded = try JSONEncoder().encode(persistable)
        let decoded = try JSONDecoder().decode(SessionConfiguration.Persistable.self, from: encoded)
        #expect(decoded == persistable)
    }

    // MARK: - The removed summarization key

    /// The key of the summarization stage that task ^mvm7zjy removed. A
    /// record does not write it.
    private static let legacySummarizationKey = "summarization"

    /// Encodes `persistable` and returns the top-level JSON object.
    ///
    /// - Parameter persistable: The slice to encode.
    /// - Returns: The top-level JSON object of the encoded slice.
    /// - Throws: What the encoder throws, or a failed `#require`.
    private static func jsonObject(of persistable: SessionConfiguration.Persistable) throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(persistable)
        return try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }

    @Test("a new Codable slice does not write the summarization key")
    func newPersistableSliceHasNoSummarizationKey() throws {
        let object = try Self.jsonObject(of: SessionConfiguration().persistable)
        #expect(object[Self.legacySummarizationKey] == nil)
    }

    // MARK: - The grouped compaction settings keep flat keys in the slice

    /// The top-level keys of the Codable slice of a configuration that sets
    /// every field. The compaction settings are in the flat `budget` and
    /// `compactionPrompt` keys, and no `compaction` key exists.
    private static let flatSliceKeys: Set<String> = [
        "instructions", "workingDirectory", "recordingRoot", "toolNames",
        "budget", "compactionPrompt", "agentSpawn", "discoveryPriming",
        "grammar", "repetitionDetection", "mailOnlyAnswerLimit", "inlineSettleGrace", "userPresence",
    ]

    /// A Codable slice of a record that sets only the instructions, the
    /// tools and the compaction settings, which sit in the flat keys.
    private static let flatSlice = """
        {
          "instructions": "system",
          "toolNames": ["ambient-emitter"],
          "budget": {"limit": 4096, "trigger": 0.9, "target": 0.6, "toolOutputLimit": 256},
          "compactionPrompt": {"name": "custom", "text": "condense"}
        }
        """

    @Test("the compaction settings reach the flat budget and compactionPrompt of the Codable slice")
    func compactionSettingsReachTheFlatSliceKeys() {
        let budget = TokenBudget(limit: 4096, trigger: 0.9, target: 0.6)
        let prompt = CompactionPrompt(name: "custom", text: "condense")

        let persistable = SessionConfiguration(
            compaction: CompactionSettings(budget: budget, prompt: prompt)
        ).persistable

        #expect(persistable.budget == budget)
        #expect(persistable.compactionPrompt == prompt)
    }

    @Test("a Codable slice of a full configuration writes the flat compaction keys and no compaction key")
    func newPersistableSliceKeepsTheFlatKeys() throws {
        let object = try Self.jsonObject(of: Self.makeFullConfiguration().persistable)
        #expect(Set(object.keys) == Self.flatSliceKeys)
    }

    @Test("the compaction settings round-trip through the encoded Codable slice")
    func compactionSettingsRoundTripThroughTheSlice() throws {
        let budget = TokenBudget(limit: 4096, trigger: 0.9, target: 0.6, toolOutputLimit: 256)
        let prompt = CompactionPrompt(name: "custom", text: "condense")
        let protection: ToolOutputProtection = { call, _ in call.toolName == "keep" }
        let configuration = SessionConfiguration(
            compaction: CompactionSettings(budget: budget, prompt: prompt, toolOutputProtection: protection))

        let encoded = try JSONEncoder().encode(configuration.persistable)
        let decoded = try JSONDecoder().decode(SessionConfiguration.Persistable.self, from: encoded)
        let restored = decoded.compaction(toolOutputProtection: configuration.compaction.toolOutputProtection)

        #expect(restored.budget == configuration.compaction.budget)
        #expect(restored.prompt == configuration.compaction.prompt)
        #expect(restored.toolOutputProtection != nil)
    }

    @Test("a record's Codable slice with the flat compaction keys decodes into the compaction settings")
    func flatSliceDecodes() throws {
        let data = try #require(Self.flatSlice.data(using: .utf8))

        let decoded = try JSONDecoder().decode(SessionConfiguration.Persistable.self, from: data)

        #expect(decoded.instructions == "system")
        #expect(decoded.toolNames == ["ambient-emitter"])
        #expect(decoded.budget == TokenBudget(limit: 4096, trigger: 0.9, target: 0.6, toolOutputLimit: 256))
        #expect(decoded.compactionPrompt == CompactionPrompt(name: "custom", text: "condense"))
        #expect(decoded.restoredUserPresence == .interactive)

        let compaction = decoded.compaction(toolOutputProtection: nil)
        #expect(compaction.budget == decoded.budget)
        #expect(compaction.prompt == decoded.compactionPrompt)
        #expect(compaction.toolOutputProtection == nil)
    }
}
