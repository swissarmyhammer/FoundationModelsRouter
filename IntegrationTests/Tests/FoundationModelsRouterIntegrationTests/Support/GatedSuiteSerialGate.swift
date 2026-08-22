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
/// Every suite of this target that loads a model reads this one value, so no
/// such suite can buy itself more time by stating a limit of its own. The
/// sibling target states the same budget in `gatedEvalSuiteTimeLimitMinutes`.
///
/// One suite states a limit of its own, and it is STRICTER than this value:
/// `MetalLibraryBootstrapIntegrationTests` runs under a
/// `metalLibraryBootstrapTimeLimitMinutes` of 1, because it downloads nothing
/// and adds four integers — the three runs below measured it at 0.001, 0.001
/// and 0.0 seconds. A suite may hold itself to less than the budget; the rule
/// this value carries is that none may hold itself to more.
///
/// Swift Testing measures a time limit in whole minutes, and applies a suite's
/// limit to each `@Test` inside it rather than to the suite as a whole — so
/// this is a per-test bound, which is what the budget asks for, and the time a
/// suite spends waiting on ``GatedSuiteSerialGate/shared`` is not charged
/// against it.
///
/// ## What the seven runs measured
///
/// Every `@Test` of this target, in seven whole runs on one Apple silicon box
/// with every model already in the Hugging Face cache. Runs 1 to 3 are the
/// three runs of 2026-08-20. Run 1 stands before task ^k0d30s4's conversion of
/// the compaction round trip, run 2 after it, and run 3 is the configuration of
/// that day — `swift test --package-path IntegrationTests` with the
/// whole-dataset eval tier stepped aside by name, under this budget. Task
/// ^k0d30s4 has since deleted that tier, so the command CI runs is now the
/// nested package whole. Runs 4 and 5 are the two runs of 2026-08-21 of that
/// whole package, after task ^bpwfbyz converted the two tests that ran nearest
/// the budget: `SessionTreeRestorationIntegrationTests` and
/// `RecordingHandleIntegrationTests`, each of which states what its conversion
/// no longer proves. Runs 6 and 7 are the two runs later that day, after task
/// ^6ww73dm converted `RealToolTurnComparisonTests`, the test that then ran
/// nearest the budget; that suite states what its conversion no longer proves.
///
/// Several runs rather than one, because one run states no spread and this
/// target has a wide one. Most suites here take the provider's default
/// sampling — temperature 0.6 out of MLX's clock-seeded PRNG — so the `<think>`
/// block the 30B writes ahead of each answer is a different length on every
/// run, and the wall clock is different with it. Runs 4 to 7 were measured
/// while another process held the box's GPU for their whole duration — a
/// GPU-heavy game at 900 to 1600 percent CPU, load average 12 to 22, for runs
/// 6 and 7 — and the 30B decoded near ten tokens a second under it, which is
/// why most rows grew between run 3 and run 4 with no code change to their
/// suites. Each column is the code of its day on the same box; a row whose
/// suite a task converted between two runs names that task below.
///
/// Runs 1 and 2 are read off Swift Testing's own per-test lines, because
/// ``GatedRealModelSuiteTrait`` did not print yet. Runs 3 to 7 are read off
/// that trait's own lines, which is what the budget is measured against from
/// here on — so the table can be measured again without a stopwatch.
///
/// | run 1 | run 2 | run 3 | run 4 | run 5 | run 6 | run 7 | test |
/// |---|---|---|---|---|---|---|---|
/// | 94.1 | 114.1 | 116.4 | 3.1 | 3.1 | 3.0 | 3.1 | a whole fork tree recorded, torn down, and restored by root id |
/// | 16.7 | 40.9 | 101.5 | 55.4 | 44.8 | 35.1 | 37.0 | a tool-using turn over a RecordingLanguageModel handle |
/// | 86.7 | 85.3 | 85.8 | 109.4 | 110.7 | 17.4 | 17.0 | a real tool-using turn delivers its own tools' data, on each surface |
/// | 40.3 | 48.3 | 58.6 | 52.6 | 34.6 | 63.6 | 36.6 | a second respond() call on the same backend sees the first turn |
/// | 54.4 | 61.7 | 58.5 | 49.6 | 47.9 | 56.9 | 51.4 | restoreSessionTree(tools:) gives a restored session real tool-calling |
/// | 45.7 | 27.9 | 46.5 | 62.4 | 60.9 | 48.6 | 43.4 | makeSession(transcript:) seeds a fresh backend |
/// | 46.6 | 48.7 | 44.9 | 84.9 | 60.9 | 89.8 | 55.0 | resolve real profile, then generate, embed, guide, fork, and record |
/// | 48.7 | 40.4 | 41.8 | 46.3 | 51.8 | 55.9 | 57.1 | turn 2's usage.input.cachedTokenCount is positive |
/// | 41.9 | 41.1 | 41.0 | 53.1 | 53.2 | 8.1 | 8.0 | the real transcript has the same entry kinds the scripted scenario produces |
/// | 28.8 | 62.3 | 39.7 | 63.8 | 45.6 | 39.9 | 30.4 | makeFork() seeds the child's transcript from the parent's |
/// | 67.2 | 27.4 | 24.4 | 85.5 | 68.5 | 21.0 | 35.7 | MLX path: whether the ToolContext bound around respond() arrives |
/// | 19.0 | 15.0 | 23.0 | 20.4 | 25.8 | 23.3 | 15.9 | recorded entry kinds match after a live streaming turn |
/// | 23.3 | 30.0 | 21.7 | 22.8 | 19.6 | 40.9 | 23.9 | each respond() call leaves exactly one prompt entry and one response |
/// | 19.2 | 20.0 | 21.6 | 29.2 | 25.2 | 23.5 | 17.2 | transcriptEntries().count equals session.transcript.count |
/// | 19.5 | 17.2 | 20.3 | 23.4 | 18.8 | 24.4 | 24.7 | recorded entry kinds match the real session.transcript kinds |
/// | 16.6 | 21.0 | 19.3 | 20.2 | 21.2 | 19.4 | 23.4 | recorded tokensIn/tokensOut on the turn's response event |
/// | 14.6 | 15.2 | 18.6 | 18.6 | 18.7 | 18.0 | 17.8 | one fold against a real model |
/// | 16.0 | 20.4 | 17.9 | 25.1 | 25.3 | 20.9 | 21.5 | a fork taken after one turn begins holding exactly that turn's entries |
/// | 19.1 | 16.6 | 17.5 | 18.0 | 19.1 | 18.9 | 16.7 | turn 2 tends to be faster than turn 1 |
/// | 541.6 | 17.4 | 17.3 | 25.4 | 21.6 | 20.8 | 21.1 | contextFill climbs, compact() folds at the 0.80 trigger |
/// | 19.7 | 24.1 | 17.1 | 25.6 | 24.9 | 15.8 | 18.2 | reconstructed Transcript entry kinds and count match |
/// | 17.5 | 9.4 | 17.0 | 18.6 | 13.3 | 14.8 | 4.9 | a live LanguageModelSession rebuilt over a transcript |
/// | 18.8 | 19.3 | 14.5 | 23.8 | 24.4 | 23.2 | 23.1 | a fact planted at the very end of the folded span |
/// | 12.1 | 11.7 | 12.2 | 15.1 | 15.7 | 15.0 | 14.6 | one fold of the recorded transcript against a real model |
/// | 5.8 | 5.7 | 5.7 | 6.1 | 6.2 | 6.0 | 6.2 | a generation cancelled mid-decode unwinds as CancellationError |
/// | 5.2 | 5.1 | 5.1 | 7.5 | 5.7 | 5.5 | 5.4 | a session vended with a synthetic trigger folds inside its own turn |
/// | 2.1 | 2.3 | 2.1 | 2.5 | 2.5 | 1.9 | 2.0 | system-model path: whether the ToolContext bound around respond() arrives |
/// | 0.012 | 0.011 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | the recorded transcript still carries the entry kinds real traffic has |
/// | 0.001 | 0.001 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | a GPU-device MLXArray evaluation completes |
///
/// ## What the table says about the margin
///
/// The one test that did NOT fit is the compaction round trip, at 541.6
/// seconds — 4.5 times this budget. It is the test task ^k0d30s4 converted, and
/// it costs 17.3 to 25.4 seconds now; see `CompactionRoundTripIntegrationTests`
/// for what the conversion no longer proves.
///
/// Every test of all seven runs fits. In runs 1 to 3 two tests fit by little:
/// the fork-tree restoration measured 94.1, then 114.1, then 116.4 seconds —
/// 97 percent of this budget — and the `RecordingLanguageModel` handle round
/// trip measured 16.7, then 40.9, then 101.5, which is six times its own first
/// measurement with no code change between the three. Task ^bpwfbyz converted
/// both: the fork-tree restoration measures 3.1 and 3.1 seconds in runs 4 and
/// 5, and the handle round trip 55.4 and 44.8, each under half of this budget
/// in both runs. The test nearest the limit in runs 4 and 5 was the
/// both-surfaces tool turn of `RealToolTurnComparisonTests`, at 109.4 and
/// 110.7 seconds — 92 percent of this budget, up from 86 in runs 1 to 3. Task
/// ^6ww73dm moved that suite onto a 4B model that reasons and calls tools,
/// loads one container for each test, caps each round's reply and asks for
/// both calls in one step: the test measures 17.4 and 17.0 seconds in runs 6
/// and 7, and the transcript-shape test 8.1 and 8.0. See that suite for the
/// 30B measurement that ruled it out and for what the move no longer proves.
/// The test nearest the limit in runs 6 and 7 is `resolve real profile, then
/// generate, embed, guide, fork, and record`, at 89.8 seconds in run 6 — 75
/// percent of this budget on the shared box — and 55.0 in run 7; runs 1 to 5
/// measured it at 44.9 to 84.9. Task ^pa5q5dt carries it.
///
/// A test the limit cancels is worse than a plain red: the cancellation lands
/// mid-generation, and a cancellation on GPU work aborts the whole process on a
/// Metal assertion (fork card ^3axg80k), taking every other suite's results
/// with it. That is why the margin is stated here rather than left to be
/// discovered.
let integrationTestBudgetMinutes = 2

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
    /// The clock is per test rather than per suite. The budget is stated per
    /// test, Swift Testing charges `.timeLimit` per test, and a suite of this
    /// target holds many tests, so a per-test clock is the measurement that can
    /// be read straight against ``integrationTestBudgetMinutes``. No suite here
    /// asks for teardown as it ends: each gated `@Test` body evicts whatever it
    /// loaded for itself.
    ///
    /// - Returns: The trait.
    static var exclusiveRealModel: Self {
        GatedRealModelSuiteTrait(
            measurementLabel: integrationMeasurementLabel,
            measuring: .eachTest,
            holding: GatedSuiteSerialGate.shared
        )
    }
}
