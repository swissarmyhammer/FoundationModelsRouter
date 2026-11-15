import Foundation
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Synchronization
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Tests of the context of the decision slot (task ^fmhvrme).
///
/// The decision slot is sized, keyed and loaded at
/// ``ProfileDefinition/decisionContext``, and not at the shared window: a
/// decision state is small, and a GGUF decision model allocates its whole KV
/// cache at load. The window search still fits the four slots together, and
/// the decision charge is constant in the window. No network and no I/O: the
/// footprints of the joint fit are injected, and the resolve runs over stubs.
@Suite("The context of the decision slot")
struct DecisionContextTests {
    // MARK: - Fixed values

    /// The one standard candidate.
    private static let standardRef: ModelRef = "org/ctx-standard"

    /// The one flash candidate.
    private static let flashRef: ModelRef = "org/ctx-flash"

    /// The one embedding candidate.
    private static let embeddingRef: ModelRef = "org/ctx-embedding"

    /// A GGUF-shaped decision candidate: its KV cache grows with its context.
    private static let deciderRef: ModelRef = "org/ctx-decider"

    /// The native window of each candidate.
    private static let nativeWindow = 65_536

    /// The bytes of KV cache that the standard model adds for each token.
    private static let standardBytesPerToken: Int64 = 2

    /// The bytes of KV cache that the decision model adds for each token.
    private static let deciderBytesPerToken: Int64 = 1

    /// The weights of the standard model.
    private static let standardWeights: Int64 = 1_000

    /// The weights of the decision model.
    private static let deciderWeights: Int64 = 1_500

    /// The flat footprint of the flash model.
    private static let flashBytes: Int64 = 2_000

    /// The flat footprint of the embedding model.
    private static let embeddingBytes: Int64 = 500

    /// The window of the standard model in ``budgetBytes``, when the decision
    /// model is sized at the default decision context.
    private static let expectedWindow = 40_000

    /// A budget in which the standard model gets ``expectedWindow`` beside
    /// the decision model at ``ProfileDefinition/defaultDecisionContext``.
    private static let budgetBytes: Int64 =
        embeddingBytes + standardWeights + flashBytes + deciderWeights
        + deciderBytesPerToken * Int64(ProfileDefinition.defaultDecisionContext)
        + standardBytesPerToken * Int64(expectedWindow)

    /// The contexts at which the joint fit sized each candidate.
    private final class SizedContexts: Sendable {
        /// The context of each call, by candidate.
        private let contexts = Mutex<[ModelRef: [Int]]>([:])

        /// The contexts at which `ref` was sized, in call order.
        func contexts(of ref: ModelRef) -> [Int] { contexts.withLock { $0[ref] ?? [] } }

        /// Records one call.
        func record(_ ref: ModelRef, context: Int) {
            contexts.withLock { $0[ref, default: []].append(context) }
        }
    }

    // MARK: - Helpers

    /// The raw footprint of each candidate at `context`.
    private static func footprint(of ref: ModelRef, context: Int) -> Int64 {
        switch ref {
        case standardRef: standardWeights + standardBytesPerToken * Int64(context)
        case flashRef: flashBytes
        case embeddingRef: embeddingBytes
        default: deciderWeights + deciderBytesPerToken * Int64(context)
        }
    }

    /// The test profile: one candidate for each slot, at a derived window.
    ///
    /// - Parameter decisionContext: The context of the decision slot, or
    ///   `nil` for the default.
    /// - Returns: The profile.
    private static func profile(decisionContext: Int? = nil) -> ProfileDefinition {
        var profile = ProfileDefinition(
            name: "decision-context",
            description: "a GGUF-shaped decision model beside a derived window",
            standard: [standardRef],
            flash: [flashRef],
            embedding: [embeddingRef],
            decision: [deciderRef]
        )
        if let decisionContext { profile.decisionContext = decisionContext }
        return profile
    }

