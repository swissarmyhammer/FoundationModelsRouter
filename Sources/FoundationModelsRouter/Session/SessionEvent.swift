import Foundation

/// One element of the event stream ``RoutedSession/streamEvents(to:maxTokens:)`` produces.
///
/// ``turnStarted(_:)`` opens a turn, and every event up to the next one belongs to it.
/// ``RoutedSession/streamSessionEvents()`` carries every case except
/// ``textDelta(_:)`` and ``textReset``. This enum has no library evolution:
/// write a `default` arm to absorb new cases.
public enum SessionEvent: Sendable, Equatable {
    /// A turn began. Emitted once per logical turn, before any work of that turn.
    /// A turn that retries after a recovered overflow reports one of these and two ``turnEnded(_:)``.
    case turnStarted(TurnStart)

    /// A fragment of the model's response text, in production order.
    case textDelta(String)

    /// Every ``textDelta(_:)`` so far this turn is superseded. A consumer clears
    /// the accumulated text and then keeps appending. Superseded text is still
    /// recorded as its own `.response` entry.
    case textReset

    /// A fragment of the model's reasoning trace.
    case reasoningDelta(String)

    /// A tool invocation the model requested, from the SDK's `.toolCalls` entry.
    /// `id` is the call's `Transcript.ToolCall.id`; `argumentsJSON` is `GeneratedContent.jsonString`.
    case toolCall(id: String, name: String, argumentsJSON: String)

    /// A lifecycle update for a tool invocation announced by ``toolCall(id:name:argumentsJSON:)``.
    /// `summary` and `output` are non-nil only once ``ToolCallStatus/completed``;
    /// `output` carries every ``SegmentPayload`` of the answering `.toolOutput` entry.
    case toolStatus(id: String, status: ToolCallStatus, summary: String?, output: [SegmentPayload]?)

    /// A live ``ToolInvocationRecord``: an open record before a wrapped tool call
    /// starts, and a close record when it returns or throws. Delivery-only, never recorded.
    /// Its ``ToolInvocationRecord/correlationID`` is the run's `completionToken`, never a `Transcript.ToolCall.id`.
    case toolInvocation(ToolInvocationRecord)

    /// The records one tool call attached through ``ToolContext/attach(_:)``.
    /// Delivery-only, never recorded. Emitted one time per call, after the
    /// call's close ``toolInvocation(_:)`` record, and only when the call
    /// attached at least one record. Its ``ToolCallReport/correlationID`` is the
    /// run's `completionToken`, the same value as the call's
    /// ``ToolInvocationRecord/correlationID``, never a `Transcript.ToolCall.id`.
    /// Always on ``RoutedSession/streamSessionEvents()``; on the turn's stream
    /// when the call closes inside a turn.
    case toolCallReport(ToolCallReport)

    /// The turn's diff recorded one SDK transcript entry under its durable id.
    /// Emitted once per recorded `.response`, `.reasoning`, or `.toolCalls` entry.
    /// `id` is the `Transcript.Entry.id`, never a `Transcript.ToolCall.id`.
    case entryRecorded(id: String, kind: RecordedEntryKind)

    /// An auto-compaction fold completed against this session, mid-turn.
    case compaction(CompactionResult)

    /// This turn's ``DiscoveryPriming`` could not seed, so the turn generated unseeded.
    /// This is a report, not a failure.
    case discoveryPrimingFailed(DiscoveryPrimingFailure)

    /// The generation in flight has produced nothing observable for a whole reporting interval.
    /// This is a report, not a bound. It repeats once per further interval without progress.
    /// ``GenerationStall/visibility`` says what the report can claim.
    case generationStalled(GenerationStall)

    /// A background run of this session settled: its one terminal ``OperationEvent``.
    /// Always on ``RoutedSession/streamSessionEvents()``; on the turn's stream when it settles inside a turn.
    case runSettled(OperationEvent)

