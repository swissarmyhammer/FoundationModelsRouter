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
        /// The pump takes the next batch. It has no message yet. A cancel
        /// that arrives now still reaches the answer that the batch starts.
        case taking

        /// An answer: the chain of submissions that answers `letters`. The
        /// chain starts with one submission, and each continuation of it is
        /// one more submission (section 5.5).
        ///
        /// - Parameters:
        ///   - options: The options of every submission of the chain.
        ///   - letters: Every caller message the chain delivered so far.
        case answer(options: SubmissionOptions, letters: [SessionLetter])

        /// A compaction that a caller asked for
        /// (``RoutedSession/compact(prompt:budget:)``).
        ///
        /// - Parameter requestID: The id that ``RoutedSessionActor/compactionRequests``
        ///   gave the request.
        case compaction(requestID: MessageID)
    }

    /// The id of the work. Ids are monotonic in their session.
    let id: UInt64

    /// What the work is.
    var kind: Kind

    /// The letter that the pump posted to ``SessionOutbox/messages`` to start
    /// the batch of an answer that only mail starts, or `nil` when a caller
    /// message started the batch. The letter is no caller message: the answer
    /// carries no letter for it, and ``RoutedSessionActor/messageQueueDepth()``
    /// leaves it out.
    var mailDeliveryLetter: MessageID?
}

/// A compaction that a caller asked for, which waits for the pump
/// (``RoutedSession/compact(prompt:budget:)``). The pump runs it between two
/// submissions, as it runs every compaction.
struct CompactionRequest: Sendable {
    /// The compaction prompt sent to the summarizer.
    let prompt: CompactionPrompt

    /// The token budget to compact against, or `nil` for the resolved
    /// working context of the session.
    let budget: TokenBudget?

    /// The tracing context of the caller, so the compaction span is a child
    /// of the span of the caller.
    let serviceContext: ServiceContext?
}

/// The queue of the caller compactions of one session: an Extras `Mailbox`
/// whose answer is the result of the compaction
/// (``RoutedSessionActor/compactionRequests``).
typealias CompactionRequestMailbox = FoundationModelsExtras.Mailbox<CompactionRequest, CompactionResult>

/// ``RoutedSessionActor``'s pump: the one task of the session that submits
/// for it (`generation-queue.md`, section 5.4).
///
/// The pump starts when a message arrives and no pump runs, and it ends when
/// no deliverable message waits. Each cycle takes one batch of the mailbox
/// ``SessionOutbox/messages``: every waiting message that can share one
/// submission. The pump runs the chain of submissions that answers the
/// batch, and the mailbox gives the result to each message of the batch.
/// A message that arrives while a submission runs waits in the mailbox for
/// the next cycle, or for the next continuation of the running answer.
extension RoutedSessionActor: SessionMailObserver {
    /// The text that separates two caller prompts in the prompt of one
    /// submission.
    static let messageSeparator = "\n\n"

    /// The prompt of a submission that only mail started: the settled runs'
    /// terminals precede it as its preamble.
    static let settledRunDeliveryPrompt = """
        Background work you started has settled, and its result is above. \
        Act on it, or say what you did with it.
        """

    /// The message of the letter that the pump posts to start the batch of an
    /// answer that only mail starts (``PumpWork/mailDeliveryLetter``). Its
    /// options are ``SubmissionOptions/mailDelivery``. No caller waits for
    /// its answer.
    static let mailDeliveryMessage = SessionMessage(
        prompt: .plainText(settledRunDeliveryPrompt), requestedMaxTokens: nil, reader: .reply, serviceContext: nil)

    /// See ``SessionMailObserver/mailArrived()``. Wakes the pump, which
    /// delivers the new mail when it can start a submission.
    func mailArrived() {
        wakePump()
    }

    /// Whether the pump of this session runs now.
    var isPumpRunning: Bool {
        pumpTask != nil
    }

    /// Starts the pump when no pump runs. When a pump runs, it takes one
    /// more cycle before it ends. A pump that waits for a letter that a
    /// cancel withdrew is released (``releasePumpAwaitingLetter()``), and a
    /// new pump takes its place.
    ///
    /// The pump is a detached task: it inherits no task-local of the caller
    /// that woke it. So a ``ModelCallMark`` of a tool body that sent a
    /// message never reaches a submission of the pump.
    ///
    /// While a drain runs (``drainTask``), no pump starts.
    func wakePump() {
        pumpWakeRequested = true
        releasePumpAwaitingLetter()
        guard pumpTask == nil, drainTask == nil else { return }
        pumpTask = Task.detached { await self.runPump() }
    }