    /// Runs the joint fit over ``footprint(of:context:)``.
    private static func resolve(
        _ profile: ProfileDefinition, sized: SizedContexts = SizedContexts()
    ) throws -> JointResolution {
        try JointFit.resolve(
            profile: profile,
            budgetBytes: budgetBytes,
            footprint: { ref, _, context, _ in
                sized.record(ref, context: context)
                return .success(footprint(of: ref, context: context))
            },
            nativeMaxContext: { _ in .success(nativeWindow) }
        )
    }

    /// The resolution of `slot`.
    private static func resolution(_ result: JointResolution, for slot: ModelSlot) throws -> SlotResolution {
        try #require(result.slots.first { $0.slot == slot })
    }

    // MARK: - ProfileDefinition

    @Test("the decision context of a profile defaults to 16,384 tokens")
    func decisionContextDefaultsTo16K() {
        #expect(ProfileDefinition.defaultDecisionContext == 16_384)
        #expect(Self.profile().decisionContext == ProfileDefinition.defaultDecisionContext)
    }

    @Test("the initializer sets the decision context")
    func initializerSetsTheDecisionContext() {
        let profile = ProfileDefinition(
            name: "p", description: "d", standard: [Self.standardRef], flash: [Self.flashRef],
            embedding: [Self.embeddingRef], decision: [Self.deciderRef], decisionContext: 4_096)

        #expect(profile.decisionContext == 4_096)
    }

    @Test("JSON with no decisionContext key decodes to the default, and the key round-trips")
    func decisionContextCodable() throws {
        let json = Data(
            #"{"name":"p","description":"d","standard":["org/a"],"flash":["org/b"],"embedding":["org/c"]}"#.utf8)
        let decoded = try JSONDecoder().decode(ProfileDefinition.self, from: json)
        #expect(decoded.decisionContext == ProfileDefinition.defaultDecisionContext)

        let encoded = try JSONEncoder().encode(Self.profile(decisionContext: 2_048))
        #expect(try JSONDecoder().decode(ProfileDefinition.self, from: encoded).decisionContext == 2_048)
    }

    // MARK: - The joint fit

    @Test("with a derived window, the decision model is sized at the decision context")
    func decisionModelIsSizedAtTheDecisionContext() throws {
        let sized = SizedContexts()
        let result = try Self.resolve(Self.profile(), sized: sized)

        #expect(try Self.resolution(result, for: .decision).contextTokens == ProfileDefinition.defaultDecisionContext)
        #expect(Set(sized.contexts(of: Self.deciderRef)) == [ProfileDefinition.defaultDecisionContext])
    }

    @Test("with a derived window, the decision charge is constant, so the standard window gets the rest")
    func standardWindowExcludesTheDecisionSlope() throws {
        let result = try Self.resolve(Self.profile())

        #expect(try Self.resolution(result, for: .standard).contextTokens == Self.expectedWindow)
    }

    @Test("a profile's own decision context is used")
    func profileDecisionContextIsUsed() throws {
        let sized = SizedContexts()
        let result = try Self.resolve(Self.profile(decisionContext: 4_096), sized: sized)

        #expect(try Self.resolution(result, for: .decision).contextTokens == 4_096)
        #expect(Set(sized.contexts(of: Self.deciderRef)) == [4_096])
    }

    // MARK: - The price of a decision model that a winner serves

    /// The price of the router of the flash model in the decision slot at
    /// `decisionContext`, when the flash slot allocated it at `flashContext`.
    private static func decisionPriceOfTheAllocatedFlash(
        metadata: RepoMetadata, flashContext: Int, decisionContext: Int
    ) throws -> Int64 {
        try Router.footprintBytes(
            for: flashRef, in: .decision, context: decisionContext, metadataByRef: [flashRef: .success(metadata)],
            membership: [flashRef: [.flash, .decision]], residentKeys: [],
            allocatedKeys: [ModelSlot.flash.poolKey(of: flashRef, context: flashContext)]
        ).get()
    }

    @Test("a GGUF decision model that is the flash model at a bigger flash window costs 0")
    func ggufFlashAtABiggerWindowServesTheDecisionSlot() throws {
        let metadata = try RepoMetadata(
            ggufHeader: GGUFModelHeader(prefix: GGUFHeaderFixtures.denseBytes), weightBytes: Self.deciderWeights,
            name: "fixture")

        #expect(
            try Self.decisionPriceOfTheAllocatedFlash(
                metadata: metadata, flashContext: 100_000, decisionContext: ProfileDefinition.defaultDecisionContext)
                == 0)
    }

