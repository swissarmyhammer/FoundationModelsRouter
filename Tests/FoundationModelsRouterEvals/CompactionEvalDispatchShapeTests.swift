import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterEvalSupport

// MARK: - Dispatch shape (plain `swift test`, no real inference)

/// Counts the samples that are inside their subject work at the same moment.
///
/// An `actor`, so two samples that really did overlap can never lose an
/// update to a data race and report a smaller overlap than the run had.
private actor CompactionEvalDispatchShapeRecorder {
    /// How many samples are inside their subject work right now.
    private var inFlightCount = 0

    /// The largest ``inFlightCount`` any moment of the run reached.
    private(set) var maxInFlightCount = 0

    /// How many samples entered their subject work over the whole run.
    private(set) var enteredCount = 0

    /// Records that one sample entered its subject work.
    func recordEntry() {
        inFlightCount += 1
        enteredCount += 1
        maxInFlightCount = max(maxInFlightCount, inFlightCount)
    }

    /// Records that one sample left its subject work.
    func recordExit() {
        inFlightCount -= 1
    }
}

/// Measures the dispatch shape of `Evaluation.run(info:)` itself, hermetically.
///
/// Task ^23qeprz holds the two gated trails this test exists to settle: one
/// run of 2026-08-18 dispatched all seven samples together, and a later run
/// of the same dispatch code drove them one at a time. `Evaluation.run(info:)`
/// takes no concurrency limit (see the installed `Evaluations.framework`
/// interface), so the shape belongs to the framework, and the only honest way
/// to state it is to measure it — a trail's `elapsed=` values prove nothing
/// about it (the field was a literal zero at every fold start until task
/// ^h2xxsse removed it), and only the ORDER of a trail's lines does.
///
/// This suite measures the shape with no model at all: a fake subject that
/// suspends long enough for any concurrent dispatch to overlap, and no
/// `ModelJudgeEvaluator` (`includesJudgedDimensions: false`), so a plain
/// `swift test` states the answer on every run.
///
/// The gated tiers do not TRUST the answer: `CompactionEvalRealSubjectRunner`
/// and `CompactionContinuityEvalRealSubjectRunner` each hold a value-1 permit
/// around one sample's work, so the tiers run one sample at a time whatever
/// shape the framework dispatches. This test is the tripwire that says when
/// the framework's own shape changed, so the per-sample derivations in
/// `CompactionEvalTiers.swift` get re-read against the new shape instead of
/// drifting silently.
@Suite("CompactionEvaluation dispatch shape")
struct CompactionEvalDispatchShapeTests {
    /// How long the fake subject suspends, in milliseconds.
    ///
    /// Long enough that a dispatcher which starts a second sample while the
    /// first is suspended would overlap the two on any machine, and short
    /// enough that all 24 seeds still cost about half a second when the
    /// framework drives them one at a time.
    private static let fakeSubjectSuspensionMilliseconds = 20

    @Test("Evaluation.run(info:) drives the samples one at a time")
    func runDrivesSamplesOneAtATime() async throws {
        let recorder = CompactionEvalDispatchShapeRecorder()
        let evaluation = CompactionEvaluation(includesJudgedDimensions: false) { _, _, _, _ in
            await recorder.recordEntry()
            // Suspends so a concurrent dispatcher has room to start the next
            // sample before this one returns. A subject that returns without
            // suspending would measure every dispatch shape as serial.
            try await Task.sleep(for: .milliseconds(Self.fakeSubjectSuspensionMilliseconds))
            await recorder.recordExit()
            return ("the fake answer", 500, 50, ["Summarization"])
        }

        _ = try await evaluation.run()

        // Every seed's sample ran — an answer of "one at a time" over a
        // dataset that never dispatched would be vacuous.
        #expect(await recorder.enteredCount == compactionEvalSeeds.count)
        // THE answer this suite exists to state: the framework drives one
        // sample at a time. A failure here means the framework's dispatch
        // shape changed — re-read the per-sample derivations in
        // `CompactionEvalTiers.swift` before touching this expectation.
        #expect(await recorder.maxInFlightCount == 1)
    }
}
