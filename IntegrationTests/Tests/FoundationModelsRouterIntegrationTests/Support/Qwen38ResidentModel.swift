import Foundation
import FoundationModels

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The one load of Qwen 3.8 27B that the tests of
/// `Qwen38CompactionIntegrationTests` share (task ^yyjvyga).
///
/// The first test that asks for the model loads it, and each later test of
/// the suite gets the same container. The suite trait evicts the model one
/// time, as the suite ends. So the three compaction tests pay for one load,
/// and each test costs only its own model calls.
///
/// The suite is `.serialized`, so two loads never start at the same time.
actor Qwen38ResidentModel {
    /// The model: the product's standard model, Qwen 3.8 27B in the `mxfp4`
    /// quantization.
    static let ref: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"

    /// The tag of the printed load line.
    private static let label = "qwen38ResidentModel"

    /// The one value the suite shares.
    static let shared = Qwen38ResidentModel()

    /// The loaded model, or `nil` before the first use and after the eviction.
    private var loaded: RealModelContainer?

    /// The resident model. The first call loads it with greedy decoding and
    /// prints the time of the load.
    ///
    /// - Returns: The loaded model.
    /// - Throws: What ``RealModelContainer/load(ref:context:samplingMode:chatTemplateDate:)``
    ///   throws.
    func container() async throws -> RealModelContainer {
        if let loaded { return loaded }
        let started = ContinuousClock.now
        let container = try await RealModelContainer.load(ref: Self.ref, samplingMode: .greedy)
        // The gated run's record of the load. This test target does not ship.
        // swiftlint:disable:next no_direct_standard_out_logs - the gated run's record; this target does not ship
        print("[\(Self.label)] modelLoad=\(ContinuousClock.now - started)")
        loaded = container
        return container
    }

    /// Evicts the resident model, when one is loaded.
    func evict() async {
        await loaded?.container.model.evict()
        loaded = nil
    }
}