    /// Stops the pump when it waits in a mailbox for a letter
    /// (``pumpAwaitsLetter``). The pump reads that a letter waits, and then
    /// takes its batch with no suspension point between the two. A cancel
    /// from the handler of a caller task does not run on this actor, so it
    /// can withdraw the letter between the two, and the take then waits for
    /// a letter that never comes. The cancel of the pump task ends that wait
    /// with nothing taken, and the pump then starts a new pump
    /// (``runPump()``).
    func releasePumpAwaitingLetter() {
        guard pumpAwaitsLetter else { return }
        pumpTask?.cancel()
    }

    /// The loop of the pump: one cycle for each work, until no work waits.
    ///
    /// A released pump (``releasePumpAwaitingLetter()``) is cancelled, so it
    /// ends, and it starts a new pump in its place: the new task is not
    /// cancelled, so it can run the next answer. A drain (``drainTask``) ends
    /// the loop before its next work. The end of the loop is a change of the
    /// work of the session (``signalWorkChange()``).
    private func runPump() async {
        while !Task.isCancelled, drainTask == nil {
            pumpWakeRequested = false
            if !pendingCompactions.isEmpty {
                await withSessionTelemetry { await runNextCallerCompaction() }
                continue
            }
            guard await withSessionTelemetry({ await runNextAnswer() }) || pumpWakeRequested else { break }
        }
        pumpTask = nil
        if Task.isCancelled {
            wakePump()
        }
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
    /// When a caller message waits, the pump takes the next batch of
    /// ``SessionOutbox/messages``: the first waiting message decides the
    /// options of the batch (``SubmissionOptions``), and every waiting
    /// message that the options admit comes with it, in FIFO order. A stream
    /// message goes alone. Every pending mail event comes with the batch,
    /// held or not. When no caller message waits, the terminal of a settled
    /// background run that is not held starts an answer of its own
    /// (``SessionOutbox/takeMailStartingASubmission(deliveringRunsOf:)``,
    /// ``answerMail(_:settledRunTokens:workId:)``). A caller message that
    /// arrives while the pump takes that mail starts the answer in its place,
    /// and the mail rides it.
    ///
    /// - Returns: `false` when no deliverable message waited, or when the
    ///   pump was released before it took a batch.
    private func runNextAnswer() async -> Bool {
        let workId = lastWorkId + 1
        pumpWork = PumpWork(id: workId, kind: .taking)
        let settledRunTokens = await mailbox.settledRunTokens()
        guard outbox.messages.pending.isEmpty else {
            return await answerCallerBatch(settledRunTokens: settledRunTokens, workId: workId)
        }
        guard let mail = await outbox.takeMailStartingASubmission(deliveringRunsOf: settledRunTokens) else {
            endPumpWork()
            return false
        }
        // No suspension point between this read and the post of the delivery
        // letter: ``answerMail(_:settledRunTokens:workId:)`` relies on it.
        guard !outbox.messages.pending.isEmpty else {
            return await answerMail(mail, settledRunTokens: settledRunTokens, workId: workId)
        }
        // A caller message arrived while the pump took the mail. The mail
        // goes back as it was, and the next cycle reads the waiting messages
        // again with no suspension point before its take. The work keeps its
        // id, so a cancel that arrived meanwhile reaches the next answer.
        await outbox.putBack(untouched: mail)
        return true
    }

    /// Takes the next batch of caller messages, and runs its answer. Every
    /// pending mail event comes with the batch.
    ///
    /// - Parameters:
    ///   - settledRunTokens: The completion tokens of the settled background
    ///     runs.
    ///   - workId: The id of the work.
    /// - Returns: `false` when the pump was released before it took a batch.
    private func answerCallerBatch(settledRunTokens: Set<String>, workId: UInt64) async -> Bool {
        let answered = await answerNextBatch(of: outbox.messages, joining: SessionMessage.sharesSubmission) {
            letters in
            let mail = await outbox.takeEvents()
            // No suspension point between the read of the cancel marks
            // and the work that holds the live letters: ``cancel(message:)``
            // relies on it.
            let live = liveLetters(letters, of: outbox.messages)
            return try await runAnswer(
                of: SubmissionBatch(letters: live, events: mail), settledRunTokens: settledRunTokens,
                workId: workId
            ).get()
        }
        if !answered {
            endPumpWork()
        }
        return answered
    }

    /// Runs the answer that only `mail` starts, as the body of a batch of
    /// ``SessionOutbox/messages``. The pump posts a letter of its own
    /// (``mailDeliveryMessage``) to start the batch, because the mailbox
    /// starts no batch with no letter. A caller message that arrives while
    /// the answer runs can then join a continuation of it
    /// (``takeMessagesJoiningTheAnswer()``), and its caller gets the final
    /// reply of the answer, or its error. The answer carries no letter for
    /// the delivery letter, which no caller waits for.
    ///
    /// The caller reads that no caller message waits, and calls this with no
    /// suspension point between the two. A caller posts only on this actor,
    /// so the delivery letter is the first letter, the batch takes it alone,
    /// and no reader on this actor sees it wait.
    ///
    /// - Parameters:
    ///   - mail: The mail the pump took, which can start a submission.
    ///   - settledRunTokens: The completion tokens of the settled background
    ///     runs.
    ///   - workId: The id of the work.
    /// - Returns: `false` when the pump was released before it took the
    ///   batch. Then the mail went back as it was.
    private func answerMail(
        _ mail: [SessionOutbox.PendingEvent], settledRunTokens: Set<String>, workId: UInt64
    ) async -> Bool {
        let deliveryLetter = outbox.messages.post(Self.mailDeliveryMessage).id
        pumpWork?.mailDeliveryLetter = deliveryLetter
        let answered = await answerNextBatch(of: outbox.messages, joining: { _, _ in false }) { _ in
            try await runAnswer(
                of: SubmissionBatch(letters: [], events: mail), settledRunTokens: settledRunTokens, workId: workId
            ).get()
        }
        guard answered else {
            // Nothing ran. The delivery letter leaves the mailbox, and the
            // mail must not be lost.
            outbox.messages.cancel(deliveryLetter)
            await outbox.putBack(untouched: mail)
            endPumpWork()
            return false
        }
        return true
    }

    /// Runs the chain of submissions that answers `batch`, and gives its
    /// result back. The mailbox gives the result to every caller message of
    /// the batch, and to every message that joined a continuation.
    ///
    /// - Parameters:
    ///   - batch: What the first submission of the chain carries.
    ///   - settledRunTokens: The completion tokens whose terminal can start a
    ///     submission with no caller message.
    ///   - workId: The id of the work.
    /// - Returns: The final reply of the chain, or its error.
    ///   `CancellationError` when the batch started no answer.
    private func runAnswer(
        of batch: SubmissionBatch, settledRunTokens: Set<String>, workId: UInt64
    ) async -> Result<String, any Error> {
        let mailCanStart = SessionOutbox.canStartASubmission(batch.events, settledRunTokens: settledRunTokens)
        guard !batch.letters.isEmpty || mailCanStart else {
            // Every caller of the batch was cancelled, and the mail alone
            // cannot start a submission. The mail goes back as it was.
            await outbox.putBack(untouched: batch.events)
            endPumpWork()
            return .failure(CancellationError())
        }
        guard !batch.letters.isEmpty || mailOnlyAnswersInARow < mailOnlyAnswerLimit else {
            await pauseMailDelivery(holding: batch.events)
            endPumpWork()
            return .failure(CancellationError())
        }
        lastWorkId = workId
        let options = batch.letters.first?.message.options ?? .mailDelivery
        pumpWork?.kind = .answer(options: options, letters: batch.letters)
        // The batch left the waiting messages: the depth is synchronous, so
        // it adds no suspension point here.
        recordMessageQueueDepth()
        startAnswerLimits()
        let result: Result<String, any Error>
        do {
            result = .success(
                try await runFirstSubmission(
                    carrying: batch.letters, options: options, mail: batch.events.map(\.event)))
        } catch {
            result = .failure(error)
        }
        countAnswer(delivering: deliveredMessages ?? batch.letters)
        endPumpWork()
        return result
    }

    /// Counts the answer that just ended for the bound on answers that mail
    /// alone starts (``SessionConfiguration/mailOnlyAnswerLimit``). An answer
    /// that delivered a caller message, also one that joined a continuation,
    /// starts the count again. An answer that only mail started adds one.
    ///
    /// - Parameter delivered: The caller messages the answer delivered.
    private func countAnswer(delivering delivered: [SessionLetter]) {
        mailOnlyAnswersInARow = delivered.isEmpty ? mailOnlyAnswersInARow + 1 : 0
    }

    /// Holds the mail of a batch that only mail started, because
    /// ``mailOnlyAnswersInARow`` reached ``mailOnlyAnswerLimit``
    /// (`generation-queue.md`, section 5.4). The mail goes back into the
    /// outbox, held, so it starts no submission by itself, and the next
    /// caller message carries it. The session reports the hold with
    /// ``SessionEvent/mailDeliveryPaused(_:)`` and a log line.
    ///
    /// No answer runs now, so the event goes to the session-wide feed only.
    ///
    /// - Parameter events: The mail the pump took.
    private func pauseMailDelivery(holding events: [SessionOutbox.PendingEvent]) async {
        await outbox.putBack(holding: events)
        let pause = MailDeliveryPause(limit: mailOnlyAnswerLimit, heldMail: events.map(\.event))
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
    /// - Parameters:
    ///   - letters: The caller messages of the first submission, or none
    ///     when only mail started it.
    ///   - options: The options of every submission of the chain. Their
    ///     token ceiling is the ceiling of each submission: every message
    ///     that the options admit named that same ceiling.
    ///   - mail: The mail events of the first submission.
    /// - Returns: The final reply of the chain.
    /// - Throws: What the chain throws.
    private func runFirstSubmission(
        carrying letters: [SessionLetter], options: SubmissionOptions, mail: [OperationEvent]
    ) async throws -> String {
        let first = letters.first?.message
        let ceiling = ResponseTokenCeiling(
            requested: options.requestedMaxTokens, contextTokens: contextTokens,
            repetitionDetection: repetitionDetection)
        let work = submissionWork(for: first?.reader ?? .reply, responseTokenCeiling: ceiling)
        let ownPrompt =
            letters.isEmpty
            ? Self.settledRunDeliveryPrompt : letters.map(\.message.text).joined(separator: Self.messageSeparator)
        await attachOutboxJournalIfNeeded()
        await recordSessionMetaIfNeeded()
        await notifySubmissionBoundaryTools()
        return try await ServiceContext.$current.withValue(first?.serviceContext) {
            try await runAnswerChain(
                grammar: work.grammar, pendingEvents: mail, ownPrompt: ownPrompt,
                responseTokenCeiling: ceiling, onEvent: work.onEvent, work.body)
        }
    }

    /// The caller messages the running answer delivered so far, or `nil`
    /// when no answer runs.
    var deliveredMessages: [SessionLetter]? {
        guard case .answer(_, let letters) = pumpWork?.kind else { return nil }
        return letters
    }

    /// Takes what a continuation submission of the running answer carries:
    /// the mail that waits, and the caller messages that can share the
    /// submission (`generation-queue.md`, section 5.5). The messages join the
    /// batch of the answer in the mailbox, so their callers get its final
    /// reply. An answer that only mail started runs in the batch of its
    /// delivery letter (``answerMail(_:settledRunTokens:workId:)``), so a
    /// caller message joins it as well. A message that the options do not
    /// admit waits for the next answer.
    ///
    /// - Returns: The mail events, the texts of the joining messages, and the
    ///   ids of the joining messages, in the same order as the texts.
    func takeMessagesJoiningTheAnswer() async -> (events: [OperationEvent], texts: [String], ids: [MessageID]) {
        guard case .answer(let options, _) = pumpWork?.kind else { return ([], [], []) }
        let events = await outbox.takeEvents()
        // No suspension point between the take, the read of the cancel marks
        // and the work that holds the joining letters: ``cancel(message:)``
        // relies on it.
        let joining = liveLetters(outbox.messages.takeJoining(admitting: options.admits), of: outbox.messages)
        if case .answer(let options, let letters) = pumpWork?.kind {
            pumpWork?.kind = .answer(options: options, letters: letters + joining)
        }
        recordMessageQueueDepth()
        return (events.map(\.event), joining.map(\.message.text), joining.map(\.id))
    }

    /// The ids of the items the work of the pump carries: the messages the
    /// running answer delivered, or the running caller compaction. None when
    /// no answer and no caller compaction runs.
    var runningWorkItems: [MessageID] {
        switch pumpWork?.kind {
        case .answer(_, let letters):
            return letters.map(\.id)
        case .compaction(let requestID):
            return [requestID]
        case .taking, nil:
            return []
        }
    }

    /// Whether the work the pump runs carries the message or the caller
    /// compaction `id` (``runningWorkItems``).
    ///
    /// - Parameter id: The id of the message or of the compaction request.
    /// - Returns: `true` when the running work carries it.
    func runningWorkCarries(_ id: MessageID) -> Bool {
        runningWorkItems.contains(id)
    }

    /// Ends the running work: its id, a cancel requested for it, and the
    /// cancel marks of its items (``cancelMarks``).
    private func endPumpWork() {
        pumpWork = nil
        cancelRequestedWorkId = nil
        cancelMarks.clear()
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
    /// (``runAnswerChain(grammar:pendingEvents:ownPrompt:responseTokenCeiling:onEvent:_:)``),
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

    // MARK: - Batches of a mailbox

    /// Takes the next batch of `mailbox`, runs `body` over it, and gives the
    /// result of `body` to each letter of the batch.
    ///
    /// ``pumpAwaitsLetter`` is set from the call until `body` starts, so
    /// ``releasePumpAwaitingLetter()`` can end a take that waits for a letter
    /// that a cancel withdrew. The flag is set only while the take can wait:
    /// `body` clears it before it runs any work.
    ///
    /// - Parameters:
    ///   - mailbox: The mailbox to take from.
    ///   - joins: Whether a waiting letter shares the batch that the first
    ///     letter starts.
    ///   - body: Makes the answer of the batch.
    /// - Returns: `false` when the pump was released before a batch came.
    ///   Then nothing was taken.
    @discardableResult
    private func answerNextBatch<Message: Sendable, Answer: Sendable>(
        of mailbox: FoundationModelsExtras.Mailbox<Message, Answer>,
        joining joins: (Message, Message) -> Bool,
        _ body: ([FoundationModelsExtras.Mailbox<Message, Answer>.Letter]) async throws -> Answer
    ) async -> Bool {
        pumpAwaitsLetter = true
        defer { pumpAwaitsLetter = false }
        return await mailbox.answerNextBatch(joining: joins) { letters in
            pumpAwaitsLetter = false
            return try await body(letters)
        }
    }

    /// The letters of `letters` whose callers are not cancelled. Each letter
    /// with a cancel mark (``cancelMarks``) leaves the batch of `mailbox`
    /// and gets `CancellationError` at once. A letter that a cancel took out
    /// of the batch before this read has its `CancellationError` already.
    ///
    /// The pump reads the marks here, with no suspension point before it
    /// makes the letters part of its work, so a cancel that arrives while
    /// the pump takes them is not lost: it drops the letter here, or finds
    /// it in the work.
    ///
    /// - Parameters:
    ///   - letters: The letters the pump took.
    ///   - mailbox: The mailbox the pump took them from.
    /// - Returns: The live letters, in order.
    private func liveLetters<Message: Sendable, Answer: Sendable>(
        _ letters: [FoundationModelsExtras.Mailbox<Message, Answer>.Letter],
        of mailbox: FoundationModelsExtras.Mailbox<Message, Answer>
    ) -> [FoundationModelsExtras.Mailbox<Message, Answer>.Letter] {
        let running = Set(mailbox.depth.running)
        return letters.filter { letter in
            guard running.contains(letter.id) else { return false }
            guard cancelMarks.isMarked(letter.id) else { return true }
            mailbox.cancel(letter.id)
            return false
        }
    }

    // MARK: - Caller compactions

    /// The caller compactions that wait for the pump, first in first out.
    var pendingCompactions: [CompactionRequest] {
        compactionRequests.pending.map(\.message)
    }

    /// Takes the next caller compaction and runs it as one work of the pump.
    /// No other request joins it: each caller compaction is one work.
    private func runNextCallerCompaction() async {
        await answerNextBatch(of: compactionRequests, joining: { _, _ in false }) { letters in
            try await runCallerCompaction(of: letters)
        }
    }

    /// Runs one caller compaction.
    ///
    /// - Parameter letters: The batch of the compaction mailbox: one request.
    /// - Returns: The result of the compaction.
    /// - Throws: What the compaction throws, or `CancellationError` when the
    ///   caller was cancelled before the compaction started.
    private func runCallerCompaction(of letters: [CompactionRequestMailbox.Letter]) async throws -> CompactionResult {
        // No suspension point between the read of the cancel mark and the
        // work that holds the request (``liveLetters(_:of:)``).
        guard let letter = liveLetters(letters, of: compactionRequests).first else {
            throw CancellationError()
        }
        lastWorkId += 1
        pumpWork = PumpWork(id: lastWorkId, kind: .compaction(requestID: letter.id))
        defer { endPumpWork() }
        await attachOutboxJournalIfNeeded()
        let request = letter.message
        return try await ServiceContext.$current.withValue(request.serviceContext) {
            try await compactOwnModel(prompt: request.prompt, budget: request.budget)
        }
    }
}
