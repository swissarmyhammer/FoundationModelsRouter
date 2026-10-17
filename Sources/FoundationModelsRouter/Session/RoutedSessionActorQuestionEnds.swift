import FoundationModelsExtras

/// ``RoutedSessionActor``'s wait for the end posts and the completion posts
/// of the questions of its runs (task ^pjycptw).
///
/// The run plane of Extras decides how each question ends, and it posts each
/// end and each completion to the sink of the question: an end through
/// `OperationEventSink.post(elicitationEnded:response:)`
/// (``record(elicitationEnded:response:poster:)``), and a completion through
/// `OperationEventSink.post(elicitationCompleted:)`
/// (``record(elicitationCompleted:poster:)``). The session makes no end of a
/// question itself.
///
/// While such a post is on its way, the run plane gives the id of the
/// question in `RunPlane.endingElicitations()` or in
/// `RunPlane.completingElicitations()`. The stop of the session
/// (``performCancelAll()``) reads these lists, and waits until the journal
/// handled each of these posts (``awaitQuestionPosts(of:)``). Thus each end
/// and each completion that is on its way comes before the terminal event of
/// the stop.
extension RoutedSessionActor {
    /// The ids of the questions whose end post or completion post is on its
    /// way now: `RunPlane.endingElicitations()`, and then
    /// `RunPlane.completingElicitations()`.
    ///
    /// - Returns: The ids, ends first.
    func questionPostsOnTheirWay() async -> [ULID] {
        let ending = await runPlane.endingElicitations()
        let completing = await runPlane.completingElicitations()
        return ending + completing
    }

    /// Waits until the journal handled the end post or the completion post
    /// of each question of `ids`: no question of `ids` is in the record any
    /// more (``AskedQuestions/holdsQuestion(amongAnyOf:)``).
    ///
    /// The wait reads the record of the session, not the lists of the run
    /// plane. The run plane takes an id off its list only after the post
    /// returned, and the journal signals ``questionPosts`` before the post
    /// returns. Thus a read of the run plane after that signal can still find
    /// the id, and no later signal comes.
    ///
    /// A question whose post is on its way is in the record until the
    /// journal handles that post. The run plane posts the end of a question
    /// only after the post of the question returned, and the journal records
    /// the question in that post. A question that is not in the record gets
    /// no event, so the wait does not wait for it.
    ///
    /// The posts alone bound this wait: each post of `ids` is in progress,
    /// and the run plane always finishes a post that it started. No canceler
    /// and no tool bounds it. The wait runs in a task of its own that is not
    /// cancelled, so a cancel of the caller does not end it: a cancel of the
    /// caller of ``close()`` must not let the feeds end before these events.
    ///
    /// The journal chain must not call it: each post is queued on that chain,
    /// so a wait on the chain for it never ends.
    ///
    /// - Parameter ids: The ids of the questions whose post is on its way.
    func awaitQuestionPosts(of ids: [ULID]) async {
        guard askedQuestions.holdsQuestion(amongAnyOf: ids) else { return }
        await Task { await self.waitUntilQuestionsLeftTheRecord(ids) }.value
    }

    /// Waits on ``questionPosts`` until no question of `ids` is in the
    /// record.
    ///
    /// - Parameter ids: The ids of the questions whose post is on its way.
    private func waitUntilQuestionsLeftTheRecord(_ ids: [ULID]) async {
        _ = await questionPosts.waitUntil { !askedQuestions.holdsQuestion(amongAnyOf: ids) }
    }

    /// Ends each question that went out on the feeds and can still get an
    /// end or a completion, waits for its post, and then finishes the feeds
    /// (``finishSessionEventSubscriptions()``). Only ``close()`` calls it,
    /// after ``performCancelAll()``.
    ///
    /// The rule (R3): each ``SessionEvent/elicitationRequested(_:)`` on a
    /// feed gets its ``SessionEvent/elicitationEnded(_:)`` (or its answer or
    /// its completion) on the same feed before that feed ends.
    ///
    /// ``performCancelAll()`` ends the questions that are open when it runs.
    /// While it waits for the end posts, a run that no cancel reached can ask
    /// a new question, for example a question that a
    /// ``SubagentQuestionRelay`` sends up from a child. The journal records
    /// that question, and it goes out on the feeds. The sweep that
    /// ``performCancelAll()`` starts ends such a question only later, because
    /// a slow canceler can hold the sweep. Thus each cycle of this call ends
    /// each open question (`RunPlane.cancelOpenElicitations()`), and waits
    /// for each end post and each completion post that is on its way
    /// (``awaitQuestionPosts(of:)``).
    ///
    /// The cycles repeat until a check finds no such question
    /// (``feedsHoldAnOpenQuestion()``). The feeds finish after that check
    /// with no suspension point between them, so no question goes out on a
    /// feed between the check and the end of the feeds. The journal records
    /// a later question, and it goes to no feed.
    ///
    /// The waits are bounded by sink posts only, as the waits of
    /// ``performCancelAll()`` are: no canceler and no tool bounds them. A
    /// cycle repeats only for a question that a run asked during the cycle
    /// before.
    func finishFeedsAfterTheirQuestionsEnded() async {
        while true {
            _ = await runPlane.cancelOpenElicitations()
            await awaitQuestionPosts(of: await questionPostsOnTheirWay())
            guard await feedsHoldAnOpenQuestion() else {
                finishSessionEventSubscriptions()
                return
            }
        }
    }

    /// Whether a question that went out on the feeds can still get an end or
    /// a completion: the record holds it (``askedQuestions``), and the run
    /// plane holds it open, or its end post or completion post is on its
    /// way. A question that the journal recorded during the reads of the run
    /// plane counts too, because the reads can come before its question
    /// opened in the run plane.
    ///
    /// A question that the run plane holds and the record does not hold did
    /// not go out yet. The journal records it after this check, and the
    /// caller then finished the feeds.
    ///
    /// - Returns: `true` when a cycle of
    ///   ``finishFeedsAfterTheirQuestionsEnded()`` must end a question or
    ///   wait for a post.
    private func feedsHoldAnOpenQuestion() async -> Bool {
        let recordedBefore = askedQuestions.recordedCount
        let open = await runPlane.openElicitations().map(\.elicitationId)
        let onTheirWay = await questionPostsOnTheirWay()
        return askedQuestions.recordedCount != recordedBefore
            || askedQuestions.holdsQuestion(amongAnyOf: open + onTheirWay)
    }
}
