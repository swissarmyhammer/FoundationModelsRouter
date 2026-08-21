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

// MARK: - The budget

/// The wall clock every `@Test` of this target runs under, in minutes.
///
/// Two minutes is task ^k0d30s4's budget for every integration test, stated as
/// the limit so a test past the budget FAILS rather than merely being slow.
/// Every suite of this target reads this one value, so the budget cannot hold
/// for some suites and not for others, and a suite cannot buy itself more time
/// by stating a limit of its own. The sibling target states the same budget in
/// `gatedEvalSuiteTimeLimitMinutes`.
///
/// Swift Testing measures a time limit in whole minutes, and applies a suite's
/// limit to each `@Test` inside it rather than to the suite as a whole — so
/// this is a per-test bound, which is what the budget asks for, and the time a
/// suite spends waiting on ``GatedSuiteSerialGate/shared`` is not charged
/// against it.
///
/// ## What the three runs of 2026-08-20 measured
///
/// Every `@Test` of this target, in three whole runs on one Apple silicon box
/// with every model already in the Hugging Face cache. Run 1 stands before this
/// task's conversion of the compaction round trip, run 2 after it, and run 3 is
/// the shipped configuration — `swift test --package-path IntegrationTests
/// --skip CompactionEvalFullDataset`, the command CI runs, under this budget.
///
/// Three runs rather than one, because one run states no spread and this target
/// has a wide one. Most suites here take the provider's default sampling —
/// temperature 0.6 out of MLX's clock-seeded PRNG — so the `<think>` block the
/// 30B writes ahead of each answer is a different length on every run, and the
/// wall clock is different with it. The three columns below are the same code
/// on the same box.
///
/// Runs 1 and 2 are read off Swift Testing's own per-test lines, because
/// ``GatedRealModelSuiteTrait`` did not print yet. Run 3 is read off that
/// trait's own lines, which is what the budget is measured against from here
/// on — so the table can be measured again without a stopwatch.
///
/// | run 1 | run 2 | run 3 | test |
/// |---|---|---|---|
/// | 94.1 | 114.1 | 116.4 | a whole fork tree recorded, torn down, and restored by root id |
/// | 16.7 | 40.9 | 101.5 | a tool-using turn over a RecordingLanguageModel handle |
/// | 86.7 | 85.3 | 85.8 | a real tool-using turn delivers its own tools' data, on each surface |
/// | 40.3 | 48.3 | 58.6 | a second respond() call on the same backend sees the first turn |
/// | 54.4 | 61.7 | 58.5 | restoreSessionTree(tools:) gives a restored session real tool-calling |
/// | 45.7 | 27.9 | 46.5 | makeSession(transcript:) seeds a fresh backend |
/// | 46.6 | 48.7 | 44.9 | resolve real profile, then generate, embed, guide, fork, and record |
/// | 48.7 | 40.4 | 41.8 | turn 2's usage.input.cachedTokenCount is positive |
/// | 41.9 | 41.1 | 41.0 | the real transcript has the same entry kinds the scripted scenario produces |
/// | 28.8 | 62.3 | 39.7 | makeFork() seeds the child's transcript from the parent's |
/// | 67.2 | 27.4 | 24.4 | MLX path: whether the ToolContext bound around respond() arrives |
/// | 19.0 | 15.0 | 23.0 | recorded entry kinds match after a live streaming turn |
/// | 23.3 | 30.0 | 21.7 | each respond() call leaves exactly one prompt entry and one response |
/// | 19.2 | 20.0 | 21.6 | transcriptEntries().count equals session.transcript.count |
/// | 19.5 | 17.2 | 20.3 | recorded entry kinds match the real session.transcript kinds |
/// | 16.6 | 21.0 | 19.3 | recorded tokensIn/tokensOut on the turn's response event |
/// | 14.6 | 15.2 | 18.6 | one fold against a real model |
/// | 16.0 | 20.4 | 17.9 | a fork taken after one turn begins holding exactly that turn's entries |
/// | 19.1 | 16.6 | 17.5 | turn 2 tends to be faster than turn 1 |
/// | 541.6 | 17.4 | 17.3 | contextFill climbs, compact() folds at the 0.80 trigger |
/// | 19.7 | 24.1 | 17.1 | reconstructed Transcript entry kinds and count match |
/// | 17.5 | 9.4 | 17.0 | a live LanguageModelSession rebuilt over a transcript |
/// | 18.8 | 19.3 | 14.5 | a fact planted at the very end of the folded span |
/// | 12.1 | 11.7 | 12.2 | one fold of the recorded transcript against a real model |
/// | 5.8 | 5.7 | 5.7 | a generation cancelled mid-decode unwinds as CancellationError |
/// | 5.2 | 5.1 | 5.1 | a session vended with a synthetic trigger folds inside its own turn |
/// | 2.1 | 2.3 | 2.1 | system-model path: whether the ToolContext bound around respond() arrives |
/// | 0.012 | 0.011 | 0.0 | the recorded transcript still carries the entry kinds real traffic has |
/// | 0.001 | 0.001 | 0.0 | a GPU-device MLXArray evaluation completes |
///
/// ## What the table says about the margin
///
/// The one test that did NOT fit is the compaction round trip, at 541.6
/// seconds — 4.5 times this budget. It is the test this task converted, and it
/// costs 17.3 to 17.4 seconds now; see `CompactionRoundTripIntegrationTests`
/// for what the conversion no longer proves.
///
/// Every test of all three runs fits, and two of them fit by little. The
/// fork-tree restoration measured 94.1, then 114.1, then 116.4 seconds — 97
/// percent of this budget — and the `RecordingLanguageModel` handle round trip
/// measured 16.7, then 40.9, then 101.5, which is six times its own first
/// measurement with no code change between the three. Those two are the tests a
/// slower box or a longer `<think>` block pushes past the limit first, and the
/// spread above says a run alone decides which. Task ^bpwfbyz carries their
/// conversion.
///
/// A test the limit cancels is worse than a plain red: the cancellation lands
/// mid-generation, and a cancellation on GPU work aborts the whole process on a
/// Metal assertion (fork card ^3axg80k), taking every other suite's results
/// with it. That is why the margin is stated here rather than left to be
/// discovered.
let integrationTestBudgetMinutes = 2

