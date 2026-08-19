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
/// The two in this target now call it. The third cannot, and its own doc comment
/// states why: this function needs `@testable import FoundationModelsRouter`,
/// because ``LanguageModelProfile``'s initializer is internal to the router, and
/// `@testable` reaches only a LEAF test target. Measured — hosting this in
/// `FoundationModelsRouterTestSupport` builds under `swift build --build-tests`
/// and breaks `swift build -c release`, which compiles that target against a
/// router with no testability — and SwiftPM cannot share source between two leaf
/// test targets.
///
/// ## What the ungated tests prove, and what they cannot
///
/// Two gated suites call this, each with a 20-minute limit against a 30B model,
/// so a change here cannot be proved by running them. It is proved instead by
/// ``RealModelHarnessTests``, which builds a whole profile over a stub container
/// and reads back every fact this function stamps: the definition name, each
/// slot's resolution, the router id every handle carries, the one gate set the
/// two generation handles share, and the `session.json` the durable recording
/// actually writes to disk. That is why ``make(model:context:container:cacheDir:recordingsDir:routerId:)``
/// takes `any LoadedLLMContainer` rather than the concrete MLX type: the
/// protocol is the only thing this function uses, and taking it is what lets a
/// hermetic test supply a stand-in.
///
/// What no ungated test reaches is the real model's own behavior. A session
/// vended from this profile generating real text stays the gated suites' work.
enum RealModelHarness {
    /// The ``LanguageModelProfile/definitionName`` every profile built here
    /// carries.
    ///
    /// A hand-built profile was resolved from no ``ProfileDefinition`` at all,
    /// so this name records how it was made rather than naming a definition a
    /// reader could go and find. The two suites that moved onto this function
    /// each wrote `"test"` before, and nothing reads the field — no gated suite,
    /// and not the sidecar, which is written with `profile: nil`.
    static let definitionName = "real-model-harness"

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

    /// The ``SlotResolution`` every handle of a harness profile carries.
    ///
    /// A hand-built profile resolved nothing, so this records what was loaded
    /// rather than reporting a decision: no budget was spent and no candidate
    /// was rejected, and `contextTokens` is the window the caller loaded at.
    ///
    /// Separate from ``make(model:context:container:cacheDir:recordingsDir:routerId:)``
    /// because it needs no container, which is what lets ``RealModelHarnessTests``
    /// hold it to the exact value each hand-built copy produced.
    ///
    /// - Parameters:
    ///   - slot: The slot this resolution is for.
    ///   - model: The model reference to stamp it with.
    ///   - context: The working context, in tokens, the model was loaded at.
    /// - Returns: The resolution.
    static func makeResolution(slot: ModelSlot, model: ModelRef, context: Int) -> SlotResolution {
        SlotResolution(
            slot: slot,
            remainingBudgetBytes: 0,
            chosen: model,
            considered: [],
            contextTokens: context
        )
    }

    /// The ``DurableRecording`` every handle of a harness profile records
    /// through — the same root-plus-writer pair `Router.makeDurableRecording`
    /// builds.
    ///
    /// Every session vended from the profile writes its `session.json` through
    /// this, so a tree loaded from disk carries the facts to read it by. That
    /// file is the whole of what a restore reads, which is why
    /// ``RealModelHarnessTests`` drives this writer against a temporary
    /// directory and decodes what it wrote.
    ///
    /// - Parameters:
    ///   - slot: The slot sessions vended from the handle run against.
    ///   - model: The model they run against.
    ///   - context: The working context, in tokens, `model` was loaded at.
    ///   - recordingsDir: The router's durable transcripts root.
    ///   - routerId: The id of the router that owns `recordingsDir`.
    /// - Returns: The durable recording.
    static func makeDurableRecording(
        slot: ModelSlot,
        model: ModelRef,
        context: Int,
        recordingsDir: URL,
        routerId: ULID
    ) -> DurableRecording {
        DurableRecording(
            root: recordingsDir,
            sidecarWriter: SessionSidecarWriter(
                slot: slot,
                model: model,
                context: context,
                recordingLevel: .full,
                profile: nil,
                routerId: routerId
            )
        )
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
    ///   - container: The model that is already loaded and resident. Taken as
    ///     the protocol rather than as ``MLXFoundationModelsContainer``, because
    ///     nothing here needs the concrete type and the protocol is what lets
    ///     ``RealModelHarnessTests`` prove this whole build with no model at all.
    ///   - cacheDir: The directory the router caches under.
    ///   - recordingsDir: The directory the router records under.
    ///   - routerId: The id to stamp the router with. Defaults to a fresh one.
    ///     A caller that restores a session tree across two routers passes the
    ///     FIRST router's id, so the second profile reads the same recording
    ///     root — ``SessionTreeRestorationIntegrationTests`` and
    ///     ``CompactionRoundTripIntegrationTests`` each do exactly that, and
    ///     each reads the id back off ``RoutedModel/routerId``, which is why
    ///     this returns the profile alone and no `Router` beside it.
    /// - Returns: The profile to vend sessions from.
    static func make(
        model: ModelRef,
        context: Int,
        container: any LoadedLLMContainer,
        cacheDir: URL,
        recordingsDir: URL,
        routerId: ULID = .generate()
    ) -> LanguageModelProfile {
        let recorder = JSONLRecorder(directory: recordingsDir)
        let router = Router(id: routerId, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)

        func resolution(_ slot: ModelSlot) -> SlotResolution {
            makeResolution(slot: slot, model: model, context: context)
        }
        func durableRecording(_ slot: ModelSlot) -> DurableRecording {
            makeDurableRecording(
                slot: slot, model: model, context: context, recordingsDir: recordingsDir, routerId: router.id)
        }
        let generationGates = ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        func makeRoutedLLM(_ slot: ModelSlot) -> RoutedLLM {
            RoutedLLM(
                slot: slot,
                chosen: model,
                footprintBytes: 0,
                resolution: resolution(slot),
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
            resolution: resolution(.embedding),
            container: UnusedEmbeddingContainer(),
            routerId: router.id,
            recorder: recorder,
            durableRecording: durableRecording(.embedding),
            gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        )
        return LanguageModelProfile(
            definitionName: definitionName,
            standard: makeRoutedLLM(.standard),
            flash: makeRoutedLLM(.flash),
            embedding: embedding,
            router: router,
            residencyToken: .generate()
        )
    }
}
