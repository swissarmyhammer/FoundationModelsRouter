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
}
