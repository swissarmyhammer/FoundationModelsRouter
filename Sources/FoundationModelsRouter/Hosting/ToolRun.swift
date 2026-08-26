import Foundation
import FoundationModels
import Synchronization

/// One call's correlation and body, shared by ``RunToCompletionTool`` and
/// ``BackgroundTool``: the completion token, the cancellation flag, the
/// event funnel, the bound ``ToolContext``, and the invocation records
/// around the work.
struct ToolRun<Arguments: ConvertibleFromGeneratedContent & Sendable>: Sendable {
    /// The wrapped tool the body calls.
    private let wrapped: any Tool<Arguments, String>

    /// The upstream sink the invocation records are posted to.
    private let sink: any OperationEventSink

    /// The context bound around the body; its `completionToken` is the run's key.
    let context: ToolContext

    /// The run's single posting funnel.
    let funnel: RunEventFunnel

    /// The sticky request flag behind ``ToolContext/isCancelled``.
    private let cancellationFlag: CancellationRequestFlag

    /// How long the body may run with no progress, or `nil` for no clock.
    private let timeoutSeconds: TimeInterval?

    /// The open invocation record; its close is posted when the body ends.
    private let openRecord: ToolInvocationRecord

    /// Prepares one call: mints the token, builds the funnel and context,
    /// and resolves the timeout — the tool's per-call value over `mountTimeout`.
    ///
    /// - Parameters:
    ///   - wrapped: The wrapped tool.
    ///   - arguments: The call's arguments, read for a per-call timeout.
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink for events and invocation records.
    ///   - op: The registration site's `"verb noun"` op, or `nil`.
    ///   - mountTimeout: The mount's timeout, or `nil` for no clock.
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
        let funnel = RunEventFunnel(upstream: sink, mailbox: mailbox, completionToken: completionToken)
        let context = ToolContext(
            stamping: wrapped,
            op: op,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: funnel,
            completionToken: completionToken,
            isCancelled: { cancellationFlag.isRequested }
        )
        self.wrapped = wrapped
        self.sink = sink
        self.context = context
        self.funnel = funnel
        self.cancellationFlag = cancellationFlag
        self.timeoutSeconds = Self.perCallTimeout(of: wrapped, from: arguments) ?? mountTimeout
        self.openRecord = ToolInvocationRecord(
            tool: context.tool,
            op: context.op,
            correlationID: completionToken,
            sessionID: sessionID,
            openedAt: Date()
        )
    }

    /// The per-call timeout `wrapped` supplies through
    /// ``DetachmentParameterProviding/detachmentTimeout(from:)``, or `nil`.
    private static func perCallTimeout(
        of wrapped: any Tool<Arguments, String>, from arguments: Arguments
    ) -> TimeInterval? {
        guard
            let provider = wrapped as? any DetachmentParameterProviding,
            let convertible = arguments as? any ConvertibleToGeneratedContent
        else {
            return nil
        }
        return provider.detachmentTimeout(from: convertible.generatedContent)
    }

    /// Posts the open invocation record, awaited to delivery, so a live
    /// consumer sees the invocation before the work starts.
    func open() async {
        await sink.post(invocation: openRecord)
    }

    /// Raises the cooperative cancellation flag the tool reads as
    /// ``ToolContext/isCancelled``.
    func requestCancellation() {
        cancellationFlag.request()
    }

    /// Runs the body under the bound context: calls the wrapped tool raced
    /// against the timeout, settles the funnel with exactly one terminal,
    /// and posts the close invocation record.
    ///
    /// - Parameter arguments: The call's arguments, forwarded untouched.
    /// - Returns: The in-band result and the run's terminal event.
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
        let facts = Self.terminalFacts(for: result)
        let terminal = OperationEvent(
            tool: context.tool,
            op: context.op,
            correlationID: context.completionToken,
            kind: .completed,
            detail: facts.detail,
            outcome: facts.outcome
        )
        await funnel.settleRun(with: terminal)
        return RunSettlement(result: result, terminal: terminal)
    }

    /// Races `inner` against the resettable timeout through a ``RaceGate``.
    /// A `nil` timeout starts no watcher. Expiry cancels `inner` and resolves
    /// as ``DetachingToolError/timedOut(tool:timeoutSeconds:)``.
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
                DetachingToolError.timedOut(tool: context.tool, timeoutSeconds: timeoutSeconds)
            )
        }
    }

    /// Sleeps in full-`timeout` windows until one elapses with no progress
    /// and no pending elicitation.
    ///
    /// - Returns: `true` when the call timed out; `false` when the watcher
    ///   was cancelled because the race already resolved.
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

    /// Maps an in-band result to its terminal outcome and detail.
    private static func terminalFacts(
        for result: Result<String, any Error>
    ) -> (outcome: OperationOutcome, detail: String) {
        switch result {
        case .success(let output):
            return (.succeeded, output)
        case .failure(let error):
            if error is CancellationError {
                return (.cancelled, String(describing: error))
            }
            if case DetachingToolError.timedOut = error {
                return (.timedOut, String(describing: error))
            }
            return (.failed, String(describing: error))
        }
    }
}

