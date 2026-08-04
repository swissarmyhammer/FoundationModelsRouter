/// The category of a posted `OperationEvent`: whether a long-running
/// operation is still running, or has finished.
///
/// Terminal-event scope contract (a minimum guarantee, not a ceiling): a
/// run that posts any event at all must post exactly one terminal
/// (`.completed`) event before it ends; a run that settles entirely
/// in-band — its result returned directly, with no events posted — may
/// post nothing. Both current emitters comply: Shelltool posts events only
/// for commands that actually detached, and posts `.completed` exactly once
/// for each; MCP posts one `.completed` event per call, for every call,
/// which satisfies the minimum by always posting rather than relying on
/// "may post nothing".
public enum OperationEventKind: String, Codable, Sendable, Equatable {
    /// The operation is still running; `OperationEvent.detail` describes its
    /// current progress.
    case progress

    /// The operation has finished; `OperationEvent.detail` describes its
    /// final result, and `OperationEvent.outcome` states how it ended.
    case completed
}

/// A standard progress/completion event a long-running operation posts
/// through a connected `OperationEventSink`.
///
/// This is the vocabulary every fused tool and every session host shares:
/// a tool posts these from inside `OperationDefinition.execute(in:)` (via an
/// `EventEmittingContext`'s sink holder) without knowing anything about the
/// host that will observe them, and a host consumes them through
/// `OperationEventSink` without knowing anything about the tool that posted
/// them. Neither side depends on the other — only on this shared type.
///
/// See `OperationEventKind` for the terminal-event scope contract every
/// emitter must follow.
public struct OperationEvent: Codable, Sendable, Equatable {
    /// The fused tool's name (`OperationTool.name`) that posted this event.
    public let tool: String

    /// The canonical `"verb noun"` op string of the operation that posted
    /// this event (see `OperationDefinition.opString`).
    public let op: String

    /// A tool-assigned identifier correlating every event from the same
    /// logical operation run (e.g. a shell tool's commandID). Opaque to this
    /// package — it never interprets or generates one itself.
    public let correlationID: String

    /// Whether this event reports in-progress state or completion.
    public let kind: OperationEventKind

    /// A JSON-string payload describing this event, in whatever shape the
    /// emitting tool defines and owns. Opaque to this package: neither
    /// `OperationEvent` nor `OperationEventSink` interpret it — the emitting
    /// tool and the connected host agree on its shape out of band.
    public let detail: String

    /// How the operation run ended.
    ///
    /// Invariant: non-nil if and only if `kind == .completed`. Decoded with
    /// `decodeIfPresent`, defaulting to `nil`, so `OperationEvent`s recorded
    /// before this field existed — e.g. Router-journaled
    /// `OperationEventSegment`s already committed to a transcript — continue
    /// to decode unchanged. `detail` remains the place for everything
    /// genuinely tool-specific (exit codes, `isError` provenance, progress
    /// counts); `outcome` carries only the one fact every host branches on.
    public let outcome: OperationOutcome?

    /// Creates an event with the given fields.
    ///
    /// - Parameters:
    ///   - tool: The fused tool's name that posted this event.
    ///   - op: The canonical `"verb noun"` op string of the posting
    ///     operation.
    ///   - correlationID: A tool-assigned identifier correlating every event
    ///     from the same logical operation run.
    ///   - kind: Whether this event reports in-progress state or completion.
    ///   - detail: A JSON-string payload describing this event, in whatever
    ///     shape the emitting tool defines and owns.
    ///   - outcome: How the operation run ended. Non-nil if and only if
    ///     `kind == .completed`. Defaults to `nil` so existing call sites
    ///     compile unchanged.
    public init(
        tool: String,
        op: String,
        correlationID: String,
        kind: OperationEventKind,
        detail: String,
        outcome: OperationOutcome? = nil
    ) {
        self.tool = tool
        self.op = op
        self.correlationID = correlationID
        self.kind = kind
        self.detail = detail
        self.outcome = outcome
    }
}
