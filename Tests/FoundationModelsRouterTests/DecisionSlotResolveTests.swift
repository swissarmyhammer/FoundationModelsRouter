import Foundation
import FoundationModels
import FoundationModelsDecision
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Tests of the decision slot through ``Router/resolve(profile:reporting:)``,
/// over a stub loader and a stub metadata source. The decision candidate of
/// these tests cannot be sized, so the decision slot uses the flash winner:
/// the decision hold is a second hold of the flash entry, which costs no
/// bytes and no second preload. `DecisionSlotFitTests` tests a decision
/// candidate that fits. No test downloads or loads a model, and no test makes
/// a network request.
@Suite("The decision slot of a resolve")
struct DecisionSlotResolveTests {
    // MARK: - Fixed values

    /// The prefix of the temp directory of each test.
    private static let tempDirPrefix = "DecisionSlotResolveTests"

    /// The one decision candidate of ``profile``.
    private static let deciderRef: ModelRef = "org/decider-a"

    /// Why ``UnsizableDeciderMetadataSource`` gives no metadata of
    /// ``deciderRef``.
    private static let unsizableDeciderReason = "the stub source has no metadata of the decider"

    /// The model reference of the logits-capable live container.
    private static let liveContainerRef: ModelRef = "org/logits-stub"

    /// The context window of the logits-capable live container.
    private static let liveContextWindow = 4096

    /// The start of an assistant message that turns reasoning off: the
    /// thinking block is closed.
    private static let closedThinkingSuffix = "<think>\n\n</think>\n\n"

    /// The start of an assistant message that turns reasoning on.
    private static let openThinkingSuffix = "<think>\n"

    /// The state of each decision session.
    private static let state: DecisionState = "The build is red."

    /// The yes-or-no question of the decision tests.
    private static let question = "Does the state report a failure?"

    /// The test profile: the standard test profile, with ``deciderRef`` as
    /// the one decision candidate.
    private static var profile: ProfileDefinition {
        var profile = RouterTestFixtures.profile()
        profile.decision = [deciderRef]
        return profile
    }

    // MARK: - Stubs

    /// What ``RecordingLoader`` saw: the key of each pool request, the ref of
    /// each LLM load, and the count of the preloads.
    private struct LoaderRecord {
        /// The key of each request that the pool asked the loader about.
        var requestedKeys: [ModelPoolKey] = []

        /// The ref of each LLM load.
        var loadedLLMRefs: [ModelRef] = []

        /// The count of the preloads.
        var preloadCount = 0
    }

    /// A ``ModelLoader`` that gives one LLM container for each generation
    /// slot and a stub embedder, and records each pool request, each LLM
    /// load and each preload.
    private final class RecordingLoader: ModelLoader {
        /// The container of each generation slot.
        let container: any LoadedLLMContainer

        /// What the loader saw.
        private let record = Mutex(LoaderRecord())

        /// Makes a loader.
        ///
        /// - Parameter container: The container of each generation slot.
        init(container: any LoadedLLMContainer) {
            self.container = container
        }

        /// What the loader saw so far.
        var seen: LoaderRecord { record.withLock { $0 } }

        func poolKey(for key: ModelPoolKey) async throws -> ModelPoolKey {
            record.withLock { $0.requestedKeys.append(key) }
            return key.withoutContext
        }

        func loadLLM(
            ref: ModelRef, slot: ModelSlot, context: Int, reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            record.withLock { $0.loadedLLMRefs.append(ref) }
            return container
        }

        func loadEmbedder(
            ref: ModelRef, slot: ModelSlot, reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            StubEmbeddingContainer(dimension: RouterTestFixtures.stubDimension)
        }

        func preload(container: any LoadedModelContainer) async throws {
            record.withLock { $0.preloadCount += 1 }
        }
    }

    /// A ``MetadataSource`` that answers each fetch with the canned metadata
    /// of the fixtures, and records the repo of each fetch.
    private final class RecordingMetadataSource: MetadataSource {
        /// The repo of each fetch, in order.
        private let repos = Mutex<[String]>([])

