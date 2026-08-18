import Foundation

@testable import FoundationModelsRouter

/// Which of one sample's two real model calls a progress line reports.
///
/// A gated sample pays for exactly two generations — the summarizer call inside
/// the fold, and the answering turn on the resumed session — and they are the
/// only two places a sample can spend half an hour. The raw value is the word a
/// line states, so the vocabulary lives in one declaration rather than in a
/// branch for each step.
enum CompactionEvalProgressStep: String, Sendable, CaseIterable {
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// over the seed's entries, summarizer call included.
    case fold

    /// The resumed session's answer to the seed's question.
    case answer
}

/// What one sample is called in every progress line it emits.
///
/// A run cut short by the suite's time limit leaves its trail and nothing else,
/// so a line has to name the sample without the table that never printed: which
/// seed it ran, and how far into the tier it stood when it stopped.
struct CompactionEvalSampleLabel: Sendable, Equatable {
    /// Where this sample stands in the tier, counting from one in the order the
    /// samples started.
    let ordinal: Int

    /// How many seeds the tier states — the denominator ``ordinal`` is read
    /// against.
    let total: Int

    /// The ``CompactionEvalSeed/id`` this sample ran, or
    /// ``CompactionEvalFactRetentionReport/unmatchedSeedID`` when its question
    /// matched no seed of the tier.
    let seedID: String

    /// This label as a progress line states it.
    var rendered: String {
        "sample=\(ordinal)/\(total) seed=\(seedID)"
    }
}

extension CompactionEvalSampleLabel {
    /// Labels the sample that asked `question`, resolving the seed it ran.
    ///
    /// A question is the join key a recorded sample already carries back to its
    /// seed — see ``CompactionEvalFactRetentionReport/findings(for:seeds:)`` —
    /// so a live line and the table printed at the end always name one sample
    /// the same way.
    ///
    /// - Parameters:
    ///   - ordinal: Where this sample stands in the tier, counting from one.
    ///   - total: How many seeds the tier states.
    ///   - question: The question this sample asked.
    ///   - seedsByQuestion: The tier's seeds, keyed by
    ///     ``CompactionEvalSeed/keyedByQuestion(_:)``.
    init(
        ordinal: Int,
        of total: Int,
        question: String,
        in seedsByQuestion: [String: CompactionEvalSeed]
    ) {
        self.init(
            ordinal: ordinal,
            total: total,
            seedID: seedsByQuestion[question]?.id ?? CompactionEvalFactRetentionReport.unmatchedSeedID
        )
    }
}

/// The live trail a gated eval tier writes while it runs.
///
/// The tiers cost half an hour each and printed nothing until they ended, so a
/// run that hit its own time limit reported one bit: "not finished". The gated
/// run of 2026-08-18 measured 0 of 7 seeds that way (task ^h2xxsse), and no
/// reading of its output could say whether the model load, one fold, or one
/// answering turn had taken the time — three explanations that each cost
/// another half-hour run to tell apart.
///
/// Every line this renders is one fact stated as it happens: the model load
/// timed apart from the samples, and each sample naming the step it entered and
/// the step it left. A run cut short then stops mid-trail, and the last line it
/// wrote names exactly where.
///
/// Kept as functions over plain values, beside
/// ``CompactionEvalFactRetentionReport``, so the trail a gated run is read from
/// is itself covered by hermetic tests that need no model.
enum CompactionEvalProgressLog {
    /// The marker every progress line opens with, so one `grep` separates the
    /// trail from the model's own output and from the table printed at the end.
    static let linePrefix = "[compaction-eval]"

    /// What a line reporting a step's start states after the step's name.
    static let startedMarker = "started"

    /// What a line reporting a step's completion states after the step's name.
    static let returnedMarker = "returned"

    /// What the model-load lines state in place of a step name.
    ///
    /// Deliberately not a ``CompactionEvalProgressStep``: the load happens once
    /// for a whole tier, on the first sample's own call, and stating it as a
    /// step of that sample would charge one seed for work every seed shares.
    static let modelLoadStepName = "model load"

    /// How many places after the decimal point ``makeSecondsText(_:)`` states.
    ///
    /// One. A step of this eval runs in hundreds of seconds, so more places
    /// state noise; whole seconds would render a fast step as `0s` and read as
    /// a step that never ran.
    private static let secondsFormat = "%.1f"

    /// Renders a duration as a progress line states it.
    ///
    /// - Parameter seconds: The duration to state.
    /// - Returns: The seconds, to one decimal place, with their unit.
    static func makeSecondsText(_ seconds: Double) -> String {
        String(format: secondsFormat, seconds) + "s"
    }

