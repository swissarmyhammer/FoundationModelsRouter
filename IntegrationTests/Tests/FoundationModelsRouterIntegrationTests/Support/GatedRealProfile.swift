import FoundationModelsRouterRealModelSupport

@testable import FoundationModelsRouter

/// The profile the gated suites resolve: two different real generation models
/// and a real embedder, all resident at one time, over the ``RealModels``
/// repositories.
///
/// The `standard` and `flash` slots name two different models, because the
/// two generation slots of one resolved profile never use the same model.
/// See ``RealModels/flash``. Each slot loads its own resident container, which
/// is what ``gatedRealProfileResidentContainerCount`` counts.
///
/// One definition for the whole target. ``IntegrationTests`` resolves it end to
/// end on one router. A second copy would drift from the first.
///
/// The decision slot names no candidate, so it always uses the flash model.
/// This profile tests the trio on one router. `DecisionSlotIntegrationTests`
/// tests the decision slot with a profile of its own. The default decision
/// candidate (``ProfileDefinition/defaultDecisionCandidates``) is a fourth
/// container when it fits in the memory that the trio leaves, and it does not
/// fit on each runner. Thus with the default, the count of resident containers
/// changes with the memory of the runner.
///
/// `CrossRouterPoolIntegrationTests` does not use this profile. Its two
/// routers keep all their models loaded at the same time, and these models
/// with a decision model did not fit on the runner `mini-01` (CI run
/// 43122216651). That suite resolves a profile of small models, with a
/// decision model of its own.
let gatedRealProfile = ProfileDefinition(
    name: "integration-real",
    description: "Real mlx-community models for the gated integration suite.",
    standard: [RealModels.standard],
    flash: [RealModels.flash],
    embedding: [RealModels.embedding],
    decision: [],
    context: RealModels.context
)

/// How many resident containers ``gatedRealProfile`` asks a fresh pool to load,
/// and so how many `load` spans one resolve opens on an empty pool.
///
/// Read off the resolve path, not off a measured run. `Router.acquire`
/// asks the pool before it reaches the loader, and the pool runs the loader one
/// time for each distinct residency key, not one time for each slot. A
/// generation key is the chosen reference alone, so two
/// generation slots that name one repository build one key and load one
/// container. An embedding key carries a different role, so it never merges
/// with a generation key, whatever the references are named.
///
/// The decision slot adds no container: its list is empty, so it uses the
/// flash model, and the hold of the flash slot serves its key.
var gatedRealProfileResidentContainerCount: Int {
    let generationRefs = Set([RealModels.standard, RealModels.flash])
    let embeddingRefs = Set([RealModels.embedding])
    return generationRefs.count + embeddingRefs.count
}
