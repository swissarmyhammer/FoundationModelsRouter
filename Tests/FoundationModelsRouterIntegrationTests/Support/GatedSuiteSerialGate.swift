import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// Process-wide mutual exclusion across every gated real-model suite in this
/// target.
///
/// Each suite here is independently `.serialized` (Swift Testing serializes
/// *within* a `@Suite`), but distinct `@Suite` types still run concurrently
/// with each other by default — every gated suite in this target is one of
/// them, and nothing previously stopped them all from resolving/loading real
/// models at the same time. With real ~15-20GB models in the
/// `.standard`/`.flash` slots (replacing the former tiny `SmolLM-135M`
/// placeholder), that concurrency is a real RAM risk. Every gated `@Test`
/// body in this target acquires this single value-1 permit for its duration,
/// making the whole gated tier serial across files, not just within one.
///
/// The permit covers this target only. `FoundationModelsRouterEvals` is a
/// separate test target — a separate module and a separate `swift test`
/// process — so it cannot see this gate, and its own gated evals are not
/// serialized against these suites.
enum GatedSuiteSerialGate {
    /// The target-wide permit every gated `@Test` body takes for its duration.
    ///
    /// Because that makes reading this property the one thing every gated test
    /// does before it loads a model, its initializer is also where
    /// ``MetalLibraryTestBootstrap`` runs — mlx-swift cannot find its shader
    /// library under a plain `swift test` until that symlink exists, and the
    /// first GPU-device `MLXArray` evaluation would abort the whole test
    /// process. `static let` runs the initializer once, before the first
    /// permit is handed out.
    static let shared: AsyncSemaphore = {
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        return AsyncSemaphore(value: 1)
    }()
}