/// How one run's body ended: the in-band result and the terminal event.
struct RunSettlement: Sendable {
    /// The wrapped tool's output, or the error that ended the call.
    let result: Result<String, any Error>

    /// The run's terminal event, already funneled upstream.
    let terminal: OperationEvent
}

/// Whichever of the inner call's completion or the timeout arrives first.
private enum TimeoutRaceOutcome: Sendable {
    /// The inner call finished with this result.
    case finished(Result<String, any Error>)

    /// A full timeout window elapsed with no progress and no pending elicitation.
    case timedOut
}

/// A sticky request-for-cancellation flag: set by a canceler, the timeout,
/// or the calling task's own cancellation, and never cleared. The probe
/// behind ``ToolContext/isCancelled`` in every per-call binding layer.
final class CancellationRequestFlag: Sendable {
    /// Whether cancellation has been requested.
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

/// One run's single posting funnel: every event the run produces passes
/// through here, which is what makes "exactly one `.completed` per run"
/// enforceable. Also the deadline state the timeout watcher compares:
/// progress bumps the reset count, and a pending elicitation suspends the
/// timeout. Upstream deliveries are FIFO-chained.
actor RunEventFunnel: OperationEventSink {
    /// One timeout-loop observation.
    struct TimeoutCheckpoint: Sendable, Equatable {
        /// Bumped by every progress event and every elicitation resolution.
        let resetCount: Int

        /// Whether any elicitation this run posted is still pending.
        let isElicitationPending: Bool
    }

    /// The sink every delivery forwards to.
    private let upstream: any OperationEventSink

    /// The session's mailbox: progress feeds its run-plane snapshot, and
    /// pending elicitations are reconciled against it.
    private let mailbox: SessionMailbox

    /// The run's completion token.
    private let completionToken: String

    /// Whether any event has been delivered upstream for this run.
    private var hasDeliveredAnyEvent = false

    /// Whether a terminal event has been delivered upstream for this run.
    private var hasDeliveredTerminal = false

    /// Bumped by progress and by elicitation resolutions.
    private var deadlineResetCount = 0

    /// The elicitation ids this run posted that were pending at last look.
    private var trackedElicitationIds: Set<ULID> = []

    /// The FIFO chain every upstream delivery is enqueued onto.
    private var deliveryChain = SerialAsyncChain()

    /// Creates the funnel for one run.
    ///
    /// - Parameters:
    ///   - upstream: The sink every delivery forwards to.
    ///   - mailbox: The session's mailbox.
    ///   - completionToken: The run's completion token.
    init(upstream: any OperationEventSink, mailbox: SessionMailbox, completionToken: String) {
        self.upstream = upstream
        self.mailbox = mailbox
        self.completionToken = completionToken
    }

    /// Records what the deadline and synthesis need, then forwards `event`
    /// upstream — except a second terminal for the run, which is dropped.
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

    /// Delivers `terminal` upstream iff no terminal has passed yet and the
    /// run either posted any event or ended abnormally. A silent, successful
    /// run posts nothing at all.
    ///
    /// - Parameter terminal: The synthesized terminal event.
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

    /// One timeout-loop observation. An elicitation that resolved since the
    /// last look bumps the reset count, so the time a question took is never
    /// counted as a stall.
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

    /// Chains one upstream delivery onto ``deliveryChain`` and returns it for
    /// the caller to await.
    private func enqueueUpstream(event: OperationEvent) -> Task<Void, Never> {
        let upstream = self.upstream
        return deliveryChain.enqueue { await upstream.post(event: event) }
    }
}
