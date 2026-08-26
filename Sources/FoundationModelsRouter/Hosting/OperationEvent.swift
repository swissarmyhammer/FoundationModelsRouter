/// The category of a posted `OperationEvent`.
///
/// Only `.completed` is terminal. A run that posts any event must post
/// exactly one `.completed` event before it ends. A run that settles
/// in-band with no events may post nothing.
public enum OperationEventKind: String, Codable, Sendable, Equatable {
    /// The operation is still running; `OperationEvent.detail` describes its progress.
    case progress

    /// The operation has finished; `OperationEvent.outcome` states how it ended.
    case completed

    /// The operation asks the user for input; `OperationEvent.elicitation` carries the request.
    /// Never terminal.
    case elicitation
}

/// A progress, completion, or elicitation event a long-running operation
/// posts through a connected `OperationEventSink`.
/// See `OperationEventKind` for the terminal-event contract.
public struct OperationEvent: Codable, Sendable, Equatable {
    /// The name of the fused tool (`OperationTool.name`) that posted this event.
    public let tool: String

    /// The canonical `"verb noun"` op string of the operation that posted this event.
    public let op: String

    /// A tool-assigned identifier that correlates every event from the same run.
    /// Opaque to this package.
    public let correlationID: String

    /// Whether this event reports progress, completion, or a request for user input.
    public let kind: OperationEventKind

    /// A JSON-string payload in a shape the emitting tool owns. Opaque to this package.
    public let detail: String

    /// How the operation run ended. Non-nil if and only if `kind == .completed`.
    /// Decoded with `decodeIfPresent`, so older recorded events decode unchanged.
    public let outcome: OperationOutcome?

    /// The typed request for user input. Non-nil if and only if `kind == .elicitation`.
    /// Decoded with `decodeIfPresent`, so older recorded events decode unchanged.
    public let elicitation: ElicitationRequest?

    /// Creates an event with the given fields.
    /// - Parameters:
    ///   - tool: The name of the posting tool.
    ///   - op: The `"verb noun"` op string of the posting operation.
    ///   - correlationID: The identifier of the operation run.
    ///   - kind: The event category.
    ///   - detail: The tool-owned JSON-string payload.
    ///   - outcome: How the run ended; non-nil only when `kind == .completed`.
    ///   - elicitation: The request for user input; non-nil only when `kind == .elicitation`.
    public init(
        tool: String,
        op: String,
        correlationID: String,
        kind: OperationEventKind,
        detail: String,
        outcome: OperationOutcome? = nil,
        elicitation: ElicitationRequest? = nil
    ) {
        self.tool = tool
        self.op = op
        self.correlationID = correlationID
        self.kind = kind
        self.detail = detail
        self.outcome = outcome
        self.elicitation = elicitation
    }
}