/// Gives one gated real-model suite exclusive residency for its whole run,
/// installs the metallib symlink every suite in this target needs before it
/// touches the GPU, and prints each of the suite's tests' own wall clock.
///
/// ## Why the wall clock is printed here
///
/// Task ^k0d30s4 asks every integration test to print its own measurement, so
/// a regression against ``integrationTestBudgetMinutes`` is visible without a
/// stopwatch. Printing it from this trait rather than from each `@Test` body
/// is the same argument the metallib symlink makes below: a suite that gains a
/// test gains the measurement with it, and a body that forgets the line cannot
/// go unmeasured. A body's own clock would also miss whatever a test-level
/// trait spends ahead of the body.
///
/// ## Why both concerns sit in one suite-scoped trait
///
/// Both used to rest on convention: every gated `@Test` body opened by reading
/// ``GatedSuiteSerialGate/shared``, which took the permit and — through that
/// property's initializer — installed the symlink. Twenty test bodies all
/// remembered to, and nothing enforced it. A new gated `@Test` written without
/// that line did not fail an assertion: mlx-swift cannot find its shader
/// library under a plain `swift test` until the symlink exists, so the first
/// GPU-device `MLXArray` evaluation aborted the whole test process, taking
/// every other suite's results with it, under an error naming mlx rather than
/// the missing line. A `SuiteTrait` written once per `@Suite` cannot be
/// forgotten by a test the suite later gains.
///
/// ## Ordering against test-level traits
///
/// A `SuiteTrait`'s scope opens on the suite's own plan step, before any child
/// step exists, so it encloses every test-level trait no matter where among
/// the suite's own traits it is written. That matters for any trait that
/// reaches the GPU ahead of the `@Test` body — `.evaluates(...)` in
/// `FoundationModelsRouterEvals` is exactly such a trait, which is why its
/// sibling ``GatedEvalResidencyTrait`` is suite-scoped too. Nothing in this
/// target carries such a trait today; being suite-scoped means nothing here
/// has to.
///
/// That freedom covers the suite/test boundary only. Written order still
/// decides nesting *within* one declaration's own trait list, where the first
/// trait written is the outermost — so a second suite trait that itself
/// reached the GPU would have to be written after this one on the `@Suite`
/// line to run inside its scope.
struct GatedRealModelSuiteTrait: SuiteTrait, TestTrait, TestScoping {
    /// The tag every wall-clock line of this target carries, so one `grep`
    /// collects the whole run's measurements.
    private static let measurementLabel = "gatedTest"

