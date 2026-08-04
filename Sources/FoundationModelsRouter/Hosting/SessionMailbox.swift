import Foundation

/// The per-session registry of detached, long-running work: parked runs a
/// caller can observe (`status()`), await (`wait(completionToken:seconds:)`),
/// and cancel (`cancel(completionToken:)`), plus the pending elicitations
/// those runs have raised.
///
/// Scope rule — identical to ``SessionOutbox``: one mailbox per session, a
/// fork gets its own fresh one, never shared, so a run parked on one session
/// can never be waited on, cancelled, or swept through another.
///
/// This is the **run plane**, deliberately distinct from the content plane:
/// the mailbox carries envelopes (`OperationEvent`) and outcomes
/// (`OperationOutcome`), never a capability's bulk output. A run's terminal
/// event `detail` is a bounded output tail (see ``terminalDetailTailLimit``)
/// plus the run's identifier — `wait(completionToken:seconds:)` returns
/// exactly that, never a full store.
///
/// A parked run is keyed by its **completion token**: a ULID string that IS
/// the run's event `correlationID` (minted through the same ULID machinery
/// behind ``SessionOutbox/ItemID`` — see ``makeCompletionToken()``), so the
/// token a caller holds and the correlation on the run's posted events are
/// one and the same identifier.
///
/// Phase 1 ships the ``RunKind/swiftTask`` run kind only; ``RunKind`` is the
/// seam where `process` (phase 2) and `mcpRequest` (phase 4) land, each
/// carrying its own cancellation semantics through the parked run's canceler
/// closure and the honest ``OperationOutcome`` vocabulary that closure must
/// report (`.cancelled` is a request, `.stopped` is certainty, `.lost` is
/// unknowable — never flattened).
///
/// Teardown is ``sweep()``, driven by ``RoutedSession/close()``: every parked
/// run's canceler is invoked with its kind's semantics and exactly one
/// terminal event per parked run is produced for the journal — no orphans, no
/// holes — and every pending elicitation is rejected.
public actor SessionMailbox {
    // MARK: - Vocabulary

    /// What kind of work a parked run is — the discriminator that selects
    /// the cancellation semantics its canceler closure carries.
    ///
    /// Phase 1 ships ``swiftTask`` only; this enum is the seam where the
    /// `process` (phase 2) and `mcpRequest` (phase 4) kinds land.
    public enum RunKind: String, Codable, Sendable, Equatable {
        /// An in-process Swift `Task`: cancellation is cooperative
        /// (`Task.cancel()`), so a canceler honestly reports
        /// ``OperationOutcome/cancelled`` — requested, the work may still be
        /// running — never ``OperationOutcome/stopped``.
        case swiftTask
    }

    /// One row of ``status()``'s run-plane snapshot: the parked run's token,
    /// op, kind, and latest progress detail — envelopes only, never bulk
    /// output.
    public struct RunStatus: Sendable, Equatable {
        /// The run's completion token — the ULID string that is also the
        /// run's event `correlationID`.
        public let completionToken: String

        /// The fused tool's name that owns the run.
        public let tool: String

        /// The canonical `"verb noun"` op string of the parked operation.
        public let op: String

        /// What kind of work the run is.
        public let kind: RunKind

        /// The latest progress detail reported for the run, or `nil` when
        /// none has been reported yet.
        public let latestProgressDetail: String?
    }

    /// What ``wait(completionToken:seconds:)`` resolved to.
    public enum WaitResult: Sendable, Equatable {
        /// The run settled; the terminal event carries the run's identifier
        /// (`correlationID`), its bounded output tail (`detail`), and its
        /// honest outcome.
        case settled(OperationEvent)

        /// The deadline elapsed before the run settled; the run stays
        /// parked.
        case deadlineElapsed

        /// No run — parked or settled — is known under this token. A safe,
        /// reportable no-op, never a throw or a crash.
        case unknownToken
    }

    /// What ``cancel(completionToken:)`` resolved to.
    public enum CancelResult: Sendable, Equatable {
        /// The canceler ran; this is the outcome it reported — verbatim,
        /// never a guess (``OperationOutcome``'s authority distinction).
        case reported(OperationOutcome)

        /// The run already settled before the cancel arrived — nothing left
        /// to cancel; the retained terminal event says how it ended. Honest
        /// where ``unknownToken`` would be a lie: the token is known, its
        /// run just finished first.
        case alreadySettled(OperationEvent)

        /// No run — parked or settled — is known under this token. A safe,
        /// reportable no-op, never a throw or a crash.
        case unknownToken
    }

    /// What ``park(tool:op:kind:completionToken:settling:canceler:)``
    /// resolved to.
    public enum ParkResult: Sendable, Equatable {
        /// The run is parked under its token.
        case parked

        /// The token already names a parked or settled run; the incumbent
        /// is left untouched and the new run is **not** registered — the
        /// caller violated token uniqueness (tokens are freshly minted
        /// ULIDs, see ``makeCompletionToken()``) and remains responsible
        /// for the refused run.
        case duplicateToken
    }

    /// What ``respond(elicitationId:_:)`` did with a delivered answer.
    public enum ElicitationAnswerDelivery: Sendable, Equatable {
        /// The answer resumed the awaiting run and closed the entry.
        case delivered

        /// A URL-mode accept was recorded, but the entry stays open — the
        /// run resumes only when ``complete(elicitationId:)`` arrives.
        case acceptedAwaitingCompletion

        /// No pending elicitation this answer applies to: the id was never
        /// registered, or the entry was already answered. A safe no-op per
        /// the MCP spec.
        case noPendingElicitation
    }

    /// What ``complete(elicitationId:)`` did.
    public enum ElicitationCompletionDelivery: Sendable, Equatable {
        /// The out-of-band flow's completion resumed the accepted URL-mode
        /// entry and closed it.
        case completed

        /// No pending elicitation this completion applies to: the id was
        /// never registered, was already completed, or has not been accepted
        /// yet. A safe no-op per the MCP spec.
        case noPendingElicitation
    }

    // MARK: - Constants

    /// The maximum character count of a terminal event's `detail` as this
    /// mailbox reports it — the bound behind "``wait(completionToken:seconds:)``
    /// returns a bounded output tail, never a capability's full store". A
    /// longer detail is truncated to its trailing `terminalDetailTailLimit`
    /// characters (the tail — the end of the output is what a caller acts
    /// on), so the run identifier plus a capped tail is all that ever leaves
    /// the run plane.
    public static let terminalDetailTailLimit = 4_096

    /// The most recent settled terminal events retained for late
    /// ``wait(completionToken:seconds:)`` and ``cancel(completionToken:)``
    /// calls, in settlement order. Retention is deliberately bounded: once
    /// more runs than this have settled, the oldest terminal events are
    /// evicted and their tokens report ``WaitResult/unknownToken`` /
    /// ``CancelResult/unknownToken`` again — a session-lifetime mailbox must
    /// not grow without bound.
    public static let settledTerminalEventRetentionLimit = 128

    /// The largest deadline ``wait(completionToken:seconds:)`` honors, in
    /// seconds (one day). A larger — or infinite — requested deadline is
    /// clamped here rather than trapped on: the run stays parked past the
    /// clamp, so a caller can simply wait again.
    public static let waitSecondsCeiling: Double = 86_400

    // MARK: - Token minting

    /// Mints a fresh completion token: a ULID string, generated through the
    /// same ULID machinery behind ``SessionOutbox/ItemID``, that the parking
    /// caller also uses as the run's event `correlationID`.
    public static func makeCompletionToken() -> String {
        ULID.generate().description
    }

    // MARK: - Parked-run storage

    /// One parked run's bookkeeping.
    private struct ParkedRun {
        /// The fused tool's name that owns the run.
        let tool: String

        /// The canonical `"verb noun"` op string of the parked operation.
        let op: String

        /// What kind of work the run is.
        let kind: RunKind

        /// The latest progress detail reported for the run.
        var latestProgressDetail: String?

        /// The settling handle: resolves to the run's terminal event when
        /// the run's own body ends.
        let settling: Task<OperationEvent, Never>

        /// Requests cancellation with this run kind's own semantics and
        /// reports the honest ``OperationOutcome`` of that request.
        let canceler: @Sendable () async -> OperationOutcome
    }

    /// Parked runs by completion token.
    private var parkedRuns: [String: ParkedRun] = [:]

    /// Completion tokens in park order, so ``status()`` and ``sweep()`` are
    /// deterministic.
    private var parkOrder: [String] = []

    /// Terminal events of settled (or swept) runs, by completion token, so a
    /// ``wait(completionToken:seconds:)`` arriving after settlement still
    /// resolves to the terminal event instead of reporting the token
    /// unknown.
    ///
    /// Bounded, not unbounded: only the newest
    /// ``settledTerminalEventRetentionLimit`` settlements are retained (FIFO
    /// eviction by ``settledOrder``), so a session-lifetime mailbox never
    /// accumulates terminal events without limit. A `wait()` or `cancel()`
    /// on an evicted token reports `unknownToken`.
    private var settledTerminalEvents: [String: OperationEvent] = [:]

    /// Settled completion tokens in settlement order — the FIFO eviction
    /// order for ``settledTerminalEvents``'s bounded retention.
    private var settledOrder: [String] = []

    /// Whether a ``sweep()`` is currently in flight, so a concurrent second
    /// sweep returns empty instead of double-invoking cancelers and
    /// double-journaling terminal events across the first sweep's canceler
    /// awaits.
    private var isSweeping = false

    /// Continuations parked by ``wait(completionToken:seconds:)``, keyed by
    /// completion token and then by a per-waiter id so a deadline can expire
    /// exactly its own waiter.
    private var waiters: [String: [UUID: CheckedContinuation<WaitResult, Never>]] = [:]

    // MARK: - Pending-elicitation storage

    /// One pending elicitation's state.
    private enum PendingElicitation {
        /// The run is suspended on ``awaitAnswer(to:)``, waiting for
        /// ``respond(elicitationId:_:)``.
        case awaitingAnswer(mode: ElicitationMode, continuation: CheckedContinuation<ElicitationResponse, Never>)

        /// A URL-mode request was accepted; the entry stays open — and the
        /// run stays suspended — until ``complete(elicitationId:)`` arrives
        /// with the out-of-band flow's completion.
        case awaitingCompletion(accepted: ElicitationResponse, continuation: CheckedContinuation<ElicitationResponse, Never>)
    }

    /// Pending elicitations by their `elicitationId` — a ULID distinct from
    /// any run's completion token, because one run can hold more than one
    /// pending elicitation at the same time.
    private var pendingElicitations: [ULID: PendingElicitation] = [:]

    /// Pending elicitation ids in registration order, so
    /// ``pendingElicitationIds()`` and ``sweep()``'s rejection pass are
    /// deterministic.
    private var elicitationOrder: [ULID] = []

    /// Creates an empty mailbox.
    public init() {}

    // MARK: - Parked runs

    /// Registers a detached run under `completionToken`.
    ///
    /// The mailbox observes `settling` in the background: when the run's own
    /// body ends, the run leaves ``status()``, its terminal event (detail
    /// bounded to ``terminalDetailTailLimit``) is retained for late
    /// ``wait(completionToken:seconds:)`` calls, and every waiter currently
    /// parked on the token resumes with it. A run that only ends because
    /// ``sweep()`` already synthesized its terminal event settles silently —
    /// exactly one terminal event per run, never two.
    ///
    /// - Parameters:
    ///   - tool: The fused tool's name that owns the run.
    ///   - op: The canonical `"verb noun"` op string of the operation.
    ///   - kind: What kind of work the run is — selects the cancellation
    ///     semantics `canceler` carries.
    ///   - completionToken: The run's completion token (see
    ///     ``makeCompletionToken()``); also the run's event `correlationID`.
    ///   - settling: The handle resolving to the run's terminal event when
    ///     its body ends.
    ///   - canceler: Requests cancellation with `kind`'s own semantics and
    ///     reports the honest ``OperationOutcome`` of that request.
    /// - Returns: ``ParkResult/parked``, or ``ParkResult/duplicateToken``
    ///   when the token already names a parked or settled run — the
    ///   incumbent is never silently overwritten (that would orphan its
    ///   canceler and settling handle, the exact hole ``sweep()`` exists to
    ///   prevent).
    @discardableResult
    public func park(
        tool: String,
        op: String,
        kind: RunKind,
        completionToken: String,
        settling: Task<OperationEvent, Never>,
        canceler: @escaping @Sendable () async -> OperationOutcome
    ) -> ParkResult {
        guard parkedRuns[completionToken] == nil, settledTerminalEvents[completionToken] == nil else {
            return .duplicateToken
        }
        parkedRuns[completionToken] = ParkedRun(
            tool: tool,
            op: op,
            kind: kind,
            latestProgressDetail: nil,
            settling: settling,
            canceler: canceler
        )
        parkOrder.append(completionToken)
        Task { [weak self] in
            let terminal = await settling.value
            await self?.markSettled(completionToken: completionToken, terminal: terminal)
        }
        return .parked
    }

    /// Records the latest progress detail for a parked run — the value
    /// ``status()`` reports. Unknown token: a safe no-op.
    ///
    /// - Parameters:
    ///   - completionToken: The parked run's completion token.
    ///   - detail: The run's newest progress detail.
    public func updateProgress(completionToken: String, detail: String) {
        parkedRuns[completionToken]?.latestProgressDetail = detail
    }

    /// A run-plane snapshot of every pending run, in park order: token, op,
    /// kind, and latest progress — envelopes only, never bulk output.
    ///
    /// - Returns: One ``RunStatus`` per still-parked run.
    public func status() -> [RunStatus] {
        parkOrder.compactMap { token in
            parkedRuns[token].map { run in
                RunStatus(
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
    /// This is the single `wait()` contract: the result is the run's
    /// terminal event — the (already capped, see ``terminalDetailTailLimit``)
    /// output tail plus the run's identifier — never a capability's full
    /// store. A run that already settled resolves immediately; an unknown
    /// token is a safe, reportable no-op.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token.
    ///   - seconds: How long to wait for settlement before reporting
    ///     ``WaitResult/deadlineElapsed``. The value arrives from outside
    ///     the process (the model-supplied `waitSeconds`), so it is clamped
    ///     rather than trusted: NaN and negative values floor to an
    ///     immediate deadline, and anything above ``waitSecondsCeiling``
    ///     (including infinity) is capped there — never a trap.
    /// - Returns: The ``WaitResult``.
    public func wait(completionToken: String, seconds: Double) async -> WaitResult {
        if let terminal = settledTerminalEvents[completionToken] {
            return .settled(terminal)
        }
        guard parkedRuns[completionToken] != nil else {
            return .unknownToken
        }
        let deadline = Self.boundedWaitNanoseconds(seconds)
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            waiters[completionToken, default: [:]][waiterID] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: deadline)
                await self?.expireWaiter(completionToken: completionToken, waiterID: waiterID)
            }
        }
    }

    /// Invokes a parked run's canceler and reports the outcome the canceler
    /// reports — verbatim, never a guess.
    ///
    /// The run stays parked until it actually settles: for a
    /// ``RunKind/swiftTask`` run cancellation is cooperative, so the body
    /// ends on its own schedule and settlement (observed by ``park``'s
    /// background observer) is what resumes any waiters with the terminal
    /// event.
    ///
    /// - Parameter completionToken: The run's completion token.
    /// - Returns: ``CancelResult/reported(_:)`` with the canceler's honest
    ///   outcome; ``CancelResult/alreadySettled(_:)`` with the retained
    ///   terminal event when the run finished before the cancel arrived; or
    ///   ``CancelResult/unknownToken`` as a safe, reportable no-op.
    public func cancel(completionToken: String) async -> CancelResult {
        if let terminal = settledTerminalEvents[completionToken] {
            return .alreadySettled(terminal)
        }
        guard let run = parkedRuns[completionToken] else {
            return .unknownToken
        }
        return .reported(await run.canceler())
    }

    // MARK: - Pending elicitations

    /// Suspends the calling run until its elicitation is answered — and, for
    /// an accepted URL-mode request, until the out-of-band flow's
    /// ``complete(elicitationId:)`` arrives (URL-mode entries stay open past
    /// accept).
    ///
    /// Registering an `elicitationId` that is already pending is a caller
    /// error; the duplicate registration is rejected immediately with
    /// ``ElicitationResponse/cancel`` rather than disturbing the entry
    /// already pending under that id.
    ///
    /// - Parameter request: The typed request whose `elicitationId` keys the
    ///   registry entry.
    /// - Returns: The user's answer — for an accepted URL-mode request,
    ///   delivered only once the flow completed.
    public func awaitAnswer(to request: ElicitationRequest) async -> ElicitationResponse {
        await withCheckedContinuation { continuation in
            guard pendingElicitations[request.elicitationId] == nil else {
                continuation.resume(returning: .cancel)
                return
            }
            pendingElicitations[request.elicitationId] = .awaitingAnswer(mode: request.mode, continuation: continuation)
            elicitationOrder.append(request.elicitationId)
        }
    }

    /// The ids of every pending elicitation, in registration order.
    ///
    /// - Returns: The pending `elicitationId`s.
    public func pendingElicitationIds() -> [ULID] {
        elicitationOrder.filter { pendingElicitations[$0] != nil }
    }

    /// Delivers the user's answer to a pending elicitation.
    ///
    /// A form-mode answer — and a URL-mode decline or cancel — resumes the
    /// awaiting run and closes the entry. A URL-mode **accept** only records
    /// the accept: the entry stays open, and the run stays suspended, until
    /// ``complete(elicitationId:)`` arrives. Unknown and already-answered
    /// ids are safe no-ops per the MCP spec.
    ///
    /// - Parameters:
    ///   - elicitationId: The id the answer addresses.
    ///   - response: The user's answer.
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

    /// Signals that an accepted URL-mode elicitation's out-of-band flow
    /// finished, resuming the run that has been suspended past the accept.
    /// Unknown, already-completed, and not-yet-accepted ids are safe no-ops
    /// per the MCP spec.
    ///
    /// - Parameter elicitationId: The id the completion addresses.
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

    /// The deterministic session-teardown sweep ``RoutedSession/close()``
    /// drives: for each parked run, in park order, invoke its canceler with
    /// that kind's own semantics and produce exactly one terminal event —
    /// then reject every pending elicitation with
    /// ``ElicitationResponse/cancel``.
    ///
    /// Exactly-one-terminal is an invariant, not a hope: a run that settles
    /// naturally while its canceler is awaited contributes its natural
    /// terminal event instead of a synthesized one, and a run that settles
    /// only after the sweep is dropped by ``park``'s observer (its token is
    /// no longer parked). Every returned event is `.completed`-kind with the
    /// run's completion token as its `correlationID`, its detail bounded to
    /// ``terminalDetailTailLimit``, and the canceler's honest outcome — so
    /// the caller can journal the whole list before the session closes, with
    /// no orphans and no holes.
    ///
    /// - Returns: One terminal event per run that was parked when the sweep
    ///   began, in park order. A sweep that arrives while another is still
    ///   in flight returns empty — the in-flight sweep already owns every
    ///   parked run's single terminal event, so a concurrent second sweep
    ///   never double-invokes a canceler or double-journals.
    public func sweep() async -> [OperationEvent] {
        guard !isSweeping else { return [] }
        isSweeping = true
        defer { isSweeping = false }
        var terminals: [OperationEvent] = []
        let tokens = parkOrder
        for token in tokens {
            guard let run = parkedRuns[token] else {
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
            parkedRuns.removeValue(forKey: token)
            parkOrder.removeAll { $0 == token }
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

    /// Removes one pending elicitation's entry and its registration-order
    /// slot.
    private func removeElicitation(_ elicitationId: ULID) {
        pendingElicitations.removeValue(forKey: elicitationId)
        elicitationOrder.removeAll { $0 == elicitationId }
    }

    /// Records a run's natural settlement: removes it from the parked set,
    /// retains its (detail-bounded) terminal event, and resumes every waiter
    /// parked on its token. A token no longer parked — already swept — is
    /// dropped, preserving exactly-one-terminal.
    private func markSettled(completionToken: String, terminal: OperationEvent) {
        guard parkedRuns.removeValue(forKey: completionToken) != nil else {
            return
        }
        parkOrder.removeAll { $0 == completionToken }
        let bounded = boundingDetail(terminal)
        retainSettledTerminalEvent(bounded, for: completionToken)
        resumeWaiters(for: completionToken, with: .settled(bounded))
    }

    /// Retains a settled run's terminal event under bounded FIFO retention:
    /// the token joins ``settledOrder`` and, once more than
    /// ``settledTerminalEventRetentionLimit`` settlements are held, the
    /// oldest are evicted — their tokens report `unknownToken` again.
    private func retainSettledTerminalEvent(_ terminal: OperationEvent, for completionToken: String) {
        settledTerminalEvents[completionToken] = terminal
        settledOrder.append(completionToken)
        while settledOrder.count > Self.settledTerminalEventRetentionLimit {
            let evicted = settledOrder.removeFirst()
            settledTerminalEvents.removeValue(forKey: evicted)
        }
    }

    /// Clamps a caller-supplied wait deadline to a representable, safe
    /// nanosecond count: NaN and negative values floor to zero and anything
    /// above ``waitSecondsCeiling`` (including infinity) caps there, so no
    /// outside-supplied value can trap the `UInt64` conversion.
    private static func boundedWaitNanoseconds(_ seconds: Double) -> UInt64 {
        guard !seconds.isNaN else { return 0 }
        let clamped = min(max(seconds, 0), waitSecondsCeiling)
        return UInt64(clamped * 1_000_000_000)
    }

    /// Expires one waiter's deadline: if it is still parked, resumes it with
    /// ``WaitResult/deadlineElapsed``; a waiter already resumed by
    /// settlement is left alone.
    private func expireWaiter(completionToken: String, waiterID: UUID) {
        guard let continuation = waiters[completionToken]?.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(returning: .deadlineElapsed)
    }

    /// Resumes every waiter parked on `completionToken` with `result`.
    private func resumeWaiters(for completionToken: String, with result: WaitResult) {
        guard let parked = waiters.removeValue(forKey: completionToken) else {
            return
        }
        for continuation in parked.values {
            continuation.resume(returning: result)
        }
    }

    /// Returns `event` with its `detail` truncated to the trailing
    /// ``terminalDetailTailLimit`` characters — the bounded output tail the
    /// run plane carries — or `event` unchanged when already within bounds.
    private func boundingDetail(_ event: OperationEvent) -> OperationEvent {
        guard event.detail.count > Self.terminalDetailTailLimit else {
            return event
        }
        return OperationEvent(
            tool: event.tool,
            op: event.op,
            correlationID: event.correlationID,
            kind: event.kind,
            detail: String(event.detail.suffix(Self.terminalDetailTailLimit)),
            outcome: event.outcome,
            elicitation: event.elicitation
        )
    }
}
