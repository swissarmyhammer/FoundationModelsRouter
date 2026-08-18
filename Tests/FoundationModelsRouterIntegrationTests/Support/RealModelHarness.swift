import Foundation
import FoundationModels

@testable import FoundationModelsRouter

/// The one way a gated suite in this target builds a real ``LanguageModelProfile``
/// over a model it has already loaded.
///
/// A gated suite cannot call `Router.resolve(_:reporting:)`. That call downloads
/// the `.flash` and the `.embedding` slots as well, and a suite that folds one
/// transcript does not need either model. So each suite builds the profile by
/// hand over the one container it loaded, and vends its sessions from that.
///
/// Three suites wrote that same body before this type: ``CompactionRoundTripIntegrationTests``,
/// ``SessionTreeRestorationIntegrationTests``, and
/// `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift`.
/// The three copies differ only in the model they name and the context they
/// resolve at, and those two are this function's parameters. This type is the
/// same consolidation ``RealModelContainer`` is, and for the same reason: a new
/// suite copied whichever neighbour it happened to read.
///
/// The three copies stay as they are for now. Two of them are 20-minute gated
/// suites, and the card that added this type could not run either one to prove
/// the change safe. A follow-up card moves them.
///
/// ## What is deliberately not a parameter
///
/// The router's own identity. A caller that restores a session tree across two
/// routers must stamp the second router with the first router's id, and no
/// caller here does that yet. The parameter is added with the first caller that
/// needs it, rather than before.
enum RealModelHarness {
    /// A minimal ``LoadedEmbeddingContainer`` stand-in for the `.embedding` slot
    /// every ``LanguageModelProfile`` must carry. No suite that builds a profile
    /// here embeds anything, so this is present only to satisfy the type.
    private struct UnusedEmbeddingContainer: LoadedEmbeddingContainer {
        /// The dimension of a vector this container never makes.
        let dimension = 1

        /// Answers with no vectors, because nothing calls this.
        ///
        /// - Parameter texts: The texts to embed. Ignored.
        /// - Returns: An empty array.
        func embed(texts: [String]) async throws -> [[Float]] { [] }
    }

    /// Builds a real ``LanguageModelProfile`` over `container`.
    ///
    /// The `.standard` and the `.flash` slots both wrap `container`, so a fold
    /// that prefers the flash tier generates over the same resident model. Both
    /// slots also share one ``ResidentModelGates`` set, as they would from a
    /// pool entry: two sets would let two generations run inside the one
    /// container at the same time.
    ///
    /// - Parameters:
    ///   - model: The model reference to stamp every slot with. This is a
    ///     record of what was loaded, not an instruction to load it.
    ///   - context: The working context to resolve every slot at. A session
    ///     vended from the profile reports its ``RoutedSession/contextFill``
    ///     against this number.
    ///   - container: The model that is already loaded and resident.
    ///   - cacheDir: The directory the router caches under.
    ///   - recordingsDir: The directory the router records under.
    /// - Returns: The profile to vend sessions from.
    static func make(
        model: ModelRef,
        context: Int,
        container: MLXFoundationModelsContainer,
        cacheDir: URL,
        recordingsDir: URL
    ) -> LanguageModelProfile {
        let recorder = JSONLRecorder(directory: recordingsDir)
        let router = Router(cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)

        func noopResolution(_ slot: ModelSlot) -> SlotResolution {
            SlotResolution(
                slot: slot,
                remainingBudgetBytes: 0,
                chosen: model,
                considered: [],
                contextTokens: context
            )
        }
        // The same root-plus-writer pair `Router.makeDurableRecording` builds.
        // Every session vended from this profile writes its `session.json`
        // through it, so a tree loaded from disk carries the facts to read it
        // by.
        func durableRecording(_ slot: ModelSlot) -> DurableRecording {
            DurableRecording(
                root: recordingsDir,
                sidecarWriter: SessionSidecarWriter(
                    slot: slot,
                    model: model,
                    context: context,
                    recordingLevel: .full,
                    profile: nil,
                    routerId: router.id
                )
            )
        }
        let generationGates = ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        func makeRoutedLLM(_ slot: ModelSlot) -> RoutedLLM {
            RoutedLLM(
                slot: slot,
                chosen: model,
                footprintBytes: 0,
                resolution: noopResolution(slot),
                container: container,
                routerId: router.id,
                recorder: recorder,
                durableRecording: durableRecording(slot),
                gates: generationGates
            )
        }
        let embedding = RoutedEmbedder(
            slot: .embedding,
            chosen: model,
            footprintBytes: 0,
            resolution: noopResolution(.embedding),
            container: UnusedEmbeddingContainer(),
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.embedding),
            gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        )
        return LanguageModelProfile(
            definitionName: "real-model-harness",
            standard: makeRoutedLLM(.standard),
            flash: makeRoutedLLM(.flash),
            embedding: embedding,
            router: router,
            residencyToken: .generate()
        )
    }
}
