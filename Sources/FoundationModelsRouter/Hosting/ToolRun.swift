import Foundation
import FoundationModels
import Synchronization

/// One call's correlation and body, shared by ``RunToCompletionRunner`` and ``BackgroundToolRunner``.
struct ToolRun<Arguments: ConvertibleFromGeneratedContent & Sendable>: Sendable {
    private let wrapped: any Tool<Arguments, String>

    private let sink: any OperationEventSink

    /// The context bound around the body; its `completionToken` is the run's key.
    let context: ToolContext

    /// The run's single posting funnel.
    let funnel: RunEventFunnel

    private let cancellationFlag: CancellationRequestFlag

    /// The records the tool attaches through ``ToolContext/attach(_:)``,
    /// drained into the settlement when the call closes.
    private let attachmentBox: ToolCallAttachmentBox

    private let stopReport = AuthoritativeStopReport()

    private let timeoutSeconds: TimeInterval?

    private let openRecord: ToolInvocationRecord

    /// Prepares one call. The tool's per-call timeout wins over `mountTimeout`.
    init(
        wrapped: any Tool<Arguments, String>,
        arguments: Arguments,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        op: String?,
        mountTimeout: TimeInterval?
    ) {
        let completionToken = SessionMailbox.makeCompletionToken()
        let cancellationFlag = CancellationRequestFlag()
        let attachmentBox = ToolCallAttachmentBox()
        let funnel = RunEventFunnel(upstream: sink, mailbox: mailbox, completionToken: completionToken)
        let context = ToolContext(
            stamping: wrapped,
            op: op,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: funnel,
            completionToken: completionToken,
            isCancelled: { cancellationFlag.isRequested },
            attachmentSink: { attachmentBox.append($0) }
        )
        self.wrapped = wrapped
        self.sink = sink
        self.context = context
        self.funnel = funnel
        self.cancellationFlag = cancellationFlag
        self.attachmentBox = attachmentBox
        self.timeoutSeconds = Self.perCallTimeout(of: wrapped, from: arguments) ?? mountTimeout
        self.openRecord = ToolInvocationRecord(
            tool: context.tool,
            op: context.op,
            correlationID: completionToken,
            sessionID: sessionID,
            openedAt: Date()
        )
    }

    /// The per-call timeout `wrapped` supplies, or `nil`.
    private static func perCallTimeout(
        of wrapped: any Tool<Arguments, String>, from arguments: Arguments
    ) -> TimeInterval? {
        guard
            let provider = wrapped as? any BackgroundTool,
            let convertible = arguments as? any ConvertibleToGeneratedContent
        else {
            return nil
        }
        return provider.timeout(from: convertible.generatedContent)
    }

    /// Posts the open invocation record and awaits its delivery.
    func open() async {
        await sink.post(invocation: openRecord)
    }

    /// Raises the cooperative cancellation flag behind ``ToolContext/isCancelled``.
    func requestCancellation() {
        cancellationFlag.request()
    }

    /// Runs the tool's own authoritative `canceler` and reports its outcome.
    /// The terminal event carries that outcome, whatever the body then returns.
    func stop(using canceler: @Sendable () async -> OperationOutcome) async -> OperationOutcome {
        stopReport.begin()
        let outcome = await canceler()
        stopReport.report(outcome: outcome)
        return outcome
    }

    /// Runs the body under the bound context, settles the funnel with one
    /// terminal, and posts the close invocation record.
    func execute(arguments: Arguments) async -> RunSettlement {
        let settlement = await ToolContext.$current.withValue(context) {
            await settle(arguments: arguments)
        }
        await sink.post(invocation: openRecord.closed(at: Date()))
        return settlement
    }

    /// Calls the wrapped tool raced against the timeout and settles the funnel.
    private func settle(arguments: Arguments) async -> RunSettlement {
        // Created inside the ToolContext binding, so the inner call inherits it.
        let inner = Task { try await wrapped.call(arguments: arguments) }
        let result = await withTaskCancellationHandler {
            await raceAgainstTimeout(inner: inner)
        } onCancel: {
            cancellationFlag.request()
            inner.cancel()
        }
        // Drained after the call returns. A record the tool attaches later
        // than this point belongs to no settlement, and is dropped.
        let attachments = attachmentBox.drain()
        let facts = Self.terminalFacts(for: result, stoppedAs: await stopReport.outcome())
        let terminal = OperationEvent(
            tool: context.tool,
            op: context.op,
            correlationID: context.completionToken,
            kind: .completed,
            detail: facts.detail,
            outcome: facts.outcome
        )
        await funnel.settleRun(with: terminal)
        return RunSettlement(result: result, terminal: terminal, attachments: attachments)
    }