    @Test("an MLX decision model that is the flash model costs 0 also when the flash window is smaller")
    func mlxFlashServesAnyDecisionContext() throws {
        let metadata = try RepoMetadata(raw: RouterTestFixtures.rawMetadata, repo: Self.flashRef.repo)

        #expect(
            try Self.decisionPriceOfTheAllocatedFlash(
                metadata: metadata, flashContext: 8_192, decisionContext: ProfileDefinition.defaultDecisionContext)
                == 0)
    }

    // MARK: - The resolve

    /// What a stub loader saw: the key of each pool request.
    private final class KeyRecordingLoader: ModelLoader {
        /// The key of each request that the pool asked about.
        private let keys = Mutex<[ModelPoolKey]>([])

        /// The keys so far.
        var requestedKeys: [ModelPoolKey] { keys.withLock { $0 } }

        func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey {
            keys.withLock { $0.append(key) }
            return key.withoutContext
        }

        func loadLLM(
            ref: ModelRef, slot: ModelSlot, context: Int, reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            BasicLLMContainer()
        }

        func loadEmbedder(
            ref: ModelRef, slot: ModelSlot, reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            StubEmbeddingContainer(dimension: RouterTestFixtures.stubDimension)
        }

        func preload(container: any LoadedModelContainer) async throws {}
    }

    /// The decision candidate of the resolve tests: a model of its own.
    private static let resolveDeciderRef: ModelRef = "org/decider-own"

    /// The decision context of the resolve tests.
    private static let resolveDecisionContext = 2_048

    /// The shared test profile, with a decision model of its own at
    /// ``resolveDecisionContext``.
    private static var resolveProfile: ProfileDefinition {
        var profile = RouterTestFixtures.profile()
        profile.decision = [resolveDeciderRef]
        profile.decisionContext = resolveDecisionContext
        return profile
    }

    @Test("a resolve asks the pool for the decision model at the decision context, and reports it")
    @MainActor
    func resolveKeysAndReportsTheDecisionContext() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "DecisionContextTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loader = KeyRecordingLoader()
        let tracer = InMemoryTracer()
        let router = RouterTestFixtures.makeRouter(cacheDir: dir, loader: loader, tracer: tracer)
        let progress = ResolutionProgress()

        let profile = try await router.resolve(profile: Self.resolveProfile, reporting: progress)

        let deciderKeys = loader.requestedKeys.filter { $0.ref == Self.resolveDeciderRef }
        #expect(deciderKeys.map(\.contextSize) == [Self.resolveDecisionContext])
        #expect(profile.decision.resolution.contextTokens == Self.resolveDecisionContext)
        #expect(progress.slots[.decision]?.contextTokens == Self.resolveDecisionContext)
        #expect(progress.slots[.standard]?.contextTokens == ScriptedSessionContext.tokens)
        let span = try #require(tracer.finishedSpans(named: "FoundationModelsRouter.resolve").first)
        #expect(span.attributes.get("context.tokens") == .int64(Int64(ScriptedSessionContext.tokens)))
        #expect(span.attributes.get("context.decision_tokens") == .int64(Int64(Self.resolveDecisionContext)))
        withExtendedLifetime(router) {}
    }
}