    /// Applies this trait to each `@Test` of the suite as well as to the suite
    /// itself.
    ///
    /// A `SuiteTrait` is asked for a scope on its own suite's step only, unless
    /// it says so here. The permit wants the suite's step and nothing more, but
    /// the wall clock this trait prints is a PER-TEST measurement — the budget
    /// is per test, and Swift Testing charges `.timeLimit` per test — so the
    /// trait has to reach each test's own step to measure it. Measured on
    /// 2026-08-20: with this left at its default of `false` the trait ran on
    /// the suite alone, and the whole target printed no measurement at all.
    ///
    /// A recursive `SuiteTrait` has to conform to `TestTrait` as well, and that
    /// is a hard requirement rather than a matter of taste: `SuiteTrait` alone
    /// plus this override traps the run inside
    /// `Runner.Plan._recursivelyApplyTraits(_:to:)` on `SIGTRAP`, before any
    /// test starts and with no diagnostic. The conformance is what lets the
    /// plan carry the trait down onto a test.
    var isRecursive: Bool { true }

    /// Provides the scope for the suite's own step and for each of its tests'
    /// own steps, and for no test CASE's step.
    ///
    /// The two scopes it does provide do different work — see
    /// ``provideScope(for:testCase:performing:)``. A test case's step is left
    /// alone because no `@Test` of this target is parameterized: each holds
    /// exactly one case, so a scope there would print the same measurement a
    /// second time.
    ///
    /// - Parameters:
    ///   - test: The test the trait is deciding a scope for.
    ///   - testCase: The test case, if this is a test case's own step rather
    ///     than a suite's or a test's.
    /// - Returns: This trait for a suite's or a test's own step, or `nil` for a
    ///   test case's.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? self : nil
    }

    /// Runs one step: the suite itself under the permit, or one of its tests
    /// under a clock.
    ///
    /// The SUITE's step installs the metallib symlink and takes
    /// ``GatedSuiteSerialGate/shared``. That scope is the whole target's single
    /// metallib trigger, and the single place its permit is taken.
    ///
    /// A TEST's step takes no permit — its suite already holds one, and this
    /// value-1 permit taken a second time inside itself would deadlock — and
    /// prints the test's own wall clock however the test ended, so a run past
    /// ``integrationTestBudgetMinutes`` states what it cost as well as failing.
    ///
    /// - Parameters:
    ///   - test: The suite or the test this step belongs to.
    ///   - testCase: Always `nil` here; ``scopeProvider(for:testCase:)``
    ///     provides no per-test-case scope.
    ///   - function: The step's own work.
    /// - Throws: Whatever `function` throws, rethrown once the permit is back
    ///   and the measurement is printed.
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        guard test.isSuite else {
            try await GatedWallClock.printing(
                label: Self.measurementLabel,
                subject: "test=\(test.displayName ?? test.name)"
            ) {
                try await function()
            }
            return
        }
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        try await GatedSuiteSerialGate.shared.withPermit {
            try await function()
        }
    }
}

extension Trait where Self == GatedRealModelSuiteTrait {
    /// Serializes this suite against every other gated real-model suite in the
    /// target, installs the metallib symlink before the suite runs, and prints
    /// each of the suite's tests' own wall clock.
    ///
    /// - Returns: The trait.
    static var exclusiveRealModel: Self {
        GatedRealModelSuiteTrait()
    }
}
