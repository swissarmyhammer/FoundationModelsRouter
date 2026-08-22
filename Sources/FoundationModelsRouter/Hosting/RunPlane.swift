/// What kind of work a parked run is — the discriminator that selects the
/// cancellation semantics its canceler closure carries.
///
/// Phase 1 shipped ``swiftTask`` and phase 2 adds ``process``; this enum stays
/// the seam where the `mcpRequest` (phase 4) kind lands.
///
/// Router owns the vocabulary and none of the machinery: each kind's canceler
/// comes from the capability that started the run, so the router never spawns
/// a process and never signals one.
public enum RunKind: String, Codable, Sendable, Equatable {
    /// An in-process Swift `Task`: cancellation is cooperative
    /// (`Task.cancel()`), so a canceler honestly reports
    /// ``OperationOutcome/cancelled`` — requested, the work may still be
    /// running — never ``OperationOutcome/stopped``.
    case swiftTask

    /// An OS process group, which a shell capability owns: `killpg(SIGKILL)`
    /// is authoritative, so a canceler for this kind reports
    /// ``OperationOutcome/stopped`` — the work is over, and that is certain —
    /// never ``OperationOutcome/cancelled``.
    ///
    /// The signal itself belongs to the capability that spawned the group. The
    /// run plane holds the canceler closure and reports the outcome it
    /// returns; it never calls `killpg` itself.
    case process
}

/// One row of the run plane's snapshot: a parked run's token, tool, op, kind,
/// and latest progress detail — envelopes only, never bulk output.
///
/// This is what ``ToolContext/parkedRuns()`` reports, and what a tool host
/// renders for a model that asked which of its runs are still going.
public struct ParkedRun: Sendable, Equatable {
    /// The run's completion token — the ULID string that is also the run's
    /// event `correlationID`.
    public let completionToken: String

    /// The fused tool's name that owns the run.
    public let tool: String

    /// The canonical `"verb noun"` op string of the parked operation.
    public let op: String

    /// What kind of work the run is.
    public let kind: RunKind

    /// The latest progress detail reported for the run, or `nil` when none
    /// has been reported yet.
    public let latestProgressDetail: String?
}

/// What ``ToolContext/wait(completionToken:seconds:)`` resolved to.
public enum WaitOutcome: Sendable, Equatable {
    /// The run settled; the terminal event carries the run's identifier
    /// (`correlationID`), its bounded output tail (`detail`, capped at
    /// ``ToolContext/terminalDetailTailLimit``), and its honest outcome.
    case settled(OperationEvent)

    /// The deadline elapsed before the run settled; the run stays parked.
    case deadlineElapsed

    /// No run — parked or settled — is known under this token. A safe,
    /// reportable no-op, never a throw or a crash.
    case unknownToken
}

/// What ``ToolContext/cancel(completionToken:)`` resolved to.
public enum CancelOutcome: Sendable, Equatable {
    /// The canceler ran; this is the outcome it reported — verbatim, never a
    /// guess (``OperationOutcome``'s authority distinction).
    case reported(OperationOutcome)

    /// The run already settled before the cancel arrived — nothing left to
    /// cancel; the retained terminal event says how it ended. Honest where
    /// ``unknownToken`` would be a lie: the token is known, its run just
    /// finished first.
    case alreadySettled(OperationEvent)

    /// No run — parked or settled — is known under this token. A safe,
    /// reportable no-op, never a throw or a crash.
    case unknownToken
}
