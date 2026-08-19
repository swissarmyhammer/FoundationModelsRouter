import Foundation

import FoundationModelsRouter

/// Which real model call a progress line reports.
///
/// The raw value is the word a line states, so the whole vocabulary lives in one
/// declaration rather than in a branch for each step. The two gated tiers spend
/// their time in differently-shaped calls, and both vocabularies live here so
/// one `grep` reads either trail.
///
/// ``fold`` and ``answer`` are the fact-retention tier's pair: a sample there
/// pays for exactly two generations, and they are the only two places it can
/// spend half an hour. ``step`` and ``finalInstruction`` are the continuity
/// tier's: a sample there drives a LIST of steps through one live session before
/// it asks its final instruction, so it pays for as many generations as its task
/// has steps (task ^aktsp2e).
enum CompactionEvalProgressStep: String, Sendable, CaseIterable {
    /// ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// over the seed's entries, summarizer call included.
    case fold

    /// The resumed session's answer to the seed's question.
    case answer

    /// One of the continuity task's steps — a setup step planting a fact, or a
    /// filler step pushing the session toward its budget's trigger — driven
    /// through the live session.
    case step

    /// The continuity task's final instruction, whose reply is the answer that
    /// tier's metrics read.
    case finalInstruction = "final-instruction"
}

/// What a tier calls the fixture one of its samples ran.
///
/// The two tiers draw from differently-shaped fixtures, and a reader who greps
/// one trail has to know which one a line names. The raw value is the key a line
/// states in front of the id.
enum CompactionEvalFixtureKind: String, Sendable {
    /// A ``CompactionEvalSeed`` of the fact-retention tier.
    case seed

    /// A ``CompactionContinuitySeed`` of the continuity tier — that tier's
    /// dataset, its evaluation and every one of its metrics call one a task.
    case task
}

/// What one sample is called in every progress line it emits.
///
/// A run cut short by the suite's time limit leaves its trail and nothing else,
/// so a line has to name the sample without the table that never printed: which
/// fixture it ran, and how far into the tier it stood when it stopped.
struct CompactionEvalSampleLabel: Sendable, Equatable {
    /// Where this sample stands in the tier, counting from one in the order the
    /// samples started.
    let ordinal: Int

    /// How many fixtures the tier states — the denominator ``ordinal`` is read
    /// against.
    let total: Int

    /// What this sample's tier calls the fixture it ran.
    let fixture: CompactionEvalFixtureKind

    /// The ``CompactionEvalSeed/id`` or ``CompactionContinuitySeed/id`` this
    /// sample ran, or ``CompactionEvalFactRetentionReport/unmatchedSeedID`` when
    /// it matched no fixture of the tier.
    let fixtureID: String

    /// This label as a progress line states it.
    var rendered: String {
        "sample=\(ordinal)/\(total) \(fixture.rawValue)=\(fixtureID)"
    }
}

extension CompactionEvalSampleLabel {
    /// Labels a sample whose tier has already resolved the fixture it is
    /// running.
    ///
    /// Each tier joins a running sample back to its fixture on a key the sample
    /// already carries — the question for the fact-retention tier (see
    /// ``CompactionEvalFactRetentionReport/findings(for:seeds:)``), the final
    /// instruction for the continuity tier — so the lookup stays with the runner
    /// that owns the fixtures, and this initializer takes the answer.
    ///
    /// - Parameters:
    ///   - ordinal: Where this sample stands in the tier, counting from one.
    ///   - total: How many fixtures the tier states.
    ///   - fixture: What this tier calls the fixture.
    ///   - id: The resolved fixture's own id, or `nil` when the sample's join key
    ///     matched no fixture of the tier.
    init(ordinal: Int, of total: Int, fixture: CompactionEvalFixtureKind, id: String?) {
        self.init(
            ordinal: ordinal,
            total: total,
            fixture: fixture,
            fixtureID: id ?? CompactionEvalFactRetentionReport.unmatchedSeedID
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
    ///   - elapsedSeconds: How long the sample has run so far, or `nil` when
    ///     this is the sample's FIRST step and nothing of it has been measured
    ///     yet. A `nil` states no `elapsed=` clause at all.
    ///
    ///     The first step used to pass the literal `0`, and the line then read
    ///     `elapsed=0.0s` — a number carrying no measurement, which was misread
    ///     as evidence that the samples were dispatched concurrently. A clause
    ///     that is absent cannot be misread; a zero can.
    ///   - detail: What the sample is about to do, when the step's own name does
    ///     not say it — ``makeStepPositionDetail(ordinal:of:)``. Empty by
    ///     default, and an empty detail states no clause.
    /// - Returns: The line.
    static func makeStepStartedLine(
        _ step: CompactionEvalProgressStep,
        sample: CompactionEvalSampleLabel,
        elapsedSeconds: Double?,
        detail: String = ""
    ) -> String {
        var line = "\(linePrefix) \(sample.rendered) \(step.rawValue) \(startedMarker)"
        if let elapsedSeconds {
            line += " elapsed=\(makeSecondsText(elapsedSeconds))"
        }
        if !detail.isEmpty {
            line += " \(detail)"
        }
        return line
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

    /// Renders where in its task a continuity sample's step stands, for that
    /// step's own STARTED line.
    ///
    /// A continuity task drives a dozen or more steps, and every one of them
    /// renders the same ``CompactionEvalProgressStep/step`` word. Without this,
    /// a run cut short states which sample it stopped in and not which step of
    /// it, so the started line — the line a hung generation leaves as the last
    /// word of a run — carries the position.
    ///
    /// - Parameters:
    ///   - ordinal: Where this step stands in the task, counting from one.
    ///   - total: How many steps the task drives before its final instruction.
    /// - Returns: The detail text.
    static func makeStepPositionDetail(ordinal: Int, of total: Int) -> String {
        "step=\(ordinal)/\(total)"
    }

    /// Renders what one step driven through a live session produced, for that
    /// step's own returned line.
    ///
    /// The two facts that separate the shapes a continuity step can take: how
    /// large its reply was, and whether the session's own budget folded while it
    /// ran. The fold count is the one this tier exists to watch — a task is
    /// sized so at least one fold fires somewhere in the middle, and this states
    /// which step it fired on rather than leaving the whole task's count to be
    /// read at the end.
    ///
    /// - Parameters:
    ///   - reply: What the session answered this step with.
    ///   - foldCount: How many ``SessionEvent/compaction(_:)`` events this step
    ///     drove.
    /// - Returns: The detail text.
    static func makeDrivenStepDetail(reply: String, foldCount: Int) -> String {
        "replyBytes=\(reply.utf8.count) folds=\(foldCount)"
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
