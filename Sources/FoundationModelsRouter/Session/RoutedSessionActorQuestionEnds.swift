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
///
/// A question that left the run plane through a completion gets no end. The
/// run plane takes an accepted URL question off at its completion, and the
/// post of the completion comes later (`ToolContext.complete(elicitationId:)`
/// of the tool that asked, or ``RoutedSession/complete(elicitationId:)``).
/// While that post is on its way, the run plane gives the id in
/// `RunPlane.completingElicitations()`. Each end check reads that list, and
/// marks such a question as completed (``AskedQuestions/State/completed``):
/// the post then sends its ``SessionEvent/elicitationCompleted(_:)``. A
/// question that left the run plane with no completion, for example through a
/// cancel of its run, is in neither list, and it ends as usual.
/// ``performCancelAll()`` waits for the completions that its check found
/// before the ``SessionEvent/signalDone(_:)``, and ``close()`` waits for each
/// completion on its way before the feeds end (``awaitDeferredEnds()``). The
/// run plane always posts a completion that it started, so these waits end.
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
    /// The read takes the open questions first, and then the questions whose
    /// completion post is on its way. A question that the run plane completes
    /// between the two reads is then in the second list, so it gets no end.
    /// This check marks such a question as completed, but does not wait for
    /// its post: the check runs on the journal chain, and the post is queued
    /// on the same chain after it. ``close()`` waits for that post before the
    /// feeds end.
    ///
    /// - Parameters:
    ///   - terminal: The terminal event of the run.
    ///   - origin: The run mail of the terminal and the work that posted it.
    func endQuestionsThatLeftTheRunPlane(ofRunOf terminal: OperationEvent, origin: RunEventOrigin) async {
        let runToken = terminal.correlationID
        guard askedQuestions.hasOpenQuestions(ofRun: runToken) else { return }
        let openIds = Set(await runPlane.openElicitations().map(\.elicitationId))
        let completingIds = Set(await runPlane.completingElicitations())
        let delivery = QuestionEndDelivery.runEvent(origin)
        let check = askedQuestions.endQuestions(
            ofRun: runToken, notIn: openIds, completing: completingIds, via: delivery)
        await settle(check, via: delivery)
    }

    /// Ends each open question of each run now, and sends its end with the
    /// origin `origin`. ``performCancelAll()`` and ``close()`` call it before
    /// the sweep, which then gives each run the cancel.
    ///
    /// The end of a question with an answer on its way waits for that answer.
    /// A question whose completion post is on its way
    /// (`RunPlane.completingElicitations()`) gets no end: it becomes
    /// completed, and the post sends its completion. The record decides with
    /// no suspension point after the read of the run plane. The caller starts
    /// the sweep, and then waits for those answers and posts before its
    /// terminal event: ``performCancelAll()`` waits for the returned ids
    /// (``awaitAnswersAndCompletionsOnTheirWay(to:)``), and ``close()`` waits
    /// for each held end and each completion on its way
    /// (``awaitDeferredEnds()``). The sweep comes first, so an answer that
    /// comes to the run plane after the sweep finds no question, and the end
    /// goes out. The sweep does not find a question whose completion post is
    /// on its way, so that post always comes.
    ///
    /// - Parameter origin: The origin of the ends: the origin of the
    ///   cancel-all signal, or ``Origin/system`` for ``close()``.
    /// - Returns: The ids of the questions whose end waits for an answer on
    ///   its way, and of the questions whose completion post is on its way.
    func endOpenQuestions(at origin: Origin) async -> [ULID] {
        let completingIds = Set(await runPlane.completingElicitations())
        let delivery = QuestionEndDelivery.session(origin)
        let check = askedQuestions.endQuestions(ofRun: nil, notIn: [], completing: completingIds, via: delivery)
        sendNow(check, via: delivery)
        return check.deferred + check.completing
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

    /// Waits until no answer of the client to a question of `ids` is on its
    /// way to the run plane, and no completion post of a question of `ids` is
    /// on its way to the journal: each end of `ids` went out, an answer
    /// resumed the run and no end comes, or the completion went out.
    /// ``performCancelAll()`` calls it before its
    /// ``SessionEvent/signalDone(_:)``.
    ///
    /// The journal chain must not call it: a completion post is queued on
    /// that chain, so a wait on the chain for it never ends. A cancel of the
    /// caller does not end the wait, for the reason that
    /// ``awaitAnswersOnTheirWay(to:)`` gives. The wait ends, because an answer
    /// returns with no wait for a terminal event, and the run plane always
    /// posts a completion that it started.
    ///
    /// - Parameter ids: The ids of the questions whose end waits, or whose
    ///   completion post is on its way.
    func awaitAnswersAndCompletionsOnTheirWay(to ids: [ULID]) async {
        await awaitAnswerReturns(until: {
            !$0.hasAnswerOnItsWay(toAnyOf: ids) && !$0.hasCompletionOnItsWay(toAnyOf: ids)
        })
    }

    /// Waits until no end check holds the end of a question for an answer on
    /// its way, whichever check owns that end
    /// (``AskedQuestions/hasDeferredEnds``), and no completion post of a
    /// question is on its way (``AskedQuestions/hasCompletionsOnTheirWay``):
    /// each such end went out, an answer resumed the run and no end comes,
    /// or the completion went out. ``close()`` calls it before the feeds end,
    /// so an end that a cancel of a run or a cancel-all signal held before
    /// the close, and a completion on its way, also come before the end of
    /// the feeds.
    ///
    /// A cancel of the caller does not end the wait, for the reason that
    /// ``awaitAnswersOnTheirWay(to:)`` gives.
    func awaitDeferredEnds() async {
        await awaitAnswerReturns(until: { !$0.hasDeferredEnds && !$0.hasCompletionsOnTheirWay })
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
