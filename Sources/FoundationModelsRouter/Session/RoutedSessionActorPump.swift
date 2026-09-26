import Foundation
import FoundationModels
import Tracing

/// The work that the pump of a session runs now (`generation-queue.md`,
/// section 5.4). The pump runs one work at a time, so a session never has
/// two SDK calls, and no caller waits on a lock.
struct PumpWork {
    /// What the work is.
    enum Kind {
        /// The pump takes the next batch from the outbox. It has no message
        /// yet. A cancel that arrives now still reaches the answer that the
        /// batch starts.
        case taking

        /// An answer: the chain of submissions that answers `messages`. The
        /// chain starts with one submission, and each continuation of it is
        /// one more submission (section 5.5).
        ///
        /// - Parameters:
        ///   - options: The options of every submission of the chain.
        ///   - messages: Every caller message the chain delivered so far.
        case answer(options: SubmissionOptions, messages: [SessionMessage])

        /// A compaction that a caller asked for
        /// (``RoutedSession/compact(prompt:budget:)``).
        ///
        /// - Parameter requestID: The id of the request.
        case compaction(requestID: ULID)
    }

    /// The id of the work. Ids are monotonic in their session, and the
    /// ``TurnID`` of the work carries the same number.
    let id: UInt64

    /// What the work is.
    var kind: Kind
}

/// A compaction that a caller asked for, which waits for the pump
/// (``RoutedSession/compact(prompt:budget:)``). The pump runs it between two
/// submissions, as it runs every compaction.
struct CompactionRequest: Sendable {
    /// The id of the request.
    let id = ULID.generate()

    /// The compaction prompt sent to the summarizer.
    let prompt: CompactionPrompt

    /// The token budget to compact against, or `nil` for the resolved
    /// working context of the session.
    let budget: TokenBudget?

    /// The tracing context of the caller, so the compaction span is a child
    /// of the span of the caller.
    let serviceContext: ServiceContext?

    /// The answer the caller waits for.
    let answer = PumpAnswer<CompactionResult>()
}

/// One caller of ``RoutedSession/dispatchNextPrompt()`` that found no queued
/// prompt, and waits until the pump has no work left.
struct PumpIdleWaiter {
    /// The rendezvous of the waiter and the end of the pump.
    let gate = RaceGate<String?>()

    /// The reply of the last answer that only mail started while the caller
    /// waited, or `nil`.
    var mailReply: String?
}

