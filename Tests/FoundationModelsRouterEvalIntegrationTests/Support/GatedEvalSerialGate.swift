import Foundation
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Process-wide mutual exclusion across every gated real-model eval suite in
/// this target, and the guaranteed eviction that makes it hold.
///
/// ## Why a permit, and not one shared container
///
/// Every gated eval suite resolves the same ``CompactionEvalRealModel/ref``,
/// each through its own runner (``CompactionEvalRealSubjectRunner`` and
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
///   ``GatedEvalResidencyTrait`` evicts the runner's own container as its suite
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
/// a `TestScoping` trait ahead of the body. ``GatedEvalResidencyTrait`` is a
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
/// now run it from the same place: the suite-scoped trait every gated suite
/// carries. See
/// ``GatedEvalResidencyTrait/provideScope(for:testCase:performing:)``, and
/// `GatedRealModelSuiteTrait` in `FoundationModelsRouterIntegrationTests`.
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
/// `CompactionContinuityEvaluationIntegrationTests` runs under this value.
/// The two compaction fact-retention tiers state the same budget through
/// their own measured constants (`compactionEvalSubsetTimeLimitMinutes` and
/// `compactionEvalFullDatasetTimeLimitMinutes`), which
/// `CompactionEvalTierBarTests` holds against the measured per-sample costs.
/// The 20 minutes this value stated before belonged to the 30B model the eval
/// tiers no longer drive — see ``CompactionEvalRealModel``.
let gatedEvalSuiteTimeLimitMinutes = 2

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

    /// Installs the metallib symlink, then runs the suite holding
    /// ``GatedEvalSerialGate/shared``, evicting ``runner``'s model before the
    /// permit is released whether the suite succeeded or threw.
    ///
    /// This scope is the whole target's single metallib trigger. A suite scope
    /// opens before any child step exists, so it encloses every test-level
    /// trait no matter where among the suite's own traits it is written, and
    /// the symlink is in place before `.evaluates(...)` — itself a
    /// `TestScoping` trait, which runs the entire evaluation, model load
    /// included, ahead of the `@Test` body — reaches the GPU. Among the traits
    /// on one `@Suite` line the first written is the outermost, so this trait
    /// is outermost against test-level traits, not against a suite trait
    /// written before it. Triggering from a runner's own model load worked too,
    /// but only for the runners that remembered to; this trigger covers a new
    /// gated eval suite whether or not its author knows the symlink exists.
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
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        try await GatedEvalSerialGate.shared.withPermit {
            // The suite's whole wall clock, measured inside the permit so a
            // wait on another suite is not charged, and printed however the
            // run ended. This is the recorded measurement task ^k0d30s4 asks
            // every integration test to print for itself: `.evaluates(...)`
            // runs the whole evaluation ahead of the `@Test` body, so a
            // clock started in the body would measure nothing, and this
            // trait's scope is the one place that encloses the whole run.
            let startedAt = Date()
            defer {
                let seconds = Date().timeIntervalSince(startedAt)
                print(
                    "[gatedEvalSuite] suite=\(test.displayName ?? test.name) "
                        + "wallClockSeconds=\(String(format: "%.1f", seconds))")
            }
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
