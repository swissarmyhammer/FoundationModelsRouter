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
///   journal records the terminal after the end. The end goes out as a live
///   event of the terminal (``QuestionEndDelivery/runEvent(_:)``), before its
///   ``SessionEvent/runSettled(_:)``.
/// - ``performCancelAll()``, before the sweep starts. The signal does not
///   wait for the sweep, so the session ends each open question itself, with
///   the origin of the signal, before the ``SessionEvent/signalDone(_:)``.
///   The sweep then gives the run the cancel. A later answer of the client
///   to such a question goes no further (``beginAnswer(to:)``).
/// - ``close()``, before the feeds end, with the origin ``Origin/system``.
///
/// An answer of the client can be on its way to the run plane when a place
/// ends its question. Then the end waits for that answer
/// (``AskedQuestions``): the answer sends the end when the run plane had no
/// question for it (``noteAnswer(to:outcome:startedWork:)``), through the
/// same delivery. The place waits until the answer returned
/// (``awaitAnswersOnTheirWay(to:)``), and only then sends its terminal event:
/// the ``SessionEvent/runSettled(_:)`` of the run, or the
/// ``SessionEvent/signalDone(_:)`` of the signal. Before the end of the feeds,
/// ``close()`` waits until no end check holds an end for an answer on its
/// way (``awaitDeferredEnds()``), whichever check owns that end: an end that
/// a cancel of a run or a cancel-all signal held before the close also comes
/// before the feeds end.
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
    /// before the live ``SessionEvent/runSettled(_:)`` of that terminal, and
    /// this call returns only when each end of the run went out
    /// (``settle(_:via:)``).
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
        let delivery = QuestionEndDelivery.runEvent(origin)
        await settle(askedQuestions.endQuestions(ofRun: runToken, notIn: openIds, via: delivery), via: delivery)
    }

    /// Ends each open question of each run now, and sends its end with the
    /// origin `origin`. ``performCancelAll()`` and ``close()`` call it before
    /// the sweep, which then gives each run the cancel.
    ///
    /// The end of a question with an answer on its way waits for that answer.
    /// The caller starts the sweep, and then waits for those answers before
    /// its terminal event: ``performCancelAll()`` waits for the answers to
    /// the returned ids (``awaitAnswersOnTheirWay(to:)``), and ``close()``
    /// waits for the answers to each held end (``awaitDeferredEnds()``). The sweep
    /// comes first, so an answer that comes to the run plane after the sweep
    /// finds no question, and the end goes out.
    ///
    /// - Parameter origin: The origin of the ends: the origin of the
    ///   cancel-all signal, or ``Origin/system`` for ``close()``.
    /// - Returns: The ids of the questions whose end waits for an answer on
    ///   its way.
    func endOpenQuestions(at origin: Origin) -> [ULID] {
        let delivery = QuestionEndDelivery.session(origin)
        let check = askedQuestions.endQuestions(ofRun: nil, notIn: [], via: delivery)
        sendNow(check, via: delivery)
        return check.deferred
    }

    /// Sends the ends of `check` that go out now, and then waits until the
    /// answers on their way to the questions whose end waits returned. Each
    /// of those answers sends its end when it returns.
    ///
    /// - Parameters:
    ///   - check: The result of one end check.
    ///   - delivery: How the ends go to the output.
    private func settle(_ check: QuestionEndCheck, via delivery: QuestionEndDelivery) async {
        sendNow(check, via: delivery)
        await awaitAnswersOnTheirWay(to: check.deferred)
    }

    /// Sends the ends of `check` that go out now, and reports an end that
    /// waits for an answer on its way to ``stateChanges``.
    ///
    /// - Parameters:
    ///   - check: The result of one end check.
    ///   - delivery: How the ends go to the output.
    private func sendNow(_ check: QuestionEndCheck, via delivery: QuestionEndDelivery) {
        sendQuestionEnds(check.ended, via: delivery)
        if !check.deferred.isEmpty {
            stateChanges.signal()
        }
    }

    /// Waits until no answer of the client to a question of `ids` is on its
    /// way to the run plane any more: each end of `ids` went out, or an
    /// answer resumed the run and no end comes.
    ///
    /// The wait runs in a task of its own, so a cancel of the caller does not
    /// end it: a cancel of the caller of ``close()`` must not let the feeds
    /// end before the ends. The wait ends, because an answer returns from the
    /// run plane with no wait for a terminal event.
    ///
    /// - Parameter ids: The ids of the questions whose end waits.
    func awaitAnswersOnTheirWay(to ids: [ULID]) async {
        await awaitAnswerReturns(until: { !$0.hasAnswerOnItsWay(toAnyOf: ids) })
    }

    /// Waits until no end check holds the end of a question for an answer on
    /// its way, whichever check owns that end
    /// (``AskedQuestions/hasDeferredEnds``): each such end went out, or an
    /// answer resumed the run and no end comes. ``close()`` calls it before
    /// the feeds end, so an end that a cancel of a run or a cancel-all signal
    /// held before the close also comes before the end of the feeds.
    ///
    /// A cancel of the caller does not end the wait, for the reason that
    /// ``awaitAnswersOnTheirWay(to:)`` gives.
    func awaitDeferredEnds() async {
        await awaitAnswerReturns(until: { !$0.hasDeferredEnds })
    }

    /// Waits on ``questionAnswerReturns`` until `isSettled` holds for
    /// ``askedQuestions``. The wait runs in a task of its own that is not
    /// cancelled, so the wait ends only when the state holds.
    ///
    /// - Parameter isSettled: Tells whether the record is in the state that
    ///   the caller waits for.
    private func awaitAnswerReturns(until isSettled: @escaping @Sendable (AskedQuestions) -> Bool) async {
        guard !isSettled(askedQuestions) else { return }
        await Task { await self.waitUntilAnswersReturned(isSettled) }.value
    }

    /// Waits on ``questionAnswerReturns`` until `isSettled` holds for
    /// ``askedQuestions``.
    ///
    /// - Parameter isSettled: Tells whether the record is in the state that
    ///   the caller waits for.
    private func waitUntilAnswersReturned(_ isSettled: @Sendable (AskedQuestions) -> Bool) async {
        _ = await questionAnswerReturns.waitUntil { isSettled(askedQuestions) }
    }

    /// Sends one end for each question of `ids` through `delivery`: the live
    /// event of a run terminal (``deliverLive(_:origin:)``), or the
    /// session-scoped output (``emitQuestionEnds(_:at:)``). An end that waited
    /// for an answer goes out through the same delivery as an end that goes
    /// out at once.
    ///
    /// - Parameters:
    ///   - ids: The ids of the questions that ended.
    ///   - delivery: How the ends go to the output.
    func sendQuestionEnds(_ ids: [ULID], via delivery: QuestionEndDelivery) {
        switch delivery {
        case .runEvent(let origin):
            for id in ids {
                deliverLive(Self.endEvent(ofQuestion: id), origin: origin)
            }
        case .session(let origin):
            emitQuestionEnds(ids, at: origin)
        }
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
    ///   client, or its end waits for an answer already on its way: the
    ///   answer must not go to the run plane.
    func beginAnswer(to id: ULID) -> Bool {
        askedQuestions.beginAnswer(to: id)
    }
}