/// ``RoutedSessionActor``'s pump: the one task of the session that submits
/// for it (`generation-queue.md`, section 5.4).
///
/// The pump starts when a message arrives and no pump runs, and it ends when
/// no deliverable message waits. Each cycle takes every waiting message that
/// can share one submission (``SessionOutbox/takeSubmissionBatch(deliveringRunsOf:)``),
/// and runs the chain of submissions that answers them. A message that
/// arrives while a submission runs waits in the outbox for the next cycle,
/// or for the next continuation of the running answer.
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
    /// more cycle before it ends.
    ///
    /// The pump is a detached task: it inherits no task-local of the caller
    /// that woke it. So a ``ModelCallMark`` of a tool body that sent a
    /// message never reaches a submission of the pump.
    func wakePump() {
        pumpWakeRequested = true
        guard pumpTask == nil else { return }
        pumpTask = Task.detached { await self.runPump() }
    }

    /// The loop of the pump: one cycle for each work, until no work waits.
    private func runPump() async {
        while true {
            pumpWakeRequested = false
            if !pendingCompactions.isEmpty {
                await runCallerCompaction(pendingCompactions.removeFirst())
                continue
            }
            guard await runNextAnswer() || pumpWakeRequested else { break }
        }
        pumpTask = nil
        endPumpIdleWaits()
    }

    /// Takes the next batch from the outbox and runs its answer.
    ///
    /// - Returns: `false` when no deliverable message waited.
    private func runNextAnswer() async -> Bool {
        let workId = lastWorkId + 1
        pumpWork = PumpWork(id: workId, kind: .taking)
        let settledRunTokens = await mailbox.settledRunTokens()
        guard let batch = await outbox.takeSubmissionBatch(deliveringRunsOf: settledRunTokens) else {
            endPumpWork()
            return false
        }
        lastWorkId = workId
        await runAnswer(of: batch, workId: workId, settledRunTokens: settledRunTokens)
        return true
    }

    /// Runs the chain of submissions that answers `batch`, and gives its
    /// result to every caller message the chain delivered.
    ///
    /// - Parameters:
    ///   - batch: What the first submission of the chain carries.
    ///   - workId: The id of the work.
    ///   - settledRunTokens: The completion tokens whose terminal can start a
    ///     submission with no caller message.
    private func runAnswer(of batch: SubmissionBatch, workId: UInt64, settledRunTokens: Set<String>) async {
        let messages = await liveMessages(batch.messages)
        let mail = batch.events.map(\.event)
        let mailCanStart = SessionOutbox.canStartASubmission(batch.events, settledRunTokens: settledRunTokens)
        guard !messages.isEmpty || mailCanStart else {
            // Every caller of the batch was cancelled, and the mail alone
            // cannot start a submission. The mail goes back as it was.
            await outbox.putBack(untouched: batch.events)
            endPumpWork()
            return
        }
        let options = messages.first?.options ?? .mailDelivery
        pumpWork?.kind = .answer(options: options, messages: messages)
        // The limits of an answer start fresh for each answer, and a
        // continuation of the same answer keeps them.
        compactionYieldsStopped = false
        repetitionWatch.recoveriesThisTurn = 0
        let result: Result<String, any Error>
        do {
            result = .success(
                try await runFirstSubmission(carrying: messages, options: options, mail: mail, workId: workId))
        } catch {
            result = .failure(error)
        }
        let delivered = deliveredMessages ?? messages
        endPumpWork()
        await resolve(delivered, with: result, startedByMailOnly: messages.isEmpty)
    }

    /// Runs the first submission of an answer, and every continuation of it.
    ///
    /// - Parameters:
    ///   - messages: The caller messages of the first submission, or none
    ///     when only mail started it.
    ///   - options: The options of every submission of the chain. Their
    ///     token ceiling is the ceiling of each submission: every message
    ///     that the options admit named that same ceiling.
    ///   - mail: The mail events of the first submission.
    ///   - workId: The id of the work.
    /// - Returns: The final reply of the chain.
    /// - Throws: What the chain throws.
    private func runFirstSubmission(
        carrying messages: [SessionMessage], options: SubmissionOptions, mail: [OperationEvent], workId: UInt64
    ) async throws -> String {
        let first = messages.first
        let ceiling = ResponseTokenCeiling(requested: options.requestedMaxTokens, contextTokens: contextTokens)
        let work = submissionWork(for: first?.reader ?? .reply, responseTokenCeiling: ceiling)
        let ownPrompt =
            messages.isEmpty
            ? Self.settledRunDeliveryPrompt : messages.map(\.text).joined(separator: Self.messageSeparator)
        await attachOutboxJournalIfNeeded()
        await recordSessionMetaIfNeeded()
        await notifyTurnBoundaryTools()
        return try await ServiceContext.$current.withValue(first?.serviceContext) {
            try await runTurn(
                grammar: work.grammar, turnId: TurnID(workId), entryPoint: first?.entryPoint ?? .dispatch,
                promptId: messages.first { $0.entryPoint == .dispatch }?.id, pendingEvents: mail,
                ownPrompt: ownPrompt, responseTokenCeiling: ceiling, onEvent: work.onEvent, work.body)
        }
    }

    /// The caller messages the running answer delivered so far, or `nil`
    /// when no answer runs.
    private var deliveredMessages: [SessionMessage]? {
        guard case .answer(_, let messages) = pumpWork?.kind else { return nil }
        return messages
    }

    /// Takes what a continuation submission of the running answer carries:
    /// the mail that waits, and the caller messages that can share the
    /// submission (`generation-queue.md`, section 5.5). The messages join the
    /// answer, so their callers get its final reply.
    ///
    /// - Returns: The mail events, and the texts of the joining messages.
    func takeMessagesJoiningTheAnswer() async -> (events: [OperationEvent], texts: [String]) {
        guard case .answer(let options, _) = pumpWork?.kind else { return ([], []) }
        let batch = await outbox.takeJoiningBatch(options: options)
        let joining = await liveMessages(batch.messages)
        if case .answer(let options, let messages) = pumpWork?.kind {
            pumpWork?.kind = .answer(options: options, messages: messages + joining)
        }
        return (batch.events.map(\.event), joining.map(\.text))
    }

    /// The messages of `messages` whose callers are not cancelled. Each
    /// cancelled message gets `CancellationError` at once.
    ///
    /// The pump reads the cancel mark of each message here, in the same
    /// actor turn in which it makes them part of the work, so a cancel that
    /// arrives while the pump takes them is not lost.
    ///
    /// - Parameter messages: The messages the pump took.
    /// - Returns: The live messages, in order.
    private func liveMessages(_ messages: [SessionMessage]) async -> [SessionMessage] {
        let cancelled = messages.filter(\.answer.isCancelRequested)
        await resolve(cancelled, with: .failure(CancellationError()), startedByMailOnly: false)
        return messages.filter { !$0.answer.isCancelRequested }
    }

    /// Gives `result` to each message, after the dispatched state of each
    /// released queued prompt ends.
    ///
    /// - Parameters:
    ///   - messages: The messages to answer.
    ///   - result: The final result of their answer.
    ///   - startedByMailOnly: Whether only mail started the answer. Its
    ///     reply then goes to each ``RoutedSession/dispatchNextPrompt()``
    ///     caller that waits for the pump.
    func resolve(
        _ messages: [SessionMessage], with result: Result<String, any Error>, startedByMailOnly: Bool
    ) async {
        for message in messages where message.entryPoint == .dispatch {
            await outbox.finishDispatch(id: message.id)
        }
        for message in messages {
            message.answer.resolve(result)
        }
        guard startedByMailOnly, case .success(let reply) = result else { return }
        for waiterID in pumpIdleWaiters.keys {
            pumpIdleWaiters[waiterID]?.mailReply = reply
        }
    }

    /// Ends the running work: its id, and a cancel requested for it.
    private func endPumpWork() {
        pumpWork = nil
        cancelRequestedWorkId = nil
    }

    // MARK: - Caller compactions

    /// Runs one caller compaction as one work of the pump.
    ///
    /// - Parameter request: The request.
    private func runCallerCompaction(_ request: CompactionRequest) async {
        guard !request.answer.isCancelRequested else {
            request.answer.resolve(.failure(CancellationError()))
            return
        }
        lastWorkId += 1
        pumpWork = PumpWork(id: lastWorkId, kind: .compaction(requestID: request.id))
        await attachOutboxJournalIfNeeded()
        let result: Result<CompactionResult, any Error>
        do {
            result = .success(
                try await ServiceContext.$current.withValue(request.serviceContext) {
                    try await compactOwnModel(prompt: request.prompt, budget: request.budget)
                })
        } catch {
            result = .failure(error)
        }
        endPumpWork()
        request.answer.resolve(result)
    }

    /// Stops the caller compaction `request`: it leaves the list when it
    /// waits, and its work is cancelled when it runs.
    ///
    /// - Parameter request: The request whose caller was cancelled.
    func cancel(compaction request: CompactionRequest) {
        if let index = pendingCompactions.firstIndex(where: { $0.id == request.id }) {
            pendingCompactions.remove(at: index)
            request.answer.resolve(.failure(CancellationError()))
            return
        }
        guard case .compaction(let requestID) = pumpWork?.kind, requestID == request.id else { return }
        requestCancelOfRunningWork()
    }

    // MARK: - Waits for the pump

    /// Waits until the pump has no work left.
    ///
    /// - Returns: The reply of the last answer that only mail started while
    ///   this call waited, or `nil`. A cancelled caller gets `nil` at once.
    func awaitPumpIdle() async -> String? {
        let waiterID = ULID.generate()
        let waiter = PumpIdleWaiter()
        pumpIdleWaiters[waiterID] = waiter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter.gate.register(continuation: $0) }
        } onCancel: {
            waiter.gate.resume(with: nil)
        }
    }

    /// Ends every wait of ``awaitPumpIdle()``. The pump calls it when it ends.
    private func endPumpIdleWaits() {
        let waiters = Array(pumpIdleWaiters.values)
        pumpIdleWaiters.removeAll()
        for waiter in waiters {
            waiter.gate.resume(with: waiter.mailReply)
        }
    }
}
