import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Process-wide mutual exclusion across every gated real-model eval suite in
/// this target, and the guaranteed eviction that makes it hold.
///
/// ## Why a permit, and not one shared container
///
/// A gated eval suite resolves a real model through its own runner, and that
/// runner caches its own container. The continuity tier resolves
/// ``CompactionContinuityRealModel/ref`` through
/// ``CompactionContinuityEvalRealSubjectRunner``. Distinct `@Suite` types run
/// concurrently by default in Swift Testing. Thus, without this gate, two
/// suites could keep two containers resident at the same time, and generate
/// through them at the same time. The model was the ~15-20GB 30B when this
/// gate was built. The double-residency and eviction arguments also apply to
/// a smaller model.
///
/// One suite declares a permit now: the continuity tier. The permit bounds
/// any number of suites, so a suite that is added later is also bounded.
///
/// Three mechanisms could prevent double residency. Only one of them is
/// available here:
///
/// - **One shared container** would make double residency impossible by
///   construction. It is rejected for eviction, not for decoding. Each suite's
///   `.exclusiveResidentModel(of:)` evicts the container of that suite's own
///   runner when the suite ends. A container that two suites share belongs to
///   neither suite. The first suite to end would evict the model while the
///   second suite uses it. A container that no suite owns is never evicted, so
///   the whole model stays resident for the whole process.
///
///   Decoding is not a reason to reject a shared container. The mode is per
///   call, not per container (`model-pool.md` §2.5). The container stores no
///   `samplingMode`, and each `makeSession(...samplingMode:)` call names the
///   strategy of the backend that it makes. Thus one container can serve two
///   strategies at the same time. ``CompactionContinuityEvalRealSubjectRunner``
///   pins `.greedy`, because the provider default samples at temperature 0.6
///   from MLX's clock-seeded process-global PRNG. That default made the eval's
///   score a coin flip across runs of identical code. The gate stays for the
///   GPU: the eviction argument above rejects one shared container, not the
///   mode.
/// - **`.serialized`** cannot close it at all. Swift Testing's parallelization
///   trait serializes *within* a `@Suite`; two different suites still overlap.
///   That is the same sentence
///   `FoundationModelsRouterIntegrationTests`'s own `GatedSuiteSerialGate`
///   records, and each eval suite holds exactly one `@Test` anyway.
/// - **A target-wide value-1 permit** is what is left, and it mirrors the
///   house pattern that target already uses.
///
/// ## Why the permit is taken at suite scope
///
/// A permit taken inside a `@Test` body would be taken too late: `.evaluates(...)`
/// runs the whole evaluation — every sample, and therefore the model load — in
/// a `TestScoping` trait ahead of the body. ``GatedRealModelSuiteTrait`` is a
/// `SuiteTrait` instead, so its scope opens on the suite's own plan step,
/// before any child step exists, and encloses every test-level trait no matter
/// where among the suite's own traits it is written. Written order decides
/// nesting only among the traits on one declaration, where the first written
/// is the outermost.
///
/// That scope is also what makes eviction unconditional. The trait evicts on
/// the success path and on the throwing path alike, before it hands the permit
/// back, so the next suite can never acquire the permit while the previous
/// suite's model is still resident. Eviction from inside a `@Test` body gave
/// neither guarantee: the body does not run at all when the `.evaluates(...)`
/// trait itself throws, and an early `try` inside it skips the rest.
///
/// ## How a suite of this target is selected
///
/// By the TARGET, and by nothing else. No suite here reads an environment
/// variable and none carries an `.enabled(if:)`.
/// `FoundationModelsRouterIntegrationTests` shares the
/// `IntegrationTests` suffix with this target's name, so one
/// `--filter` asks for both and one `--skip` leaves both out — see
/// `GatedSuiteSerialGate` for those two commands and for the guard that fails a
/// run whose selectors matched nothing.
///
/// The everyday real-model run asks for the nested package whole and skips
/// nothing.
///
/// ## Relationship to the integration target's gate
///
/// This permit covers this target only, and the sibling permit covers that one
/// only — `FoundationModelsRouterIntegrationTests` is a separate module in a
/// separate `swift test` process, so neither gate can see the other, and
/// ``MetalLibraryTestBootstrap`` has to run once in each of them. Both targets
/// now run it from the same place, and from one shared type: the suite-scoped
/// ``GatedRealModelSuiteTrait``, which each target binds to its own permit —
/// this target through `.exclusiveResidentModel(of:)` below, the other through
/// its own `.exclusiveRealModel`. See
/// ``GatedRealModelSuiteTrait/provideScope(for:testCase:performing:)``.
enum GatedEvalSerialGate {
    /// The target-wide permit every gated eval suite holds for its duration.
    static let shared = AsyncSemaphore(value: 1)
}

/// A gated eval's real-model runner, as its suite's trait drives it.
protocol GatedEvalRealModelRunner: Sendable {
    /// Evicts the resident model, if one was ever loaded.
    func evictIfLoaded() async
}

// MARK: - The trait every gated eval suite carries

/// The tag every wall-clock line of this target carries, so one `grep` collects
/// the whole run's measurements.
///
/// Its own tag rather than the sibling target's, because the two targets
/// measure different things: a whole suite here, one test there.
private let evalMeasurementLabel = "gatedEvalSuite"

extension Trait where Self == GatedRealModelSuiteTrait {
    /// Gives this suite exclusive residency of its real model for its whole
    /// run, installs the metallib symlink before the suite runs, prints the
    /// suite's own wall clock, and evicts `runner`'s model when the suite ends.
    ///
    /// The trait itself is ``GatedRealModelSuiteTrait``, in
    /// `FoundationModelsRouterTestSupport`, which the sibling integration
    /// target carries as well. This function is what binds that one trait to
    /// THIS target's permit, THIS target's tag, and this suite's own runner —
    /// see ``GatedEvalSerialGate`` for why the exclusion is a permit rather
    /// than a shared container, and why it is held at suite scope rather than
    /// inside the `@Test` body.
    ///
    /// The clock is per suite rather than per test. Each suite of this target
    /// holds exactly one `@Test`, and `.evaluates(...)` runs the whole
    /// evaluation ahead of that test's body, so the suite's clock IS the test's
    /// clock and a clock started in the body would measure nothing.
    ///
    /// - Parameter runner: The suite's real-model runner, whose model is
    ///   evicted as the suite ends, however it ended, before the permit is
    ///   handed back.
    /// - Returns: The trait.
    static func exclusiveResidentModel(of runner: any GatedEvalRealModelRunner) -> Self {
        GatedRealModelSuiteTrait(
            measurementLabel: evalMeasurementLabel,
            measuring: .wholeSuite,
            holding: GatedEvalSerialGate.shared,
            whenSuiteEnds: { await runner.evictIfLoaded() }
        )
    }
}
