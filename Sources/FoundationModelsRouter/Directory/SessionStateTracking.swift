import Foundation
import FoundationModelsExtras

/// The work state and the last summary of one session, as
/// ``RouterSessionDirectory`` keeps them (ROUTER-9): a pure reducer over the
/// ``SessionEvent``s of the session, with no session and no clock.
///
/// The work events drive working and idle, not the submission events (user
/// decision of 2026-10-21). One chain of work sends a
/// ``SessionEvent/submissionEnded(_:)`` for each submission (a tool loop or
/// an overflow retry sends more than one), so a submission end in the middle
/// of a turn would read as idle. ``SessionEvent/workStarted`` and
/// ``SessionEvent/workEnded`` come in turns and mean "work" and "no work":
///
/// - ``SessionEvent/workStarted`` gives `working`.
/// - ``SessionEvent/elicitationRequested(_:)`` gives `needsInput`, also
///   while the session works. It is the one event that gives `needsInput`: a
///   rule never asks (D64), so no rule denial does.
/// - ``SessionEvent/workEnded`` gives `idle`, or `needsInput` while a
///   question is still open: a run that waits only for the user is no work.
/// - ``SessionEvent/elicitationEnded(_:)`` and
///   ``SessionEvent/elicitationCompleted(_:)`` close their question. When no
///   question is open after that, the state is `working` while the session
///   works, else `idle`.
/// - ``SessionEvent/answered(_:)`` keeps the reply, cut to
///   ``lastSummaryLength`` characters, as ``lastSummary``. The state stays.
/// - ``archive()`` gives `archived`, and no later event changes it.
///
/// A `stateChanged` carries ``idleSummary``: the last summary with idle, and
/// `nil` with any other state, as the `SessionDirectory` port documents.
/// ``lastSummary`` keeps the reply in each state, for the summary of the
/// session.
///
/// A form answer of the client (``RoutedSession/respond(elicitationId:response:)``)
/// sends no event that names its question. So at each work end the directory
/// gives the tracking the open questions of the session itself
/// (``replaceOpenQuestions(with:)``), before it applies the work end.
struct SessionStateTracking: Sendable {
    /// The most characters the last summary keeps of a final reply.
    static let lastSummaryLength = 500

    /// The work state of the session.
    private(set) var state: SessionState = .idle

    /// The last final reply of the session, cut to ``lastSummaryLength``
    /// characters, or `nil` before the first answer.
    private(set) var lastSummary: String?

    /// The last summary that a `stateChanged` carries: ``lastSummary`` while
    /// the state is `idle`, else `nil`. The `SessionDirectory` port carries
    /// the last summary of a state change only with idle, so a working,
    /// needsInput or archived state carries none, while ``lastSummary``
    /// keeps the reply for the summary of the session.
    var idleSummary: String? {
        state == .idle ? lastSummary : nil
    }

    /// Whether the session has work: a ``SessionEvent/workStarted`` came
    /// after the last ``SessionEvent/workEnded``.
    private var hasWork = false

    /// The questions of the session that are open: asked, and not yet ended
    /// or completed.
    private var openQuestions: Set<ULID> = []

    /// Applies one event of the session. After ``archive()`` no event
    /// changes the tracking.
    ///
    /// - Parameter event: The event.
    mutating func apply(event: SessionEvent) {
        guard state != .archived else { return }
        switch event {
        case .workStarted:
            hasWork = true
            state = .working
        case .workEnded:
            hasWork = false
            state = openQuestions.isEmpty ? .idle : .needsInput
        case .elicitationRequested(let asked):
            if let question = asked.elicitation {
                openQuestions.insert(question.elicitationId)
            }
            state = .needsInput
        case .elicitationEnded(let end):
            closeQuestion(id: end.elicitationId)
        case .elicitationCompleted(let completion):
            closeQuestion(id: completion.elicitationId)
        case .answered(let answer):
            lastSummary = String(answer.reply.prefix(Self.lastSummaryLength))
        case .textDelta, .textReset, .reasoningDelta, .toolCall, .toolStatus, .toolInvocation, .toolCallReport,
            .toolDisplay, .entryRecorded, .compactionStarted, .compaction, .compactionFailed, .discoveryPrimingFailed,
            .generationStalled, .submissionQueued, .submissionStarted, .submissionEnded, .answerFailed,
            .repetitionStopped, .reasoningStopped, .runSettled, .runMessage, .runProgress, .generationCall,
            .mailDeliveryPaused, .mailDelivered, .cancelled, .signalDone, .lost:
            // The work events frame the work of the session, so none of
            // these changes the state: a submission is one part of a chain,
            // and the output of a turn or a run comes while the session works.
            break
        }
    }

    /// Replaces the open questions with the questions the session itself
    /// holds open (``RoutedSession/openElicitationIds()``). The state stays
    /// until the next event.
    ///
    /// - Parameter ids: The ids of the questions the session holds open.
    mutating func replaceOpenQuestions(with ids: Set<ULID>) {
        openQuestions = ids
    }

    /// Archives the session (ROUTER-11): the state becomes `archived` and
    /// stays. The last summary stays as it was.
    mutating func archive() {
        state = .archived
    }

    /// Closes the question `id`. With no question open after that, the state
    /// is `working` while the session works, else `idle`.
    ///
    /// - Parameter id: The id of the question that ended or completed.
    private mutating func closeQuestion(id: ULID) {
        openQuestions.remove(id)
        guard openQuestions.isEmpty else { return }
        state = hasWork ? .working : .idle
    }
}
