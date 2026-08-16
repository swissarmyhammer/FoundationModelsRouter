import Foundation

@testable import FoundationModelsRouter

/// Builds a ``LanguageModelProfile`` by hand over a container the test already
/// holds, in place of ``Router/resolve(profile:reporting:)``.
///
/// Several suites build a profile this way, to reach one model without a
/// download of the other two. This factory holds that construction in one
/// place: a suite states the container, the model reference and the gate, and
/// no suite writes the slot resolution and the two generation handles again.
///
/// The profile records to a fresh ``InMemoryRecorder``, and its embedding slot
/// wraps a ``StubEmbeddingContainer``, because a hand-built profile resolves
/// nothing and therefore holds no residency in its router.
enum HandBuiltProfileFixtures {
    /// Builds a profile whose three slots all name one model reference.
    ///
    /// `generationGate` has no default value on purpose. ``RoutedModel`` makes
    /// a fresh gate when the argument is `nil`, so two hand-built handles over
    /// one container then hold two gates and can never contend. That is a
    /// hazard and not a property to keep, and card ^fmet68k carries the fix, so
    /// each caller must state which of the two shapes it asks for.
    ///
    /// - Parameters:
    ///   - definitionName: The name the profile reports as its definition.
    ///   - chosen: The model reference every slot names.
    ///   - container: The one container both generation handles wrap.
    ///   - router: The router the profile reports its residency to. Nothing is
    ///     resolved through it, so it owns no residency for this profile.
    ///   - generationGate: The gate both generation handles share, or `nil` to
    ///     give each handle a fresh gate of its own.
    /// - Returns: The hand-built profile.
    static func makeProfile(
        definitionName: String,
        chosen: ModelRef,
        container: any LoadedLLMContainer,
        router: Router,
        generationGate: AsyncSemaphore?
    ) -> LanguageModelProfile {
        let recorder = InMemoryRecorder()
        return LanguageModelProfile(
            definitionName: definitionName,
            standard: makeGenerationHandle(
                slot: .standard,
                chosen: chosen,
                container: container,
                router: router,
                recorder: recorder,
                generationGate: generationGate
            ),
            flash: makeGenerationHandle(
                slot: .flash,
                chosen: chosen,
                container: container,
                router: router,
                recorder: recorder,
                generationGate: generationGate
            ),
            embedding: RoutedEmbedder(
                slot: .embedding,
                chosen: chosen,
                footprintBytes: 0,
                resolution: slotResolution(slot: .embedding, chosen: chosen),
                container: StubEmbeddingContainer(dimension: RouterTestFixtures.stubDimension),
                routerId: router.id,
                recorder: recorder
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
    ///   - generationGate: The gate to reuse, or `nil` for a fresh gate.
    /// - Returns: The generation handle.
    private static func makeGenerationHandle(
        slot: ModelSlot,
        chosen: ModelRef,
        container: any LoadedLLMContainer,
        router: Router,
        recorder: any TranscriptRecorder,
        generationGate: AsyncSemaphore?
    ) -> RoutedLLM {
        RoutedLLM(
            slot: slot,
            chosen: chosen,
            footprintBytes: 0,
            resolution: slotResolution(slot: slot, chosen: chosen),
            container: container,
            routerId: router.id,
            recorder: recorder,
            generationGate: generationGate
        )
    }
}
