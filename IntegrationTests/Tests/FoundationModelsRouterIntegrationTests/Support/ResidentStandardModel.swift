import Foundation
import FoundationModels
import MLXFoundationModels

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The one resident standard model that the tests of
/// `StandardModelCompactionIntegrationTests` share (task ^yyjvyga).
///
/// The first test that asks for a model loads it, and each later test that
/// asks for the same model gets the same container. A test that asks for
/// another model of ``StandardModels`` evicts the resident one first, so one
/// model at a time holds memory. The suite trait evicts the model one time, as
/// the suite ends. So the compaction tests pay for one load per model change,
/// and each test costs only its own model calls.
///
/// The suite is `.serialized`, so two loads never start at the same time.
actor ResidentStandardModel {
    /// The tag of the printed load line.
    private static let label = "residentStandardModel"

    /// The one value the suite shares.
    static let shared = ResidentStandardModel()

    /// The loaded model and its reference, or `nil` before the first use and
    /// after the eviction.
    private var loaded: (ref: ModelRef, container: RealModelContainer)?

    /// The resident model `ref`. A call for a model that is not resident
    /// evicts the resident one, loads `ref` with greedy decoding, and prints
    /// the time of the load.
    ///
    /// - Parameter ref: The model.
    /// - Returns: The loaded model.
    /// - Throws: What ``RealModelContainer/load(ref:context:samplingMode:chatTemplateDate:)``
    ///   throws.
    func container(for ref: ModelRef) async throws -> RealModelContainer {
        if let loaded, loaded.ref == ref { return loaded.container }
        await evict()
        let started = ContinuousClock.now
        let container = try await RealModelContainer.load(ref: ref, samplingMode: .greedy)
        // The gated run's record of the load. This test target does not ship.
        // swiftlint:disable:next no_direct_standard_out_logs - the gated run's record; this target does not ship
        print("[\(Self.label)] \(ref.stringValue) modelLoad=\(ContinuousClock.now - started)")
        loaded = (ref, container)
        return container
    }

    /// Evicts the resident model, when one is loaded.
    func evict() async {
        await loaded?.container.evict()
        loaded = nil
    }
}
