import Foundation

/// One tool call's live lifecycle record: opened when a per-call binding
/// layer (``DetachingTool`` for `String`-output tools, ``ContextBindingTool``
/// for the rest) is about to run the wrapped call, and closed when that call
/// returns — including when it throws.
///
/// The binding layers post these through the same ``OperationEventSink`` route
/// operation events take (``OperationEventSink/post(invocation:)``), and the
/// session delivers each one live on the current turn's event stream as
/// ``SessionEvent/toolInvocation(_:)`` — the open record arrives while the
/// tool's own work is still running, which is what gives a UI a truthful
/// "running tool" signal mid-turn instead of only after the turn's diff.
///
/// **Delivery-only.** A record is never staged in the session's outbox and
/// never recorded to the transcript: the post-turn snapshot diff stays the one
/// authority for what is RECORDED, byte for byte. If the diff and the live
/// records disagree, the diff wins.
///
/// **The identity rule.** ``correlationID`` is the run's `completionToken` —
/// the same identity space as `OperationEvent.correlationID`
/// (``ToolContext/completionToken``). It is *never* an SDK
/// `Transcript.ToolCall.id`, and it never appears inside a
/// ``SessionEvent/toolCall(id:name:argumentsJSON:)`` /
/// ``SessionEvent/toolStatus(id:status:summary:)`` id: those stay Apple's
/// `Transcript.ToolCall.id` space alone. A consumer joins the two views
/// explicitly — the live record identifies the run (``correlationID``,
/// ``tool``, open order inside the turn frame) and the diff's `.toolCall`
/// identifies the SDK call — and neither id may be stamped into the other.
///
/// `Codable`/`Equatable`/`Sendable` so task ^1s8p8qt (`TurnOutcome`) can later
/// surface a turn's records directly, giving a caller per-call durations
/// without touching the event stream. That API is deliberately not built here.
public struct ToolInvocationRecord: Sendable, Equatable, Codable {
    /// The session-visible tool identity the run's ``ToolContext`` stamps on
    /// every event it posts — never empty.
    public let tool: String

    /// The op string the run's ``ToolContext`` stamps — phase 1 stamps the
    /// wrapped tool's `name` here too, never empty.
    public let op: String

    /// The run's `completionToken`, the same value that is the
    /// `correlationID` on every `OperationEvent` the run posts. See the
    /// identity rule in the type documentation: this is never an SDK
    /// `Transcript.ToolCall.id`.
    public let correlationID: String

    /// The owning session's identity — ``RoutedSession/id``.
    public let sessionID: ULID

    /// When the binding opened, immediately before the wrapped call started.
    public let openedAt: Date

    /// When the wrapped call returned (or threw), or `nil` while the call is
    /// still running — an open record.
    public let closedAt: Date?

    /// How long the call ran, derived as ``closedAt`` minus ``openedAt``, or
    /// `nil` while the record is still open.
    public var duration: TimeInterval? {
        closedAt.map { $0.timeIntervalSince(openedAt) }
    }

    /// Creates a record with every field explicit.
    ///
    /// - Parameters:
    ///   - tool: The session-visible tool identity.
    ///   - op: The op string the run's context stamps.
    ///   - correlationID: The run's `completionToken`.
    ///   - sessionID: The owning session's identity.
    ///   - openedAt: When the binding opened.
    ///   - closedAt: When the wrapped call returned, or `nil` (the default)
    ///     for an open record.
    public init(
        tool: String,
        op: String,
        correlationID: String,
        sessionID: ULID,
        openedAt: Date,
        closedAt: Date? = nil
    ) {
        self.tool = tool
        self.op = op
        self.correlationID = correlationID
        self.sessionID = sessionID
        self.openedAt = openedAt
        self.closedAt = closedAt
    }

    /// The closed form of this record: same identity, same ``openedAt``, with
    /// ``closedAt`` set to `instant` — from which ``duration`` derives.
    ///
    /// - Parameter instant: When the wrapped call returned.
    /// - Returns: The closed record.
    public func closed(at instant: Date) -> ToolInvocationRecord {
        ToolInvocationRecord(
            tool: tool,
            op: op,
            correlationID: correlationID,
            sessionID: sessionID,
            openedAt: openedAt,
            closedAt: instant
        )
    }
}
