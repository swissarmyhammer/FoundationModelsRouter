/// What kind of work a background run is. The kind selects the cancellation semantics its canceler closure carries.
/// Each kind's canceler comes from the capability that started the run; the router never spawns or signals a process.
public enum RunKind: String, Codable, Sendable, Equatable {
    /// An in-process Swift `Task`. Cancellation is cooperative, so a canceler reports
    /// ``OperationOutcome/cancelled``, never ``OperationOutcome/stopped``.
    case swiftTask

    /// An OS process group owned by a shell capability. `killpg(SIGKILL)` is authoritative, so a canceler
    /// reports ``OperationOutcome/stopped``. The run plane never calls `killpg` itself.
    case process
}

/// One row of the run plane's snapshot, as ``ToolContext/backgroundRuns()`` reports it: envelopes only, never bulk output.
public struct BackgroundRun: Sendable, Equatable {
    /// The run's completion token, also the run's event `correlationID`.
    public let completionToken: String

    /// The fused tool's name that owns the run.
    public let tool: String

    /// The canonical `"verb noun"` op string of the background operation.
    public let op: String

    /// What kind of work the run is.
    public let kind: RunKind

    /// The latest progress detail reported for the run, or `nil` when none has been reported yet.
    public let latestProgressDetail: String?
}

/// What ``ToolContext/wait(completionToken:seconds:)`` resolved to.
public enum WaitOutcome: Sendable, Equatable {
    /// The run settled; the terminal event carries the run's `correlationID`, its output tail capped at ``ToolContext/terminalDetailTailLimit``, and its outcome.
    case settled(OperationEvent)

    /// The deadline elapsed before the run settled; the run stays running.
    case deadlineElapsed

    /// No run, running or settled, is known under this token. A safe no-op.
    case unknownToken
}

/// What ``ToolContext/cancel(completionToken:)`` resolved to.
public enum CancelOutcome: Sendable, Equatable {
    /// The canceler ran; this is the outcome it reported, verbatim.
    case reported(OperationOutcome)

    /// The run settled before the cancel arrived; the retained terminal event says how it ended.
    case alreadySettled(OperationEvent)

    /// No run — running or settled — is known under this token. A safe,
    /// reportable no-op, never a throw or a crash.
    case unknownToken
}
