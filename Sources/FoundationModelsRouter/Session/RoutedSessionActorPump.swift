import Foundation
import FoundationModels
import FoundationModelsExtras
import Logging
import Tracing

/// The work that the pump of a session runs now (`generation-queue.md`,
/// section 5.4). The pump runs one work at a time, so a session never has
/// two SDK calls, and no caller waits on a lock.
struct PumpWork {
    /// What the work is.
    enum Kind {
        /// The pump takes the next batch. It has no mail yet. A
        /// ``RoutedSession/cancelAll()`` that arrives now ends the take: no
        /// answer starts (see `runNextAnswer()`).
        case taking

        /// An answer: the chain of submissions that answers the mail of the
        /// open answer (``RoutedSessionActor/openAnswerMail``). The chain
        /// starts with one submission, and each continuation of it is one
        /// more submission (section 5.5).
        ///
        /// - Parameter options: The options of every submission of the chain.
        case answer(options: SubmissionOptions)
    }

    /// The id of the work. Ids are monotonic in their session.
    let id: UInt64

    /// What the work is.
    var kind: Kind
}

/// ``RoutedSessionActor``'s pump: the one task of the session that submits
/// for it (`generation-queue.md`, section 5.4, and `mailbox.md`, section 5).
///
/// The pump is event driven. New mail wakes it (``wakePump()``), and it ends
/// when a take gives no mail. Each cycle takes one batch of the mail queue
/// ``SessionOutbox/queue`` (``takeNextBatch(runTokens:)``): the first
/// user-type mail decides the options of the batch, each user-type mail
/// that the options admit comes with it, and all run mail rides it. With no
/// user-type mail, the run mail starts an answer of its own only when it can
/// start a submission. The pump runs the chain of submissions that answers
/// the batch. Mail that arrives while a submission runs waits in the queue
/// for the next cycle, or for the next continuation of the running answer.
extension RoutedSessionActor: SessionMailObserver {
    /// The text that separates two user-type prompts in the prompt of one
    /// submission: the block separator of the render
    /// (``ContextRenderer/blockSeparator``).
    static let messageSeparator = ContextRenderer.blockSeparator

    /// The prompt of a submission that only run mail started when a run
    /// terminal is in that mail: the settled runs' terminals precede it as
    /// its preamble (``mailDeliveryPrompt(for:)``).
    static let settledRunDeliveryPrompt = """
        Background work you started has settled, and its result is above. \
        Act on it, or say what you did with it.
        """

    /// The prompt of a submission that only run mail started when no
    /// settled run's terminal is in that mail: the messages of background
    /// runs (``OperationEventKind/message``) precede it as its preamble. Each
    /// run is still open, and its terminal comes later.
    static let runMessageDeliveryPrompt = """
        Background work you started sent you a message, and it is above. \
        The work is still running, and its result comes later. \
        Act on the message, or say what you did with it.
        """

    /// The prompt of a submission that only run mail started: the
    /// ``settledRunDeliveryPrompt`` when a run terminal
    /// (``OperationEventKind/completed``) is in the mail, and else the
    /// ``runMessageDeliveryPrompt``, because only a message of a background
    /// run started the submission.
    ///
    /// - Parameter mail: The mail events of the submission.
    /// - Returns: The prompt that follows the preamble of the mail.
    static func mailDeliveryPrompt(for mail: [OperationEvent]) -> String {
        mail.contains { $0.kind == .completed } ? settledRunDeliveryPrompt : runMessageDeliveryPrompt
    }

    /// See ``SessionMailObserver/mailArrived()``. Wakes the pump, which
    /// delivers the new mail when it can start a submission.
    func mailArrived() {
        wakePump()
    }

    /// See ``SessionMailObserver/runMailWithdrawn(_:)``. Sends the terminal
    /// event ``SessionEvent/cancelled(_:)`` of each withdrawn mail.
    ///
    /// - Parameter ids: The ids of the withdrawn mail, in queue order.
    nonisolated func runMailWithdrawn(_ ids: [MailID]) {
        emitCancelled(ids)
    }

    /// Whether the pump of this session runs now.
    var isPumpRunning: Bool {
        pumpTask != nil
    }

    /// Starts the pump when no pump runs. When a pump runs, it takes one
    /// more cycle before it ends.
    ///
    /// The pump is a detached task: it inherits no task-local of the caller
    /// that woke it. So a ``ModelCallMark`` of a tool body that sent mail
    /// never reaches a submission of the pump.
    ///
    /// While a drain runs (``drainTask``), no pump starts.
    func wakePump() {
        pumpWakeRequested = true
        guard pumpTask == nil, drainTask == nil else { return }
        pumpTask = Task.detached { await self.runPump() }
    }