    /// Races `inner` against the resettable timeout. Expiry cancels `inner`
    /// and resolves as ``ToolMountError/timedOut(tool:timeoutSeconds:)``.
    private func raceAgainstTimeout(inner: Task<String, any Error>) async -> Result<String, any Error> {
        guard let timeoutSeconds else {
            return await inner.result
        }
        let gate = RaceGate<TimeoutRaceOutcome>()
        Task {
            gate.resume(with: .finished(await inner.result))
        }
        let watcher = Task {
            if await Self.watchForTimeout(funnel: funnel, timeoutSeconds: timeoutSeconds) {
                gate.resume(with: .timedOut)
            }
        }
        let outcome = await withCheckedContinuation { gate.register(continuation: $0) }
        watcher.cancel()
        switch outcome {
        case .finished(let result):
            return result
        case .timedOut:
            cancellationFlag.request()
            inner.cancel()
            return .failure(
                ToolMountError.timedOut(tool: context.tool, timeoutSeconds: timeoutSeconds)
            )
        }
    }

    /// Sleeps in full-`timeout` windows until one elapses with no progress and no pending elicitation.
    /// - Returns: `true` when the call timed out; `false` when the watcher was cancelled.
    private static func watchForTimeout(
        funnel: RunEventFunnel, timeoutSeconds: TimeInterval
    ) async -> Bool {
        let window = SessionMailbox.boundedNanoseconds(clamping: timeoutSeconds)
        while true {
            let before = await funnel.timeoutCheckpoint()
            do {
                try await Task.sleep(nanoseconds: window)
            } catch {
                return false
            }
            let after = await funnel.timeoutCheckpoint()
            // Progress in the window, or a pending elicitation, proves the
            // call alive: sleep another full window.
            guard after.resetCount == before.resetCount, !after.isElicitationPending else {
                continue
            }
            return true
        }
    }

    /// The terminal outcome and detail. An authoritative stop's outcome
    /// replaces the in-band one; the in-band detail is kept.
    private static func terminalFacts(
        for result: Result<String, any Error>, stoppedAs stop: OperationOutcome?
    ) -> (outcome: OperationOutcome, detail: String) {
        let inBand = inBandFacts(for: result)
        guard let stop else {
            return inBand
        }
        return (stop, inBand.detail)
    }

    /// Maps an in-band result to its terminal outcome and detail.
    private static func inBandFacts(
        for result: Result<String, any Error>
    ) -> (outcome: OperationOutcome, detail: String) {
        switch result {
        case .success(let output):
            return (.succeeded, output)
        case .failure(let error):
            if error is CancellationError {
                return (.cancelled, String(describing: error))
            }
            if case ToolMountError.timedOut = error {
                return (.timedOut, String(describing: error))
            }
            if error is any LostRunError {
                return (.lost, String(describing: error))
            }
            return (.failed, String(describing: error))
        }
    }
}

/// How one run's body ended: the in-band result, the terminal event, and the
/// records the call attached.
struct RunSettlement: Sendable {
    /// The wrapped tool's output, or the error that ended the call.
    let result: Result<String, any Error>

    /// The run's terminal event, already funneled upstream.
    let terminal: OperationEvent

    /// The records the tool attached through ``ToolContext/attach(_:)``, in
    /// call order.
    let attachments: [ToolCallAttachment]
}

/// The records one call attaches: the tool appends them, and the run drains
/// them one time when the call closes.
final class ToolCallAttachmentBox: Sendable {
    private let collected = Mutex<[ToolCallAttachment]>([])

    /// Appends `attachment` after every record appended before it.
    func append(_ attachment: ToolCallAttachment) {
        collected.withLock { $0.append(attachment) }
    }

    /// Removes and returns every record appended so far, in call order.
    func drain() -> [ToolCallAttachment] {
        collected.withLock { records in
            let drained = records
            records.removeAll()
            return drained
        }
    }
}

/// Whichever of the inner call's completion or the timeout arrives first.
private enum TimeoutRaceOutcome: Sendable {
    /// The inner call finished with this result.
    case finished(Result<String, any Error>)

    /// A full timeout window elapsed with no progress and no pending elicitation.
    case timedOut
}

