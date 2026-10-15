import FoundationModelsExtras

/// ``RoutedSessionActor``'s ends of the questions of its runs: one
/// ``SessionEvent/elicitationEnded(_:)`` for each question that
/// ``SessionEvent/elicitationRequested(_:)`` announced and that ended with no
/// answer of the client (task ^fqb5rjr).
///
/// The run plane of Extras ends a question with no answer of the client only
/// when it stops the run of the question: a cancel of the run
/// (`RunPlane.cancel(completionToken:)`) and the sweep of
/// ``cancelAll()`` and ``close()``. Each of them gives the run
/// `.cancel(reason: RunPlane.runCancelledReason)`. The run plane has no
/// report of an ended question, so the session finds the end itself: a
/// question left `RunPlane.openElicitations()`, and no answer of the client
/// resumed its run (``askedQuestions``).
///
/// The session finds the end at three places:
///
/// - The terminal of a run, in the journal (``record(event:origin:)``). A
///   cancel of the run ends its questions before the run settles, so the
///   journal records the terminal after the end. The end goes out with the
///   origin of the terminal, before its ``SessionEvent/runSettled(_:)``.
/// - ``performCancelAll()``, before the sweep starts. The signal does not
///   wait for the sweep, so the session ends each open question itself, with
///   the origin of the signal, before the ``SessionEvent/signalDone(_:)``.
///   The sweep then gives the run the cancel. A later answer of the client
///   to such a question goes no further (``beginAnswer(to:)``).
/// - ``close()``, before the feeds end, with the origin ``Origin/system``.
extension RoutedSessionActor {
    /// The response that the run plane gives to each question of a stopped
    /// run, and that the end of the question carries.
    static let stoppedRunResponse = ElicitationResponse.cancel(reason: RunPlane.runCancelledReason)

    /// The end event of the question `id`.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: ``SessionEvent/elicitationEnded(_:)`` with
    ///   ``stoppedRunResponse``.
    static func endEvent(ofQuestion id: ULID) -> SessionEvent {
        .elicitationEnded(ElicitationEnd(elicitationId: id, response: stoppedRunResponse))
    }

    /// Sends the end of each open question of the run of `terminal` that
    /// left the run plane. The journal calls it for the terminal of a run,
    /// before the live ``SessionEvent/runSettled(_:)`` of that terminal.
    ///
    /// The run plane is read only when the run has an open question in the
    /// record. The record ends the questions with no suspension point after
    /// that read, so an answer of the client that starts during the read is
    /// on its way when the record decides (``AskedQuestions``).
    ///
    /// - Parameters:
    ///   - terminal: The terminal event of the run.
    ///   - origin: The run mail of the terminal and the work that posted it.
    func endQuestionsThatLeftTheRunPlane(ofRunOf terminal: OperationEvent, origin: RunEventOrigin) async {
        let runToken = terminal.correlationID
        guard askedQuestions.hasOpenQuestions(ofRun: runToken) else { return }
        let openIds = Set(await runPlane.openElicitations().map(\.elicitationId))
        for id in askedQuestions.endQuestions(ofRun: runToken, notIn: openIds, at: origin.output) {
            deliverLive(Self.endEvent(ofQuestion: id), origin: origin)
        }
    }

    /// Ends each open question of each run now, and sends its end with the
    /// origin `origin`. ``performCancelAll()`` and ``close()`` call it before
    /// the sweep, which then gives each run the cancel.
    ///
    /// - Parameter origin: The origin of the ends: the origin of the
    ///   cancel-all signal, or ``Origin/system`` for ``close()``.
    func endOpenQuestions(at origin: Origin) {
        emitQuestionEnds(askedQuestions.endQuestions(ofRun: nil, notIn: [], at: origin), at: origin)
    }

    /// Sends one end for each question of `ids`, with the origin `origin`, to
    /// the session-scoped output. It does not go through the sink of a
    /// running answer: ``cancelAll()`` silenced the answer that runs, and
    /// the end belongs to the work that ended the question.
    ///
    /// - Parameters:
    ///   - ids: The ids of the questions that ended.
    ///   - origin: The origin of the ends.
    func emitQuestionEnds(_ ids: [ULID], at origin: Origin) {
        guard !ids.isEmpty else { return }
        OriginContext.$current.withValue(origin) {
            for id in ids {
                emitSessionScopedEvent(Self.endEvent(ofQuestion: id))
            }
        }
    }

    /// Records that an answer of the client to the question `id` goes to the
    /// run plane now (``AskedQuestions/beginAnswer(to:)``).
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: `false` when the question ended with no answer of the
    ///   client: the answer must not go to the run plane.
    func beginAnswer(to id: ULID) -> Bool {
        askedQuestions.beginAnswer(to: id)
    }
}
