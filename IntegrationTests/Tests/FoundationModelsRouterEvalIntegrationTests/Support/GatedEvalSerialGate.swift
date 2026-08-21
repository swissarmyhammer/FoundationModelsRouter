import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Process-wide mutual exclusion across every gated real-model eval suite in
/// this target, and the guaranteed eviction that makes it hold.
///
/// ## Why a permit, and not one shared container
///
/// Every gated eval suite resolves a real model — the fact-retention tiers
/// ``CompactionEvalRealModel/ref``, the continuity tier
/// ``CompactionContinuityRealModel/ref`` — each through its own runner
/// (``CompactionEvalRealSubjectRunner`` and
/// ``CompactionContinuityEvalRealSubjectRunner``), and each caching its own
/// container. Distinct `@Suite` types run concurrently by default in Swift
/// Testing, so before this gate both containers could be resident at once —
/// two copies of one model in one process, and two suites generating through
/// them at once. The model was the ~15-20GB 30B when this gate was built;
/// the double-residency and eviction arguments hold for the small model just
/// the same.
///
/// Three suites declare one, and the everyday command steps the whole-dataset
/// fact-retention tier aside (`--skip CompactionEvalFullDataset`), so two
/// normally run in one process. The permit bounds any number of them, and a run
/// that asks for all three is bounded just the same.
///
/// Three mechanisms could close that, and only one of them is available here:
///
/// - **One shared container** would make double residency impossible by
///   construction, and it is rejected anyway — for eviction, not for decoding.
///   Every suite's `.exclusiveResidentModel(of:)` evicts that suite's own
///   runner's container as the suite
///   ends, and a container two suites share belongs to neither: the first suite
///   to end would evict the model out from under the second, and a container
///   nobody owns is never evicted at all, so the whole model stays resident
///   for the whole process.
///
///   Decoding used to be the reason stated here, and it no longer separates the
///   two. `samplingMode` is stored *on* the container (`LiveModelLoader` builds
///   `MLXFoundationModelsContainer(model:samplingMode:)`) and every session
///   opened over that container inherits it, so one container cannot carry two
///   strategies. ``CompactionContinuityEvalRealSubjectRunner`` has always pinned
///   `.greedy`, because the provider default samples at temperature 0.6 from
///   MLX's clock-seeded process-global PRNG and made that eval's score a coin
///   flip across runs of identical code, and
///   ``CompactionEvalRealSubjectRunner`` now pins it for the same measured
///   reason (task ^xscp198). Both runners want the same strategy today; the
///   eviction argument above is what still rejects one shared container.
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
/// One selector is this target's alone. The whole-dataset fact-retention tier
/// measures a superset of the subset tier's seeds, so an
/// everyday real-model run steps it aside with
/// `--skip CompactionEvalFullDataset`, and a run that wants it names it with
/// `swift test --filter CompactionEvalFullDataset`.
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

/// The wall-clock ceiling a gated eval suite's `@Test` runs under.
///
/// Two minutes is task ^k0d30s4's budget for every integration test, stated
/// as the limit so a test past the budget FAILS rather than merely being
/// slow. Swift Testing measures a time limit in whole minutes, and applies a
/// suite's limit to each `@Test` inside it rather than to the suite as a
/// whole, so the time a suite spends waiting on ``GatedEvalSerialGate/shared``
/// is not charged against it.
///
/// `CompactionContinuityEvaluationIntegrationTests` runs under this value,
/// against ``CompactionContinuityRealModel`` — its measured wall clocks are
/// 26.2 to 41.4 seconds under the 1B model, where the Qwen2.5-3B canary the
/// fact-retention tiers moved to measured 219.1 seconds on 2026-08-20, past
/// this budget, which is why the continuity tier keeps its own model (task
/// ^m03heaa). The two compaction fact-retention tiers state their own limits
/// through their own measured constants
/// (`compactionEvalSubsetTimeLimitMinutes` and
/// `compactionEvalFullDatasetTimeLimitMinutes`), which
/// `CompactionEvalTierBarTests` holds against the measured per-sample costs.
/// The 20 minutes this value stated before belonged to the 30B model the eval
/// tiers no longer drive.
let gatedEvalSuiteTimeLimitMinutes = 2

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