    /// The loop of the pump: one cycle for each work, until no work waits.
    ///
    /// A drain (``drainTask``) ends the loop before its next work. The end of
    /// the loop is a change of the work of the session
    /// (``signalWorkChange()``).
    private func runPump() async {
        while drainTask == nil {
            pumpWakeRequested = false
            guard await withSessionTelemetry({ await runNextAnswer() }) || pumpWakeRequested else { break }
        }
        pumpTask = nil
        signalWorkChange()
    }

    /// Runs one job of the pump with the explicit telemetry of this session
    /// bound: the logger (``withSessionLogger(_:)``) and the metrics factory
    /// (``withSessionMetricsFactory(_:)``). Neither binding adds a suspension
    /// point.
    ///
    /// - Parameter job: The job of the pump.
    /// - Returns: The value of `job`.
    private func withSessionTelemetry<Value>(_ job: nonisolated(nonsending) () async -> Value) async -> Value {
        await withSessionLogger { await withSessionMetricsFactory(job) }
    }

    /// Takes the next batch and runs its answer.
    ///
    /// - Returns: `false` when no batch could start an answer. Then the pump
    ///   ends, until new mail wakes it.
    private func runNextAnswer() async -> Bool {
        let workId = lastWorkId + 1
        pumpWork = PumpWork(id: workId, kind: .taking)
        let runTokens = await readBackgroundRunTokens()
        // A stop of all work (``cancelAll()``) that came while the pump read
        // the runs ends this take: mail that arrived later waits for the next
        // cycle, and no answer starts in a stopped work.
        guard cancelRequestedWorkId != workId else {
            endPumpWork()
            return false
        }
        // No suspension point between the take and the work that holds the
        // mail: a cancel finds each mail in the queue or in the open answer.
        guard let batch = takeNextBatch(runTokens: runTokens) else {
            endPumpWork()
            return false
        }
        guard !batch.userMail.isEmpty || mailOnlyAnswersInARow < mailOnlyAnswerLimit else {
            pauseMailDelivery(holding: batch.runMail)
            endPumpWork()
            return false
        }
        await runAnswer(of: batch, workId: workId)
        return true
    }

    /// Takes the next batch from ``SessionOutbox/queue``, with no suspension
    /// point.
    ///
    /// The queue is read first (``MailQueue/pending``). When it holds no
    /// user-type mail and its run mail cannot start a submission, nothing is
    /// taken. Else the take runs the batch rule (``joinsNewBatch(_:_:isGuided:)``).
    /// The queue can change between the read and the take, so the batch is
    /// checked again: a batch with no user-type mail that cannot start a
    /// submission goes back to the queue as it was.
    ///
    /// - Parameter runTokens: The completion tokens of the background runs.
    /// - Returns: The batch, or `nil` when nothing can start an answer.
    private func takeNextBatch(runTokens: BackgroundRunTokens) -> SubmissionBatch? {
        let pending = outbox.queue.pending
        guard pending.contains(where: { !$0.isRunMail }) || runMailCanStart(pending, runTokens: runTokens) else {
            return nil
        }
        let isGuided = grammar != nil
        let batch = SubmissionBatch(mail: outbox.queue.take { Self.joinsNewBatch($0, $1, isGuided: isGuided) })
        guard !batch.mail.isEmpty else { return nil }
        guard batch.userMail.isEmpty, !runMailCanStart(batch.mail, runTokens: runTokens) else { return batch }
        settleCancelledMail(outbox.putBack(untouched: batch.mail).map(\.id))
        return nil
    }

    /// Whether the run mail of `mail` can start a submission with no
    /// user-type mail (``SessionOutbox/canStartASubmission(_:runTokens:)``).
    ///
    /// - Parameters:
    ///   - mail: Mail, in queue order.
    ///   - runTokens: The completion tokens of the background runs.
    /// - Returns: `true` when a run mail of `mail` that is not held can start
    ///   a submission.
    private func runMailCanStart(_ mail: [Mail], runTokens: BackgroundRunTokens) -> Bool {
        SessionOutbox.canStartASubmission(
            SessionOutbox.pendingEvents(of: mail, held: outbox.heldMailIDs), runTokens: runTokens)
    }

    /// The batch rule of a new answer. It runs under the lock of the queue,
    /// so it reads only its arguments.
    ///
    /// Run mail always comes with the batch, held or not. The first
    /// user-type mail in queue order is the leader, and its options
    /// (``SubmissionOptions``) decide the batch: each later user-type mail
    /// comes with it when the options admit it. A stream goes alone, and the
    /// token ceiling is part of the key.
    ///
    /// - Parameters:
    ///   - candidate: The next queued mail.
    ///   - batch: The mail taken before it.
    ///   - isGuided: Whether the session has a grammar.
    /// - Returns: `true` when `candidate` comes with the batch.
    static func joinsNewBatch(_ candidate: Mail, _ batch: [Mail], isGuided: Bool) -> Bool {
        guard let options = SubmissionOptions(for: candidate, isGuided: isGuided) else { return true }
        guard let leader = batch.first(where: { !$0.isRunMail }),
            let leaderOptions = SubmissionOptions(for: leader, isGuided: isGuided)
        else { return true }
        return leaderOptions.admits(options)
    }

