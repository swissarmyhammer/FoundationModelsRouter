import FoundationModelsRouterTestSupport
import Testing

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
/// placeholder), that concurrency is a real RAM risk. Every gated suite in
/// this target holds this single value-1 permit for its duration, making the
/// whole gated tier serial across files, not just within one.
///
/// The permit covers this target only. `FoundationModelsRouterEvalIntegrationTests`
/// is a separate test target — a separate module and a separate `swift test`
/// process — so it cannot see this gate, and its own real-model evals are not
/// serialized against these suites.
///
/// The gated suites of this target have no time limit. A gated run ends when
/// it ends, or when the caller stops it. A limit that cancels a test
/// mid-generation can abort the whole process on a Metal assertion (fork card
/// ^3axg80k).
///
/// ## How a suite of this target is selected
///
/// By the PACKAGE, and by nothing else. No suite here reads an environment
/// variable and none carries an `.enabled(if:)`. This target lives in the
/// nested `IntegrationTests/` package, which the root package does not
/// declare, so a suite that is selected runs and a suite that is not
/// selected is not built into the run at all:
///
/// - `swift test` at the repository root is the everyday hermetic run, and
///   it cannot see this package.
/// - `swift test --package-path IntegrationTests` runs this target and
///   `FoundationModelsRouterEvalIntegrationTests`, and it is what CI runs.
/// - `swift test --package-path IntegrationTests --filter 'CompactionSmokeIntegrationTests|AutoCompactionTriggerIntegrationTests|RecordedTranscriptCompactionIntegrationTests'`
///   runs the three compaction smoke suites alone — the seconds-long tier that
///   answers "does compaction work at all against a real model" without the
///   other real-model suites beside it.
/// - `swift test --package-path IntegrationTests --filter Qwen38CompactionIntegrationTests`
///   runs the three compaction cases on Qwen 3.8 27B alone, over one load of
///   the model: one compaction of a built context, a tool result that
///   triggers a compaction inside its answer, and a context over the trigger
///   that compacts at the start of an answer.
///
/// The package boundary needs no guard script: a run of this package executes
/// every suite in it, so a green run always measured something.
enum GatedSuiteSerialGate {
    /// The target-wide permit every gated suite holds for its duration.
    ///
    /// Taken and released by ``GatedRealModelSuiteTrait``, never by a `@Test`
    /// body: a body that took it again while its own suite still held it would
    /// deadlock on this value-1 permit.
    static let shared = AsyncSemaphore(value: 1)
}

// MARK: - The trait every gated suite of this target carries

/// The tag every wall-clock line of this target carries, so one `grep` collects
/// the whole run's measurements.
///
/// Its own tag rather than the sibling target's, because the two targets
/// measure different things: one test here, a whole suite there.
private let integrationMeasurementLabel = "gatedTest"

extension Trait where Self == GatedRealModelSuiteTrait {
    /// Serializes this suite against every other gated real-model suite in the
    /// target, installs the metallib symlink before the suite runs, and prints
    /// each of the suite's tests' own wall clock.
    ///
    /// The trait itself is ``GatedRealModelSuiteTrait``, in
    /// `FoundationModelsRouterTestSupport`, which the sibling eval target
    /// carries as well. This property is what binds that one trait to THIS
    /// target's permit and THIS target's tag — read the type for why the two
    /// targets keep separate permits, and for why the whole job sits in a
    /// suite-scoped trait rather than in the test bodies.
    ///
    /// The clock is per test rather than per suite. A suite of this target
    /// holds many tests, so a per-test clock shows which test costs the time.
    /// This trait asks for no teardown as the suite ends: each `@Test` body
    /// of a suite that carries it evicts whatever it loaded for itself. A
    /// suite that shares one load across its tests carries
    /// ``exclusiveRealModel(whenSuiteEnds:)`` instead.
    ///
    /// - Returns: The trait.
    static var exclusiveRealModel: Self {
        exclusiveRealModel(whenSuiteEnds: nil)
    }

    /// The same trait as ``exclusiveRealModel``, with a teardown that runs as
    /// the suite ends.
    ///
    /// A suite whose tests share one resident model evicts that model here,
    /// before the permit goes to the next suite. The eviction then runs one
    /// time for the suite, however the suite ended.
    ///
    /// - Parameter whenSuiteEnds: The teardown of the suite, or `nil` for none.
    /// - Returns: The trait.
    static func exclusiveRealModel(whenSuiteEnds: (@Sendable () async -> Void)?) -> Self {
        GatedRealModelSuiteTrait(
            measurementLabel: integrationMeasurementLabel,
            measuring: .eachTest,
            holding: GatedSuiteSerialGate.shared,
            whenSuiteEnds: whenSuiteEnds
        )
    }
}