    /// Renders the line stating that the tier's one model load has begun.
    ///
    /// - Parameter ref: The model being loaded.
    /// - Returns: The line.
    static func makeModelLoadStartedLine(ref: String) -> String {
        "\(linePrefix) \(modelLoadStepName) \(startedMarker) ref=\(ref)"
    }

    /// Renders the line stating that the tier's one model load has finished,
    /// and what it cost.
    ///
    /// - Parameters:
    ///   - ref: The model that was loaded.
    ///   - seconds: How long the load took.
    /// - Returns: The line.
    static func makeModelLoadReturnedLine(ref: String, seconds: Double) -> String {
        "\(linePrefix) \(modelLoadStepName) \(returnedMarker) ref=\(ref) took=\(makeSecondsText(seconds))"
    }

    /// Renders the line stating that one sample has entered a step.
    ///
    /// It carries no duration for the step, because the step has not finished.
    /// This is the line a hung fold or a hung answering turn leaves behind as
    /// the last word of a run.
    ///
    /// - Parameters:
    ///   - step: The step the sample entered.
    ///   - sample: The sample entering it.
    ///   - elapsedSeconds: How long the sample has run so far.
    /// - Returns: The line.
    static func makeStepStartedLine(
        _ step: CompactionEvalProgressStep,
        sample: CompactionEvalSampleLabel,
        elapsedSeconds: Double
    ) -> String {
        "\(linePrefix) \(sample.rendered) \(step.rawValue) \(startedMarker)"
            + " elapsed=\(makeSecondsText(elapsedSeconds))"
    }

    /// Renders the line stating that one sample has left a step, what the step
    /// cost, and what it produced.
    ///
    /// - Parameters:
    ///   - step: The step the sample left.
    ///   - sample: The sample leaving it.
    ///   - elapsedSeconds: How long the sample has run so far.
    ///   - stepSeconds: How long this step alone took.
    ///   - detail: What the step produced — ``makeFoldDetail(stagesApplied:summarizerCalls:)``
    ///     or ``makeAnswerDetail(answer:)``.
    /// - Returns: The line.
    static func makeStepReturnedLine(
        _ step: CompactionEvalProgressStep,
        sample: CompactionEvalSampleLabel,
        elapsedSeconds: Double,
        stepSeconds: Double,
        detail: String
    ) -> String {
        "\(linePrefix) \(sample.rendered) \(step.rawValue) \(returnedMarker)"
            + " elapsed=\(makeSecondsText(elapsedSeconds))"
            + " took=\(makeSecondsText(stepSeconds))"
            + " \(detail)"
    }

    /// Renders what a fold produced, for the fold's own returned line.
    ///
    /// The three facts that separate the shapes a fold can take while it is
    /// still the only thing that ran: the stages it applied (empty for a fold
    /// `Compactor.compact` discarded), how many round trips its summarizer
    /// made, and how large the summarizer's last answer was. The full
    /// measurement of a discarded fold stays in the table — see
    /// ``CompactionEvalFactRetentionReport/discardedSummaryMarker``.
    ///
    /// - Parameters:
    ///   - stagesApplied: The fold's ``CompactionResult/stagesApplied``.
    ///   - summarizerCalls: Every summarizer call the fold made, in call order.
    /// - Returns: The detail text.
    static func makeFoldDetail(
        stagesApplied: [String],
        summarizerCalls: [CompactionEvalSummarizerCall]
    ) -> String {
        // The LAST call, for the same reason
        // `CompactionEvalSampleDiagnostic.discardedSummary` reads it: a chunked
        // fold's final reduce call is the one answer the boundary carries.
        let summarizerBytes = summarizerCalls.last?.answer.utf8.count ?? 0
        return "stages=\(stagesApplied.joined(separator: ","))"
            + " summarizerCalls=\(summarizerCalls.count)"
            + " summarizerBytes=\(summarizerBytes)"
    }

    /// Renders what an answering turn produced, for its own returned line.
    ///
    /// - Parameter answer: The resumed session's answer.
    /// - Returns: The detail text.
    static func makeAnswerDetail(answer: String) -> String {
        "answerBytes=\(answer.utf8.count)"
    }

    /// Prints one progress line where a person watching the run sees it.
    ///
    /// Flushed rather than left to the C library. `stdout` is block-buffered
    /// whenever the run is piped to a file — which is how every gated run of
    /// this eval has been captured — so an unflushed trail arrives in blocks
    /// long after the step it reports, and the whole point of the trail is that
    /// it arrives while the step is still running.
    ///
    /// - Parameter line: The line to print.
    static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