    /// The join rule of the answer that runs with `options`. Run mail
    /// always joins. User-type mail joins when `options` admit it.
    ///
    /// - Parameters:
    ///   - candidate: The next queued mail.
    ///   - options: The options of the running answer.
    ///   - isGuided: Whether the session has a grammar.
    /// - Returns: `true` when `candidate` joins the answer.
    static func joinsRunningAnswer(_ candidate: Mail, options: SubmissionOptions, isGuided: Bool) -> Bool {
        guard let candidateOptions = SubmissionOptions(for: candidate, isGuided: isGuided) else { return true }
        return options.admits(candidateOptions)
    }

    /// Runs the chain of submissions that answers `batch`. The end of the
    /// chain sends the terminal event of each mail that the answer
    /// delivered.
    ///
    /// - Parameters:
    ///   - batch: What the first submission of the chain carries.
    ///   - workId: The id of the work.
    private func runAnswer(of batch: SubmissionBatch, workId: UInt64) async {
        lastWorkId = workId
        let options =
            batch.userMail.first.flatMap { SubmissionOptions(for: $0, isGuided: grammar != nil) } ?? .mailDelivery
        pumpWork?.kind = .answer(options: options)
        let callerContext = batch.userMail.first.flatMap { outbox.takeCallerContext(for: $0.id) }
        deliver(batch.mail)
        // The batch left the queue: the depth is synchronous, so it adds no
        // suspension point here.
        recordMessageQueueDepth()
        startAnswerLimits()
        // Each event of the answer has the origin of its batch. The pump is a
        // detached task, so no origin of a caller reaches it.
        await OriginContext.$current.withValue(.mail(Set(batch.ids))) {
            await ServiceContext.$current.withValue(callerContext) {
                await runFirstSubmission(of: batch, options: options)
            }
        }
        // The terminal event of the answer already cleared ``openAnswerMail``
        // (``emitAnswerEnd(for:)``).
        countAnswer()
        openAnswerRunMail = []
        openAnswerDeliveredUserMail = false
        endPumpWork()
    }

    /// Makes `mail` part of the open answer: its ids join
    /// ``openAnswerMail``, its run mail joins ``openAnswerRunMail``, and its
    /// hold and caller contexts are forgotten. The answer sends
    /// ``SessionEvent/mailDelivered(_:)`` for each one.
    ///
    /// - Parameter mail: The mail that the pump took for the answer.
    private func deliver(_ mail: [Mail]) {
        openAnswerMail.append(mail.map(\.id))
        openAnswerRunMail += mail.filter(\.isRunMail)
        openAnswerDeliveredUserMail = openAnswerDeliveredUserMail || mail.contains { !$0.isRunMail }
        outbox.forget(mail.map(\.id))
    }

    /// Counts the answer that just ended for the bound on answers that run
    /// mail alone starts (``SessionConfiguration/mailOnlyAnswerLimit``). An
    /// answer that delivered user-type mail, also mail that joined a
    /// continuation, starts the count again. An answer that only run mail
    /// started adds one.
    private func countAnswer() {
        mailOnlyAnswersInARow = openAnswerDeliveredUserMail ? 0 : mailOnlyAnswersInARow + 1
    }

    /// Holds the run mail of a batch that only run mail started, because
    /// ``mailOnlyAnswersInARow`` reached ``mailOnlyAnswerLimit``
    /// (`generation-queue.md`, section 5.4). The mail goes back into the
    /// queue, held, so it starts no submission by itself, and the next
    /// user-type mail carries it. The session reports the hold with
    /// ``SessionEvent/mailDeliveryPaused(_:)`` and a log line.
    ///
    /// No answer runs now, so the event goes to the session-wide feed only.
    ///
    /// - Parameter mail: The run mail the pump took.
    private func pauseMailDelivery(holding mail: [Mail]) {
        settleCancelledMail(outbox.putBack(holding: mail).map(\.id))
        let pause = MailDeliveryPause(limit: mailOnlyAnswerLimit, heldMail: mail.compactMap(\.runEvent))
        sessionLogger(.mailDelivery).notice(
            "the mail delivery pauses",
            metadata: [
                RouterTelemetry.LogMetadataKey.sessionId: "\(id.description)",
                RouterTelemetry.LogMetadataKey.mailDeliveryPause: "\(pause.description)",
            ])
        emitSessionScopedEvent(.mailDeliveryPaused(pause))
    }

