import Testing

@testable import FoundationModelsRouter

/// Process-wide mutual exclusion across every gated real-model eval suite in
/// this target, and the guaranteed eviction that makes it hold.
///
/// ## Why a permit, and not one shared container
///
/// The two gated eval suites resolve the same ~15-20GB
/// ``CompactionEvalRealModel/ref``, each through its own runner
/// (``CompactionEvalRealSubjectRunner`` and
/// ``CompactionContinuityEvalRealSubjectRunner``), and each caching its own
/// container. Distinct `@Suite` types run concurrently by default in Swift
/// Testing, so before this gate both containers could be resident at once —
/// two copies of the same 27B model in one process.
///
/// Three mechanisms could close that, and only one of them is available here:
///
/// - **One shared container** would make double residency impossible by
///   construction, and it is rejected anyway. `samplingMode` is stored *on*
///   the container (`LiveModelLoader` builds
///   `MLXFoundationModelsContainer(model:samplingMode:)`) and every session
///   opened over that container inherits it.
///   ``CompactionContinuityEvalRealSubjectRunner`` deliberately pins
///   `.greedy`, because the provider default samples at temperature 0.6 from
///   MLX's clock-seeded process-global PRNG and made that eval's score a coin
///   flip across runs of identical code; ``CompactionEvalRealSubjectRunner``
///   deliberately leaves the provider default in place. One container cannot
///   carry both decoding strategies, so sharing one would silently re-measure
///   one of the two evals.
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
/// a `TestScoping` trait ahead of the body. ``GatedEvalResidencyTrait`` is a
/// `SuiteTrait` instead, so its scope wraps the suite's entire plan step and
/// sits outside every test-level trait, whatever order the traits are written
/// in.
///
/// That scope is also what makes eviction unconditional. The trait evicts on
/// the success path and on the throwing path alike, before it hands the permit
/// back, so the next suite can never acquire the permit while the previous
/// suite's model is still resident. Eviction from inside a `@Test` body gave
/// neither guarantee: the body does not run at all when the `.evaluates(...)`
/// trait itself throws, and an early `try` inside it skips the rest.
///
/// ## Relationship to the integration target's gate
///
/// This permit covers this target only, and the sibling permit covers that one
/// only — `FoundationModelsRouterEvals` is a separate module in a separate
/// `swift test` process, so neither gate can see the other. Unlike
/// `GatedSuiteSerialGate`, this gate's initializer does not run
/// ``MetalLibraryTestBootstrap``: each eval runner already installs that
/// symlink at its own GPU entry point, inside the model load itself.
enum GatedEvalSerialGate {
    /// The target-wide permit every gated eval suite holds for its duration.
    static let shared = AsyncSemaphore(value: 1)
}

/// The wall-clock ceiling each gated eval suite's `@Test` runs under.
///
/// Matches `CompactionRoundTripIntegrationTests`, the gated integration suite
/// that loads the same ``CompactionEvalRealModel/ref`` into the `.standard`
/// slot and drives multi-turn compaction through it. Swift Testing measures a
/// time limit in whole minutes, and applies a suite's limit to each `@Test`
/// inside it rather than to the suite as a whole, so the time a suite spends
/// waiting on ``GatedEvalSerialGate/shared`` is not charged against it.
let gatedEvalSuiteTimeLimitMinutes = 20

/// A gated eval's real-model runner, as ``GatedEvalResidencyTrait`` drives it.
protocol GatedEvalRealModelRunner: Sendable {
    /// Evicts the resident model, if one was ever loaded.
    func evictIfLoaded() async
}

/// Gives one gated eval suite exclusive residency of the real model for its
/// whole run, then evicts that model however the run ended.
///
/// See ``GatedEvalSerialGate`` for why the exclusion is a permit rather than a
/// shared container, and why it is held at suite scope rather than inside the
/// `@Test` body.
struct GatedEvalResidencyTrait: SuiteTrait, TestScoping {
    /// The runner whose resident model this suite owns while it holds the
    /// permit, and which is evicted before the permit is handed back.
    let runner: any GatedEvalRealModelRunner

    /// Provides the scope for the suite itself, and for nothing else.
    ///
    /// Stated rather than inherited: a scope provided per test case as well
    /// would take the same value-1 permit a second time while the suite still
    /// held it, and deadlock.
    ///
    /// - Parameters:
    ///   - test: The test the runner is deciding a scope for.
    ///   - testCase: The test case, if `test` is a function rather than a
    ///     suite. Unused — the suite is the only scope this trait provides.
    /// - Returns: This trait when `test` is the suite, or `nil` otherwise.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? self : nil
    }

    /// Runs the suite holding ``GatedEvalSerialGate/shared``, evicting
    /// ``runner``'s model before the permit is released whether the suite
    /// succeeded or threw.
    ///
    /// - Parameters:
    ///   - test: The suite being run.
    ///   - testCase: Always `nil` here; ``scopeProvider(for:testCase:)``
    ///     provides no per-test-case scope.
    ///   - function: The suite's own work.
    /// - Throws: Whatever `function` throws, rethrown after the model has been
    ///   evicted.
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await GatedEvalSerialGate.shared.withPermit {
            let outcome: Result<Void, any Error>
            do {
                try await function()
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await runner.evictIfLoaded()
            try outcome.get()
        }
    }
}

extension Trait where Self == GatedEvalResidencyTrait {
    /// Serializes this suite against every other gated eval suite in the
    /// target, and evicts its real model when the suite ends.
    ///
    /// - Parameter runner: The suite's real-model runner.
    /// - Returns: The trait.
    static func exclusiveResidentModel(of runner: any GatedEvalRealModelRunner) -> Self {
        GatedEvalResidencyTrait(runner: runner)
    }
}