        /// The repo of each fetch so far.
        var fetchedRepos: [String] { repos.withLock { $0 } }

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            repos.withLock { $0.append(repo) }
            return RouterTestFixtures.rawMetadata
        }
    }

    /// A ``MetadataSource`` that gives the canned metadata of the fixtures
    /// for each repo but the repo of ``deciderRef``. A fetch of that repo
    /// throws, so the decision candidate cannot be sized.
    private struct UnsizableDeciderMetadataSource: MetadataSource {
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            guard repo != DecisionSlotResolveTests.deciderRef.repo else {
                throw RepoMetadataError.metadataUnavailable(DecisionSlotResolveTests.unsizableDeciderReason)
            }
            return RouterTestFixtures.rawMetadata
        }
    }

    /// The result of one resolve: the profile, the loader, and the pool.
    private struct Resolved {
        /// The resolved profile.
        let profile: LanguageModelProfile

        /// The loader of the resolve.
        let loader: RecordingLoader

        /// The pool of the resolve.
        let pool: ModelPool

        /// The progress of the resolve.
        let progress: ResolutionProgress
    }

    // MARK: - Helpers

    /// Resolves ``profile`` over a ``RecordingLoader`` of `container` and an
    /// ``UnsizableDeciderMetadataSource``, in a fresh pool.
    ///
    /// - Parameter container: The container of each generation slot.
    /// - Returns: The profile, the loader, the pool and the progress.
    /// - Throws: The error of the resolve.
    @MainActor
    private static func resolve(over container: any LoadedLLMContainer = BasicLLMContainer()) async throws -> Resolved {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let loader = RecordingLoader(container: container)
        let pool = ModelPool()
        let router = Router(
            cacheDir: cacheDir, probe: RouterTestFixtures.stubProbe,
            metadataSource: UnsizableDeciderMetadataSource(), loader: loader, pool: pool)
        let progress = ResolutionProgress()
        let profile = try await router.resolve(profile: Self.profile, reporting: progress)
        return Resolved(profile: profile, loader: loader, pool: pool, progress: progress)
    }

    /// Makes a live container over a stub model that gives log probabilities.
    ///
    /// - Parameter logits: The stub that answers each logits call.
    /// - Returns: The container.
    private static func logitsCapableContainer(over logits: StubLogits) -> LiveLLMContainer {
        LiveLLMContainer(
            model: LogitsStubLanguageModel(logits: logits), ref: liveContainerRef,
            contextWindow: liveContextWindow, tokenCounter: CharacterTokenCounter())
    }

    // MARK: - The flash winner

    @Test("the decision handle uses the flash winner")
    @MainActor
    func decisionHandleUsesTheFlashWinner() async throws {
        let resolved = try await Self.resolve()

        #expect(resolved.profile.decision.chosen == resolved.profile.flash.chosen)
    }

    @Test("the decision handle records the flash fallback")
    @MainActor
    func decisionHandleRecordsTheFlashFallback() async throws {
        let resolved = try await Self.resolve()

        #expect(resolved.profile.decision.resolution.fallback == .flashModel)
    }

    @Test("the decision handle records the decision candidate with the reason it cannot be sized")
    @MainActor
    func decisionHandleRecordsEachCandidate() async throws {
        let considered = try await Self.resolve().profile.decision.resolution.considered

        #expect(considered.map(\.ref) == [Self.deciderRef])
        #expect(considered.map(\.verdict) == [.metadataUnavailable(Self.unsizableDeciderReason)])
    }

    @Test("the decision slot of the progress is ready with the flash winner")
    @MainActor
    func decisionProgressIsReadyWithTheFlashWinner() async throws {
        let resolved = try await Self.resolve()
        let decision = try #require(resolved.progress.slots[.decision])

        #expect(decision == SlotProgress(state: .ready, chosen: resolved.profile.flash.chosen))
    }

    // MARK: - The shared key

    @Test("the decision slot takes one more hold of the flash entry")
    @MainActor
    func decisionSlotTakesOneMoreHoldOfTheFlashEntry() async throws {
        let resolved = try await Self.resolve()
        let flashRequests = resolved.loader.seen.requestedKeys.filter { $0.ref == resolved.profile.flash.chosen }

        #expect(flashRequests.count == 2)
    }

    @Test("the decision slot loads no second copy of the flash model")
    @MainActor
    func decisionSlotLoadsNoSecondCopy() async throws {
        let resolved = try await Self.resolve()
        let flashLoads = resolved.loader.seen.loadedLLMRefs.filter { $0 == resolved.profile.flash.chosen }

        #expect(flashLoads.count == 1)
    }

    @Test("the flash model is preloaded once, and each other model once")
    @MainActor
    func eachModelIsPreloadedOnce() async throws {
        let resolved = try await Self.resolve()
        let loadedModelCount = Set([
            resolved.profile.standard.chosen, resolved.profile.flash.chosen, resolved.profile.embedding.chosen,
        ]).count

        #expect(resolved.loader.seen.preloadCount == loadedModelCount)
    }

    @Test("the decision hold adds no bytes to the footprint of the pool")
    @MainActor
    func decisionHoldAddsNoBytes() async throws {
        let resolved = try await Self.resolve()
        let profile = resolved.profile
        let trioBytes = profile.standard.footprintBytes + profile.flash.footprintBytes
            + profile.embedding.footprintBytes

        #expect(resolved.pool.footprint.totalBytes == trioBytes)
    }

    @Test("the decision handle of a shared key reports no footprint")
    @MainActor
    func decisionHandleOfASharedKeyReportsNoFootprint() async throws {
        let resolved = try await Self.resolve()

        #expect(resolved.profile.decision.footprintBytes == 0)
    }

    // MARK: - The decision container

    @Test("a decision over a stub container that gives no logits throws notLogitsCapable")
    @MainActor
    func decisionOverAPlainContainerThrowsNotLogitsCapable() async throws {
        let decider = try await Self.resolve().profile.decision
        let session = decider.makeSession(state: Self.state)

        await #expect(throws: PooledLogitsModelError.notLogitsCapable(decider.chosen)) {
            try await session.probability(of: Self.question)
        }
    }

    @Test("a decision over a stub container that gives logits reads the logits of the flash model")
    @MainActor
    func decisionOverALogitsContainerReadsTheLogits() async throws {
        let logits = StubLogits(reasoningOffSuffix: Self.closedThinkingSuffix, reasoningOnSuffix: Self.openThinkingSuffix)
        let resolved = try await Self.resolve(over: Self.logitsCapableContainer(over: logits))

        _ = try await resolved.profile.decision.makeSession(state: Self.state).probability(of: Self.question)

        #expect(logits.logProbabilityCallCount == 1)
    }

    // MARK: - No network

    /// Resolves `profile` over a ``RecordingMetadataSource`` and a stub
    /// loader, in a fresh pool.
    ///
    /// - Parameter profile: The profile to resolve.
    /// - Returns: The repo of each metadata fetch of the resolve, in order.
    /// - Throws: The error of the resolve.
    @MainActor
    private static func fetchedRepos(resolving profile: ProfileDefinition) async throws -> [String] {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let source = RecordingMetadataSource()
        let router = Router(
            cacheDir: cacheDir, probe: RouterTestFixtures.stubProbe, metadataSource: source,
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension),
            pool: ModelPool())
        _ = try await router.resolve(profile: profile, reporting: ResolutionProgress())
        return source.fetchedRepos
    }

    @Test("a resolve of the shared test profile fetches no metadata of the default decision model")
    @MainActor
    func sharedTestProfileFetchesNoDefaultDecisionModel() async throws {
        let defaultDecisionRepos = Set(ProfileDefinition.defaultDecisionCandidates.map(\.repo))

        let fetched = try await Self.fetchedRepos(resolving: RouterTestFixtures.profile())

        #expect(Set(fetched).isDisjoint(with: defaultDecisionRepos))
    }

    // MARK: - Sizing

    @Test("a resolve fetches the metadata of a decision candidate once")
    @MainActor
    func decisionCandidateIsFetchedOnce() async throws {
        let fetched = try await Self.fetchedRepos(resolving: Self.profile)

        #expect(fetched.filter { $0 == Self.deciderRef.repo }.count == 1)
    }

    @Test("a resolve fetches the metadata of a decision candidate that is also a flash candidate once")
    @MainActor
    func decisionCandidateSharedWithFlashIsFetchedOnce() async throws {
        var profile = RouterTestFixtures.profile()
        let flashRef = try #require(profile.flash.first)
        profile.decision = [flashRef]

        let fetched = try await Self.fetchedRepos(resolving: profile)

        #expect(fetched.filter { $0 == flashRef.repo }.count == 1)
    }
}