    /// Runs the first submission of an answer, and every continuation of it.
    ///
    /// The prompt of the submission is the render of the mail of the batch
    /// in take order (``ContextRenderer/promptText(delivering:followedBy:)``):
    /// the text of each user-type mail, and one line for each run mail. A
    /// batch with no user-type mail gets ``mailDeliveryPrompt(for:)`` after
    /// its mail. The own prompt of the answer, which a recovery sends again,
    /// is the text of each user-type mail joined with ``messageSeparator``,
    /// or that delivery prompt.
    ///
    /// - Parameters:
    ///   - batch: The mail of the first submission.
    ///   - options: The options of every submission of the chain. Their
    ///     token ceiling is the ceiling of each submission: every user-type
    ///     mail that the options admit named that same ceiling.
    private func runFirstSubmission(of batch: SubmissionBatch, options: SubmissionOptions) async {
        let ceiling = ResponseTokenCeiling(
            requested: options.requestedMaxTokens, contextTokens: contextTokens,
            repetitionDetection: repetitionDetection)
        let work = submissionWork(isStream: options.isStream, responseTokenCeiling: ceiling)
        let runEvents = batch.runMail.compactMap(\.runEvent)
        let userPrompts = batch.userMail.compactMap(\.promptText)
        let ownPrompt =
            userPrompts.isEmpty
            ? Self.mailDeliveryPrompt(for: runEvents) : userPrompts.joined(separator: Self.messageSeparator)
        await attachOutboxJournalIfNeeded()
        await recordSessionMetaIfNeeded()
        await notifySubmissionBoundaryTools()
        await runAnswerChain(
            grammar: work.grammar, deliveredMail: batch.mail, ownPrompt: ownPrompt,
            responseTokenCeiling: ceiling, work.body)
    }

    /// Takes what a continuation submission of the running answer carries:
    /// all queued run mail, and the user-type mail that the options of the
    /// answer admit (`generation-queue.md`, section 5.5,
    /// ``joinsRunningAnswer(_:options:isGuided:)``). The mail joins the open
    /// answer, so the terminal event of the answer ends it. User-type mail
    /// that the options do not admit waits for the next answer. An answer
    /// that ``cancelAll()`` stopped takes no more mail: its readers already
    /// have its end.
    ///
    /// - Returns: The joining mail, in take order.
    func takeMailJoiningTheAnswer() -> [Mail] {
        guard case .answer(let options) = pumpWork?.kind, !openAnswerMail.isSilenced else { return [] }
        let isGuided = grammar != nil
        let joining = outbox.queue.take { candidate, _ in
            Self.joinsRunningAnswer(candidate, options: options, isGuided: isGuided)
        }
        deliver(joining)
        recordMessageQueueDepth()
        return joining
    }

    /// Ends the running work: its id and a cancel requested for it.
    private func endPumpWork() {
        pumpWork = nil
        cancelRequestedWorkId = nil
    }

    /// Gives the answer that starts now fresh limits (`generation-queue.md`,
    /// section 5.5). An answer is the chain of submissions from the first
    /// delivery to the final answer, so its limits are for the whole chain:
    ///
    /// - ``compactionYieldsStopped``: a compaction inside the answer that
    ///   applied no summary stops the next ones of that answer only;
    /// - ``RepetitionWatchState/recoveriesThisAnswer``: the answer goes on
    ///   after at most ``RepetitionDetection/recoveriesPerAnswer`` repetition
    ///   stops and reasoning stops together;
    /// - ``RepetitionWatchState/finalPassRan``: an answer runs at most one
    ///   final pass after its last recovery (task ^0dcsd3t);
    /// - ``RepetitionWatchState/toolCallRun``: the count of identical
    ///   consecutive tool calls runs within one answer (task ^8eq31j0).
    ///
    /// The third limit, the one overflow retry, is no stored state: the first
    /// submission of each answer gets the permission
    /// (``runAnswerChain(grammar:deliveredMail:ownPrompt:responseTokenCeiling:_:)``),
    /// each continuation carries the permission of the submission before it
    /// (``StoppedAttempt/allowOverflowRetry``), and the retry itself gives none.
    ///
    /// Only the pump calls this, one time before the first submission of an
    /// answer. A continuation submission never calls it, so it keeps the
    /// limits of its answer.
    private func startAnswerLimits() {
        compactionYieldsStopped = false
        repetitionWatch.recoveriesThisAnswer = 0
        repetitionWatch.finalPassRan = false
        repetitionWatch.toolCallRun = IdenticalToolCallRun()
    }
}