/// A sticky request-for-cancellation flag, never cleared once set.
final class CancellationRequestFlag: Sendable {
    private let requested = Mutex(false)

    /// Records the request.
    func request() {
        requested.withLock { $0 = true }
    }

    /// Whether cancellation has been requested.
    var isRequested: Bool {
        requested.withLock { $0 }
    }
}

/// The outcome a run's authoritative canceler reports, handed to the body's
/// settlement. A settlement that arrives while the report is pending waits for it.
final class AuthoritativeStopReport: Sendable {
    private let isPending = Mutex(false)

    private let gate = RaceGate<OperationOutcome>()

    /// Marks a report pending, so ``outcome()`` waits for ``report(outcome:)``.
    func begin() {
        isPending.withLock { $0 = true }
    }

    /// Records the canceler's outcome and resumes a waiting ``outcome()``.
    func report(outcome: OperationOutcome) {
        gate.resume(with: outcome)
    }

    /// The reported outcome, awaited while pending; `nil` when no stop began.
    func outcome() async -> OperationOutcome? {
        guard isPending.withLock({ $0 }) else {
            return nil
        }
        return await withCheckedContinuation { gate.register(continuation: $0) }
    }
}

/// One run's single posting funnel. It enforces one `.completed` per run,
/// holds the deadline state the timeout watcher compares, and chains upstream deliveries FIFO.
actor RunEventFunnel: OperationEventSink {
    /// One timeout-loop observation.
    struct TimeoutCheckpoint: Sendable, Equatable {
        /// Bumped by every progress event and every elicitation resolution.
        let resetCount: Int

        /// Whether any elicitation this run posted is still pending.
        let isElicitationPending: Bool
    }

    private let upstream: any OperationEventSink

    private let mailbox: SessionMailbox

    private let completionToken: String

    private var hasDeliveredAnyEvent = false

    private var hasDeliveredTerminal = false

    private var deadlineResetCount = 0

    private var trackedElicitationIds: Set<ULID> = []

    private var deliveryChain = SerialAsyncChain()

    /// Creates the funnel for one run.
    init(upstream: any OperationEventSink, mailbox: SessionMailbox, completionToken: String) {
        self.upstream = upstream
        self.mailbox = mailbox
        self.completionToken = completionToken
    }

    /// Records deadline state, then forwards `event` upstream. A second terminal is dropped.
    func post(event: OperationEvent) async {
        switch event.kind {
        case .completed:
            guard !hasDeliveredTerminal else { return }
            hasDeliveredTerminal = true
        case .progress:
            deadlineResetCount += 1
        case .elicitation:
            if let elicitationId = event.elicitation?.elicitationId {
                trackedElicitationIds.insert(elicitationId)
            }
        }
        hasDeliveredAnyEvent = true
        let delivery = enqueueUpstream(event: event)
        if event.kind == .progress {
            await mailbox.updateProgress(completionToken: completionToken, detail: event.detail)
        }
        await delivery.value
    }

    /// Delivers `terminal` upstream when no terminal has passed yet and the
    /// run either posted any event or ended abnormally.
    func settleRun(with terminal: OperationEvent) async {
        let mustDeliver =
            !hasDeliveredTerminal && (hasDeliveredAnyEvent || terminal.outcome != .succeeded)
        guard mustDeliver else {
            return
        }
        hasDeliveredTerminal = true
        hasDeliveredAnyEvent = true
        await enqueueUpstream(event: terminal).value
    }

    /// One timeout-loop observation. An elicitation resolved since the last look bumps the reset count.
    func timeoutCheckpoint() async -> TimeoutCheckpoint {
        let tracked = trackedElicitationIds
        if !tracked.isEmpty {
            let stillPending = Set(await mailbox.pendingElicitationIds())
            let resolved = tracked.subtracting(stillPending)
            if !resolved.isEmpty {
                deadlineResetCount += 1
                trackedElicitationIds.subtract(resolved)
            }
        }
        return TimeoutCheckpoint(
            resetCount: deadlineResetCount,
            isElicitationPending: !trackedElicitationIds.isEmpty
        )
    }

    /// Chains one upstream delivery onto ``deliveryChain`` and returns it.
    private func enqueueUpstream(event: OperationEvent) -> Task<Void, Never> {
        let upstream = self.upstream
        return deliveryChain.enqueue { await upstream.post(event: event) }
    }
}
