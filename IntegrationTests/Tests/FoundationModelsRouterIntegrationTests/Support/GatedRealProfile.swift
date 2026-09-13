import FoundationModelsRouterRealModelSupport

@testable import FoundationModelsRouter

/// The profile the gated suites resolve: a real generation model in both
/// generation slots and a real embedder, all resident at one time, over the
/// ``RealModels`` repositories.
///
/// Both generation slots name one repository, because only one Muse Glimmer
/// repository is published. See ``RealModels/flash``. The two slots share one
/// resident container, which is what ``gatedRealProfileResidentContainerCount``
/// counts.
///
/// One definition for the whole target. ``IntegrationTests`` resolves it end to
/// end, and ``CrossRouterPoolIntegrationTests`` resolves it from two routers
/// over one pool. A second copy would drift from the first.
let gatedRealProfile = ProfileDefinition(
    name: "integration-real",
    description: "Real mlx-community models for the gated integration suite.",
    standard: [RealModels.standard],
    flash: [RealModels.flash],
    embedding: [RealModels.embedding],
    context: RealModels.context
)

/// How many resident containers ``gatedRealProfile`` asks a fresh pool to load,
/// and so how many `load` spans one resolve opens on an empty pool.
///
/// Read off the resolve path, not off a measured run. `Router.acquireModel`
/// asks the pool before it reaches the loader, and the pool runs the loader one
/// time for each distinct residency key, not one time for each slot. A
/// generation key is the chosen reference alone (`model-pool.md` §2.3), so two
/// generation slots that name one repository build one key and load one
/// container. An embedding key carries a different role, so it never merges
/// with a generation key, whatever the references are named.
var gatedRealProfileResidentContainerCount: Int {
    let generationRefs = Set([RealModels.standard, RealModels.flash])
    let embeddingRefs = Set([RealModels.embedding])
    return generationRefs.count + embeddingRefs.count
}