    /// A run of this session asked the user a question through
    /// ``ToolContext/elicit(_:)`` and is suspended until a host answers it.
    /// Carries the `.elicitation` ``OperationEvent`` the run posted, at the
    /// moment the session journals it. The mailbox registers the pending
    /// entry before the run posts, so a host can answer as soon as it sees
    /// this event.
    ///
    /// The event's `elicitation` is the typed ``ElicitationRequest``. Its
    /// `elicitationId` is the id ``RoutedSession/respond(elicitationId:response:)``
    /// and ``RoutedSession/complete(elicitationId:)`` take. The event's
    /// `correlationID` is the posting run's `completionToken`; for a run
    /// mounted through ``ToolContext/mount(_:op:as:)`` it is the mounting
    /// run's token.
    ///
    /// Always on ``RoutedSession/streamSessionEvents()``; on the turn's stream
    /// when the elicitation is raised inside a turn.
    ///
    /// Known limit: an elicitation posted through
    /// ``ToolContext/mount(_:op:as:postingTo:)`` with a sink that does not
    /// forward to the session's outbox never reaches the session's journal,
    /// so it never reaches this event.
    case elicitationRequested(OperationEvent)

    /// One generate attempt closed, with its measured token usage. Emitted once per inner generate call.
    case turnEnded(TokenUsage)
}

/// The records one tool call attached, carried by ``SessionEvent/toolCallReport(_:)``.
///
/// The Router does not read an attachment. A host decodes each one by its
/// ``ToolCallAttachment/schemaName``. The report identifies its call the way
/// the call's ``ToolInvocationRecord`` does, so a host can join the two.
public struct ToolCallReport: Sendable, Equatable {
    /// The session-visible tool name, the same stamp the call's record carries.
    public let tool: String

    /// The operation the call ran, the same `op` the call's record carries.
    public let op: String

    /// The run's `completionToken`: the same value as the call's
    /// ``ToolInvocationRecord/correlationID``, never a `Transcript.ToolCall.id`.
    public let correlationID: String

    /// The session the call ran in.
    public let sessionID: ULID

    /// The records the call attached, in call order. At least one.
    public let attachments: [ToolCallAttachment]

    /// Creates a report for one call.
    ///
    /// - Parameters:
    ///   - tool: The session-visible tool name.
    ///   - op: The operation the call ran.
    ///   - correlationID: The run's `completionToken`.
    ///   - sessionID: The session the call ran in.
    ///   - attachments: The records the call attached, in call order.
    public init(tool: String, op: String, correlationID: String, sessionID: ULID, attachments: [ToolCallAttachment]) {
        self.tool = tool
        self.op = op
        self.correlationID = correlationID
        self.sessionID = sessionID
        self.attachments = attachments
    }
}

/// The kind of SDK transcript entry a ``SessionEvent/entryRecorded(id:kind:)`` names.
public enum RecordedEntryKind: Sendable, Equatable {
    /// A `.response` entry, the model's answer text.
    case response

    /// A `.reasoning` entry, the model's reasoning trace.
    case reasoning

    /// A `.toolCalls` entry, one batch of tool invocations the model requested.
    case toolCalls
}

/// The lifecycle of one tool invocation a model requested, as observed through the SDK's transcript.
public enum ToolCallStatus: String, Sendable, Equatable, Codable {
    /// The SDK recorded a `.toolCalls` entry naming the call.
    case running

    /// The SDK recorded a matching `.toolOutput` entry, correlated by id.
    case completed

    /// The turn ended with no matching `.toolOutput` recorded for this call.
    case failed
}

/// One generate attempt's measured token usage, carried by ``SessionEvent/turnEnded(_:)``.
public struct TokenUsage: Sendable, Equatable {
    /// Input (prompt) tokens this attempt consumed.
    public let tokensIn: Int

    /// Output (completion) tokens this attempt produced.
    public let tokensOut: Int

    /// The session's measured ``RoutedSession/contextFill`` immediately after this attempt closed.
    public let contextFill: Double

    /// Creates a token usage value.
    public init(tokensIn: Int, tokensOut: Int, contextFill: Double) {
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.contextFill = contextFill
    }
}
