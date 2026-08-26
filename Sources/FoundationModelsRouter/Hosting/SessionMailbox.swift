import Foundation

/// The per-session registry of background runs and the pending elicitations
/// those runs have raised.
///
/// One mailbox per session; a fork gets its own. The mailbox carries envelopes
/// (`OperationEvent`) and outcomes (`OperationOutcome`), never bulk output.
/// A background run is keyed by its completion token: a ULID string that is
/// also the run's event `correlationID` (see ``makeCompletionToken()``).
///
/// The public surface is what a host that binds its own ``ToolContext`` needs:
/// ``init()``, ``makeCompletionToken()``, ``respond(elicitationId:_:)`` and
/// ``complete(elicitationId:)``. The run-plane members are internal; a tool
/// reaches them through ``ToolContext``.
public actor SessionMailbox {
    // MARK: - Vocabulary

    /// What ``track(tool:op:kind:completionToken:settling:canceler:)`` resolved to.
    enum TrackResult: Sendable, Equatable {
        /// The run is tracked under its token.
        case tracked

        /// The token already names a running or settled run. The new run is not registered.
        case duplicateToken
    }

    /// What ``respond(elicitationId:_:)`` did with a delivered answer.
    public enum ElicitationAnswerDelivery: Sendable, Equatable {
        /// The answer resumed the awaiting run and closed the entry.
        case delivered

        /// A URL-mode accept was recorded. The run resumes when ``complete(elicitationId:)`` arrives.
        case acceptedAwaitingCompletion

        /// No pending elicitation matches the id. A safe no-op.
        case noPendingElicitation
    }

    /// What ``complete(elicitationId:)`` did.
    public enum ElicitationCompletionDelivery: Sendable, Equatable {
        /// The completion resumed the accepted URL-mode entry and closed it.
        case completed

        /// No accepted pending elicitation matches the id. A safe no-op.
        case noPendingElicitation
    }

    // MARK: - Constants

    /// The number of most recent settled terminal events retained for late
    /// `wait` and `cancel` calls. Older tokens report `unknownToken` again.
    static let settledTerminalEventRetentionLimit = 128

    /// Nanoseconds in one second.
    private static let nanosecondsPerSecond: Double = 1_000_000_000

    // MARK: - Token minting

    /// Mints a fresh completion token: a ULID string that is also the run's event `correlationID`.
    public static func makeCompletionToken() -> String {
        ULID.generate().description
    }

    // MARK: - Background-run storage

    /// One background run's bookkeeping.
    private struct BackgroundRunEntry {
        /// The fused tool's name that owns the run.
        let tool: String

        /// The canonical `"verb noun"` op string of the tracked operation.
        let op: String

        /// What kind of work the run is.
        let kind: RunKind

        /// The latest progress detail reported for the run.
        var latestProgressDetail: String?

        /// Requests cancellation with this run kind's semantics and reports the ``OperationOutcome``.
        let canceler: @Sendable () async -> OperationOutcome
    }

    /// Background runs by completion token.
    private var runsByToken: [String: BackgroundRunEntry] = [:]

    /// Completion tokens in tracking order.
    private var trackingOrder: [String] = []

    /// Terminal events of settled runs, by completion token. Bounded to the newest
    /// ``settledTerminalEventRetentionLimit`` settlements.
    private var settledTerminalEvents: [String: OperationEvent] = [:]

    /// Settled completion tokens in settlement order (the FIFO eviction order).
    private var settledOrder: [String] = []

    /// Whether a ``sweep()`` is in flight. A concurrent second sweep returns empty.
    private var isSweeping = false

    /// Continuations suspended by `wait`, keyed by completion token and then by waiter id.
    private var waiters: [String: [UUID: CheckedContinuation<WaitOutcome, Never>]] = [:]

    // MARK: - Pending-elicitation storage

    /// One pending elicitation's state.
    private enum PendingElicitation {
        /// The run waits for ``respond(elicitationId:_:)``.
        case awaitingAnswer(mode: ElicitationMode, continuation: CheckedContinuation<ElicitationResponse, Never>)

        /// A URL-mode request was accepted; the run waits for ``complete(elicitationId:)``.
        case awaitingCompletion(accepted: ElicitationResponse, continuation: CheckedContinuation<ElicitationResponse, Never>)
    }

    /// Pending elicitations by `elicitationId`.
    private var pendingElicitations: [ULID: PendingElicitation] = [:]

    /// Pending elicitation ids in registration order.
    private var elicitationOrder: [ULID] = []

    /// Creates an empty mailbox.
    public init() {}

    // MARK: - Background runs

    /// Registers a background run under `completionToken`.
    ///
    /// The mailbox observes `settling`: when the run ends, its bounded terminal
    /// event is retained and every waiter on the token resumes with it. A run
    /// already swept settles silently, so each run has exactly one terminal event.
    ///
    /// - Parameters:
    ///   - tool: The tool's name that owns the run.
    ///   - op: The canonical `"verb noun"` op string.
    ///   - kind: What kind of work the run is.
    ///   - completionToken: The run's completion token; also its event `correlationID`.
    ///   - settling: The handle that resolves to the run's terminal event.
    ///   - canceler: Requests cancellation and reports the ``OperationOutcome``.
    /// - Returns: ``TrackResult/duplicateToken`` when the token is already in use; else ``TrackResult/tracked``.
    @discardableResult
    func track(
        tool: String,
        op: String,
        kind: RunKind,
        completionToken: String,
        settling: Task<OperationEvent, Never>,
        canceler: @escaping @Sendable () async -> OperationOutcome
    ) -> TrackResult {
        guard runsByToken[completionToken] == nil, settledTerminalEvents[completionToken] == nil else {
            return .duplicateToken
        }
        runsByToken[completionToken] = BackgroundRunEntry(
            tool: tool,
            op: op,
            kind: kind,
            latestProgressDetail: nil,
            canceler: canceler
        )
        trackingOrder.append(completionToken)
        Task { [weak self] in
            let terminal = await settling.value
            await self?.markSettled(completionToken: completionToken, terminal: terminal)
        }
        return .tracked
    }

    /// Records the latest progress detail for a background run. Unknown token: a safe no-op.
    func updateProgress(completionToken: String, detail: String) {
        runsByToken[completionToken]?.latestProgressDetail = detail
    }

    /// A snapshot of every background run, in tracking order. Envelopes only, never bulk output.
    func backgroundRuns() -> [BackgroundRun] {
        trackingOrder.compactMap { token in
            runsByToken[token].map { run in
                BackgroundRun(
                    completionToken: token,
                    tool: run.tool,
                    op: run.op,
                    kind: run.kind,
                    latestProgressDetail: run.latestProgressDetail
                )
            }
        }
    }

    /// Awaits a run's settlement with a deadline.
    ///
    /// A run that already settled resolves immediately. An unknown token is a safe no-op.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token.
    ///   - seconds: The deadline. NaN and negative values floor to zero; values
    ///     above ``ToolContext/deadlineSecondsCeiling`` are capped there.
    /// - Returns: The ``WaitOutcome``.
    func wait(completionToken: String, seconds: Double) async -> WaitOutcome {
        if let terminal = settledTerminalEvents[completionToken] {
            return .settled(terminal)
        }
        guard runsByToken[completionToken] != nil else {
            return .unknownToken
        }
        let deadline = Self.boundedNanoseconds(clamping: seconds)
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            waiters[completionToken, default: [:]][waiterID] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: deadline)
                await self?.expireWaiter(completionToken: completionToken, waiterID: waiterID)
            }
        }
    }

    /// Invokes a background run's canceler and reports its outcome verbatim.
    /// The run stays running until it settles.
    ///
    /// - Returns: ``CancelOutcome/reported(_:)``; ``CancelOutcome/alreadySettled(_:)``
    ///   when the run settled before the cancel; or ``CancelOutcome/unknownToken``.
    func cancel(completionToken: String) async -> CancelOutcome {
        if let terminal = settledTerminalEvents[completionToken] {
            return .alreadySettled(terminal)
        }
        guard let run = runsByToken[completionToken] else {
            return .unknownToken
        }
        return .reported(await run.canceler())
    }

    // MARK: - Pending elicitations

    /// Suspends the calling run until its elicitation is answered. An accepted
    /// URL-mode request also waits for ``complete(elicitationId:)``.
    ///
    /// The pending entry is registered before `posting` runs. A duplicate
    /// `elicitationId` is rejected with ``ElicitationResponse/cancel`` and
    /// `posting` does not run.
    ///
    /// - Parameters:
    ///   - request: The request whose `elicitationId` keys the entry.
    ///   - posting: The upstream delivery of the request. Defaults to nothing.
    /// - Returns: The user's answer.
    func awaitAnswer(
        to request: ElicitationRequest,
        posting: @escaping @Sendable () async -> Void = {}
    ) async -> ElicitationResponse {
        await withCheckedContinuation { continuation in
            guard pendingElicitations[request.elicitationId] == nil else {
                continuation.resume(returning: .cancel)
                return
            }
            pendingElicitations[request.elicitationId] = .awaitingAnswer(mode: request.mode, continuation: continuation)
            elicitationOrder.append(request.elicitationId)
            Task {
                await posting()
            }
        }
    }

    /// The ids of every pending elicitation, in registration order.
    func pendingElicitationIds() -> [ULID] {
        elicitationOrder.filter { pendingElicitations[$0] != nil }
    }

    /// Delivers the user's answer to a pending elicitation.
    ///
    /// A URL-mode accept keeps the entry open until ``complete(elicitationId:)``
    /// arrives. Every other answer resumes the run and closes the entry.
    /// Unknown and already-answered ids are safe no-ops.
    ///
    /// - Returns: The ``ElicitationAnswerDelivery``.
    @discardableResult
    public func respond(elicitationId: ULID, _ response: ElicitationResponse) -> ElicitationAnswerDelivery {
        guard let entry = pendingElicitations[elicitationId] else {
            return .noPendingElicitation
        }
        switch entry {
        case .awaitingAnswer(let mode, let continuation):
            if mode == .url && response.action == .accept {
                pendingElicitations[elicitationId] = .awaitingCompletion(accepted: response, continuation: continuation)
                return .acceptedAwaitingCompletion
            }
            removeElicitation(elicitationId)
            continuation.resume(returning: response)
            return .delivered
        case .awaitingCompletion:
            return .noPendingElicitation
        }
    }

    /// Signals that an accepted URL-mode elicitation's flow finished and resumes
    /// the run. Unknown, completed, and not-yet-accepted ids are safe no-ops.
    ///
    /// - Returns: The ``ElicitationCompletionDelivery``.
    @discardableResult
    public func complete(elicitationId: ULID) -> ElicitationCompletionDelivery {
        guard case .awaitingCompletion(let accepted, let continuation)? = pendingElicitations[elicitationId] else {
            return .noPendingElicitation
        }
        removeElicitation(elicitationId)
        continuation.resume(returning: accepted)
        return .completed
    }

    // MARK: - Teardown sweep

    /// The session-teardown sweep: cancels each background run in tracking order,
    /// produces exactly one terminal event per run, then rejects every pending
    /// elicitation with ``ElicitationResponse/cancel``.
    ///
    /// - Returns: One terminal event per run tracked when the sweep began. A
    ///   sweep that arrives while another is in flight returns empty.
    func sweep() async -> [OperationEvent] {
        guard !isSweeping else { return [] }
        isSweeping = true
        defer { isSweeping = false }
        var terminals: [OperationEvent] = []
        let tokens = trackingOrder
        for token in tokens {
            guard let run = runsByToken[token] else {
                continue
            }
            let outcome = await run.canceler()
            // The canceler await suspends this actor, so the run may have
            // settled naturally in the meantime — its natural terminal event
            // is the one true terminal then, never a second synthesized one.
            if let natural = settledTerminalEvents[token] {
                terminals.append(natural)
                continue
            }
            let synthesized = boundingDetail(
                OperationEvent(
                    tool: run.tool,
                    op: run.op,
                    correlationID: token,
                    kind: .completed,
                    detail: run.latestProgressDetail ?? "",
                    outcome: outcome
                )
            )
            runsByToken.removeValue(forKey: token)
            trackingOrder.removeAll { $0 == token }
            retainSettledTerminalEvent(synthesized, for: token)
            resumeWaiters(for: token, with: .settled(synthesized))
            terminals.append(synthesized)
        }
        for elicitationId in elicitationOrder {
            guard let entry = pendingElicitations.removeValue(forKey: elicitationId) else {
                continue
            }
            switch entry {
            case .awaitingAnswer(_, let continuation), .awaitingCompletion(_, let continuation):
                continuation.resume(returning: .cancel)
            }
        }
        elicitationOrder.removeAll()
        return terminals
    }

    // MARK: - Private helpers

    /// Removes one pending elicitation's entry and its registration-order slot.
    private func removeElicitation(_ elicitationId: ULID) {
        pendingElicitations.removeValue(forKey: elicitationId)
        elicitationOrder.removeAll { $0 == elicitationId }
    }

    /// Records a run's natural settlement and resumes its waiters. An already
    /// swept token is dropped.
    private func markSettled(completionToken: String, terminal: OperationEvent) {
        guard runsByToken.removeValue(forKey: completionToken) != nil else {
            return
        }
        trackingOrder.removeAll { $0 == completionToken }
        let bounded = boundingDetail(terminal)
        retainSettledTerminalEvent(bounded, for: completionToken)
        resumeWaiters(for: completionToken, with: .settled(bounded))
    }

    /// Retains a settled run's terminal event with bounded FIFO retention.
    private func retainSettledTerminalEvent(_ terminal: OperationEvent, for completionToken: String) {
        settledTerminalEvents[completionToken] = terminal
        settledOrder.append(completionToken)
        while settledOrder.count > Self.settledTerminalEventRetentionLimit {
            let evicted = settledOrder.removeFirst()
            settledTerminalEvents.removeValue(forKey: evicted)
        }
    }

    /// Clamps a seconds value to a safe nanosecond count: NaN and negative values
    /// floor to zero; values above ``ToolContext/deadlineSecondsCeiling`` cap there.
    static func boundedNanoseconds(clamping seconds: Double) -> UInt64 {
        guard !seconds.isNaN else { return 0 }
        let clamped = min(max(seconds, 0), ToolContext.deadlineSecondsCeiling)
        return UInt64(clamped * nanosecondsPerSecond)
    }

    /// Resumes one still-suspended waiter with ``WaitOutcome/deadlineElapsed``.
    private func expireWaiter(completionToken: String, waiterID: UUID) {
        guard let continuation = waiters[completionToken]?.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(returning: .deadlineElapsed)
    }

    /// Resumes every waiter suspended on `completionToken` with `result`.
    private func resumeWaiters(for completionToken: String, with result: WaitOutcome) {
        guard let suspended = waiters.removeValue(forKey: completionToken) else {
            return
        }
        for continuation in suspended.values {
            continuation.resume(returning: result)
        }
    }

    /// Returns `event` with its `detail` truncated to the trailing
    /// ``ToolContext/terminalDetailTailLimit`` characters.
    private func boundingDetail(_ event: OperationEvent) -> OperationEvent {
        guard event.detail.count > ToolContext.terminalDetailTailLimit else {
            return event
        }
        return OperationEvent(
            tool: event.tool,
            op: event.op,
            correlationID: event.correlationID,
            kind: event.kind,
            detail: String(event.detail.suffix(ToolContext.terminalDetailTailLimit)),
            outcome: event.outcome,
            elicitation: event.elicitation
        )
    }
}
