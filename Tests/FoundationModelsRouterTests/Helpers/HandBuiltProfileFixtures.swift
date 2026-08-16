import Foundation

@testable import FoundationModelsRouter

/// Builds a ``LanguageModelProfile`` by hand over a container the test already
/// holds, in place of ``Router/resolve(profile:reporting:)``.
///
/// Several suites build a profile this way, to reach one model without a
/// download of the other two. This factory holds that construction in one
/// place: a suite states the container, the model reference and the router, and
/// no suite writes the slot resolution and the two generation handles again.
///
/// The profile records to a fresh ``InMemoryRecorder``, and its embedding slot
/// wraps a ``StubEmbeddingContainer``, because a hand-built profile resolves
/// nothing and therefore holds no residency in its router.
///
/// ``RoutedModel`` and ``LanguageModelProfile`` construct through `@testable`
/// access alone: card ^fmet68k took both initializers off the public surface,
/// because a hand-built profile is a test shape and not a consumer shape. This
/// factory is the entry point that shape goes through, and it is what holds the
/// one-gate rule for a hand-built graph.
enum HandBuiltProfileFixtures {
    /// Builds a profile whose three slots all name one model reference.
    ///
    /// Both generation handles wrap the one `container`, so both take the one
    /// ``ResidentModelGates`` this factory mints for it. The two handles
    /// therefore contend on one generation gate, exactly as two handles over
    /// one pool entry do. There is no argument that changes this: a hand-built
    /// pair with two gates ran two concurrent generations inside one container,
    /// which is the condition the gate exists to prevent, so the shape is not
    /// offered.
    ///
    /// The embedding slot wraps its own stub container, and takes its own gate
    /// set for that reason. The embedding handle acquires neither gate.
    ///
    /// - Parameters:
    ///   - definitionName: The name the profile reports as its definition.
    ///   - chosen: The model reference every slot names.
    ///   - container: The one container both generation handles wrap.
    ///   - router: The router the profile reports its residency to. Nothing is
    ///     resolved through it, so it owns no residency for this profile.
    /// - Returns: The hand-built profile.
    static func makeProfile(
        definitionName: String,
        chosen: ModelRef,
        container: any LoadedLLMContainer,
        router: Router
    ) -> LanguageModelProfile {
        let recorder = InMemoryRecorder()
        let generationGates = ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        return LanguageModelProfile(
            definitionName: definitionName,
            standard: makeGenerationHandle(
                slot: .standard,
                chosen: chosen,
                container: container,
                router: router,
                recorder: recorder,
                gates: generationGates
            ),
            flash: makeGenerationHandle(
                slot: .flash,
                chosen: chosen,
                container: container,
                router: router,
                recorder: recorder,
                gates: generationGates
            ),
            embedding: RoutedEmbedder(
                slot: .embedding,
                chosen: chosen,
                footprintBytes: 0,
                resolution: slotResolution(slot: .embedding, chosen: chosen),
                container: StubEmbeddingContainer(dimension: RouterTestFixtures.stubDimension),
                routerId: router.id,
                recorder: recorder,
                gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
            ),
            router: router,
            residencyToken: .generate()
        )
    }

    /// Builds the reasoning a hand-built slot carries: the chosen model, no
    /// budget left, and no other candidate considered.
    ///
    /// - Parameters:
    ///   - slot: The slot the reasoning belongs to.
    ///   - chosen: The model reference the slot names.
    /// - Returns: The slot resolution.
    private static func slotResolution(slot: ModelSlot, chosen: ModelRef) -> SlotResolution {
        SlotResolution(slot: slot, remainingBudgetBytes: 0, chosen: chosen, considered: [])
    }

    /// Builds one generation handle over `container`.
    ///
    /// - Parameters:
    ///   - slot: The generation slot the handle fills.
    ///   - chosen: The model reference the handle names.
    ///   - container: The container the handle wraps.
    ///   - router: The router the handle stamps its recording root from.
    ///   - recorder: The recorder a vended session is born holding.
    ///   - gates: The gates `container` carries, which every handle over it
    ///     takes.
    /// - Returns: The generation handle.
    private static func makeGenerationHandle(
        slot: ModelSlot,
        chosen: ModelRef,
        container: any LoadedLLMContainer,
        router: Router,
        recorder: any TranscriptRecorder,
        gates: ResidentModelGates
    ) -> RoutedLLM {
        RoutedLLM(
            slot: slot,
            chosen: chosen,
            footprintBytes: 0,
            resolution: slotResolution(slot: slot, chosen: chosen),
            container: container,
            routerId: router.id,
            recorder: recorder,
            gates: gates
        )
    }
}
