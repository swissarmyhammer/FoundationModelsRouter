import Foundation

/// One element of the richer event stream ``RoutedSession/streamEvents(to:maxTokens:)``
/// produces — the turn's opening correlation frame, text/reasoning increments,
/// tool-call lifecycle, and the turn's own closing usage.
///
/// Identity travels in the frame, not on each event: ``turnStarted(_:)`` opens a
/// turn and every event up to the next one belongs to it, since a session runs
/// one turn at a time. That is also how ``RoutedSession/streamSessionEvents()``
/// — the merged, session-wide feed of a session's turn-lifecycle events,
/// whichever entry point ran the turn — stays attributable. That feed carries
/// every case except ``textDelta(_:)`` and ``textReset``, which travel only on
/// the turn's own ``RoutedSession/streamEvents(to:maxTokens:)`` stream — see
/// ``RoutedSession/streamSessionEvents()`` for the exclusion and its reason.
///
/// **Source compatibility.** This is a public enum without library evolution,
/// so adding a case is a source-breaking change for any *exhaustive* `switch`
/// over it outside this package (the compiler neither requires nor accepts an
/// `@unknown default` there). ``turnStarted(_:)`` was added this way, and so
/// were ``toolInvocation(_:)`` and ``generationStalled(_:)``: a consumer
/// switching exhaustively adds the new case when updating. A consumer that
/// wants to absorb future cases without a source break writes a `default` arm
/// instead.
///
/// The session event stream: this is
/// the general session-event vocabulary a driver — or ``SessionProjection``,
/// the `@Observable` per-session projection (task ekd82f4) — consumes
/// instead of a per-consumer type of its own. ``RoutedSession/streamEvents(to:maxTokens:)``
/// emits every case, including ``compaction(_:)`` — the auto-compaction
/// opt-in threaded through the same chokepoint (task 8213x39,
/// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``'s
/// `budget:` parameter): a session with a budget set emits this whenever it
/// folds mid-turn on its own, proactively before a turn whose measured fill
/// has already reached the budget's trigger, or reactively after a turn
/// overflows and before the one retry. A session with no budget set never
/// emits it; ``RoutedSession/compact(prompt:budget:)`` — the explicit,
/// caller-driven fold — still returns its ``CompactionResult`` directly to
/// its own caller instead, exactly as before.
public enum SessionEvent: Sendable, Equatable {
    /// A turn began, naming itself and — when the turn came off the prompt
    /// queue — the prompt that caused it.
    ///
    /// **This is the correlation frame.** A session runs one turn at a time
    /// (``RoutedSessionActor/turnLock`` is held for the whole of every turn), so
    /// every event that follows this one, up to the next ``turnStarted(_:)``,
    /// belongs to the turn this names. That is what lets a client map prompt to
    /// turn to events without an id repeated on each event — and it is why no
    /// turn identity is stamped into
    /// ``toolCall(id:name:argumentsJSON:)``/``toolStatus(id:status:summary:output:)``,
    /// whose `id` is documented as Apple's `Transcript.ToolCall.id` and belongs
    /// to that identity space alone.
    ///
    /// Emitted once per *logical* turn, before any work that turn does —
    /// including a proactive auto-compaction fold and this turn's discovery
    /// priming — and on both routes: a turn started by
    /// ``RoutedSession/streamEvents(to:maxTokens:)`` yields it on that turn's own
    /// stream, and *every* turn yields it on
    /// ``RoutedSession/streamSessionEvents()``. A turn that retries after a
    /// recovered context overflow is still one logical turn and still reports
    /// one of these, though it closes two ``turnEnded(_:)``.
    ///
    /// ``RoutedSession/compact(prompt:budget:)`` holds the same turn lock but
    /// runs no generation and derives no events, so it opens no frame; its turn
    /// id is simply never reported.
    case turnStarted(TurnStart)

    /// A fragment of the model's response text, in production order — the
    /// same fragments ``RoutedSession/streamResponse(to:maxTokens:)`` yields.
    case textDelta(String)

    /// Every ``textDelta(_:)`` so far this turn is superseded: the model
    /// abandoned the response it was writing and began another.
    ///
    /// Emitted immediately before the first ``textDelta(_:)`` of the new
    /// response, and only when a restart really happened. A tool-using turn is
    /// where it happens: the SDK closes the pre-tool `Transcript.Response`
    /// entry, runs the tool, and resumes generation into a new one, so the text
    /// before the boundary is not part of the answer
    /// ``RoutedSession/respond(to:maxTokens:)`` returns for the same turn.
    ///
    /// **The rule a consumer applies.** Clear the text accumulated so far, then
    /// keep appending. A consumer that does gets, character for character, the
    /// string `respond(to:maxTokens:)` returns — that is the invariant this
    /// case exists to make reachable (task ^w8dzvee, defect D2).
    ///
    /// A consumer that ignores it keeps every fragment the model produced,
    /// which is the prior behavior and a deliberate guarantee: a delivered
    /// chunk cannot be retracted, and a live consumer is entitled to everything
    /// the model said. Superseded text is real output, and it is recorded as
    /// its own `.response` transcript entry either way — this case reports that
    /// it is no longer part of the answer, and never withholds it.
    case textReset

    /// A fragment of the model's reasoning trace, present only when the
    /// backend recorded a `.reasoning` transcript entry for this turn.
    case reasoningDelta(String)

    /// A tool invocation the model requested, mirroring one
    /// ``ToolCallPayload`` off the SDK's own `.toolCalls` transcript entry.
    ///
    /// - Parameters:
    ///   - id: The invocation's own id — Apple's `Transcript.ToolCall.id`,
    ///     stable across this call's ``toolStatus(id:status:summary:output:)``
    ///     updates and load-bearing for distinguishing two concurrent
    ///     same-name tool calls.
    ///   - name: The tool's name.
    ///   - argumentsJSON: The call's arguments, as `GeneratedContent.jsonString`.
    case toolCall(id: String, name: String, argumentsJSON: String)

    /// A lifecycle update for a tool invocation previously announced by
    /// ``toolCall(id:name:argumentsJSON:)``, correlated by `id`.
    ///
    /// - Parameters:
    ///   - id: The originating call's id.
    ///   - status: The invocation's current status.
    ///   - summary: The tool's flattened output text once
    ///     ``ToolCallStatus/completed``, or `nil` for
    ///     ``ToolCallStatus/running``/``ToolCallStatus/failed``.
    ///   - output: The tool's full output segments once
    ///     ``ToolCallStatus/completed`` — every ``SegmentPayload`` the
    ///     answering `.toolOutput` entry carries, in entry order, so a
    ///     `.structure`, `.attachment`, or `.custom` result travels intact
    ///     where `summary` flattens it to text — or `nil` for
    ///     ``ToolCallStatus/running``/``ToolCallStatus/failed`` and for an
    ///     entry that carries no segments.
    case toolStatus(id: String, status: ToolCallStatus, summary: String?, output: [SegmentPayload]?)

    /// A live ``ToolInvocationRecord`` from this session's own per-call
    /// binding layers: an open record (``ToolInvocationRecord/closedAt``
    /// `nil`) immediately before a wrapped tool call starts, and a close
    /// record when that call returns — including when it throws.
    ///
    /// **This is the mid-turn tool liveness signal** (task ^zfd8e69). The
    /// open record arrives while the tool's own work is still running —
    /// unlike ``toolCall(id:name:argumentsJSON:)`` and
    /// ``toolStatus(id:status:summary:output:)``, which the post-turn diff
    /// synthesizes once generation finishes. It travels on both routes: the
    /// turn's own ``RoutedSession/streamEvents(to:maxTokens:)`` stream and
    /// ``RoutedSession/streamSessionEvents()``. A detached run's close
    /// arrives late, when the work really ends — possibly after this turn's
    /// ``turnEnded(_:)``, on the session-scoped feed — self-attributed by
    /// the record's ``ToolInvocationRecord/correlationID``.
    ///
    /// **Delivery-only.** The record is never staged in the session's outbox
    /// and never recorded to the transcript; the post-turn diff stays the
    /// recording authority, and its ``toolCall(id:name:argumentsJSON:)``/
    /// ``toolStatus(id:status:summary:output:)`` events keep arriving unchanged.
    ///
    /// **The identity rule.** The record's
    /// ``ToolInvocationRecord/correlationID`` is the run's `completionToken`
    /// — `OperationEvent.correlationID`'s space — and never an SDK
    /// `Transcript.ToolCall.id`; neither id is ever stamped into the other.
    /// A consumer joins the two views explicitly: the live record identifies
    /// the run (its `correlationID`, tool name, and open order inside the
    /// turn frame), the diff's ``toolCall(id:name:argumentsJSON:)``
    /// identifies the SDK call.
    ///
    /// Ordering, within one turn's in-band calls: the open record precedes
    /// its close record, and both precede the diff's
    /// ``toolCall(id:name:argumentsJSON:)``/``toolStatus(id:status:summary:output:)``
    /// for the same turn and that turn's ``turnEnded(_:)``.
    case toolInvocation(ToolInvocationRecord)

    /// The turn's snapshot diff recorded one SDK transcript entry, closing it
    /// under its durable id.
    ///
    /// This is what gives a live consumer a stable, source-derived identity
    /// for the state it accumulated from deltas: the ``textDelta(_:)`` and
    /// ``reasoningDelta(_:)`` fragments stream without an entry id, because
    /// the SDK entry does not exist until generation finishes and the turn's
    /// diff runs. This event delivers that id the moment the entry is known.
    /// ``SessionProjection`` uses it to adopt the SDK id onto the oldest
    /// still-open row of the matching kind, and to stamp
    /// ``SessionProjection/TranscriptEntry/sourceEntryId`` onto a `.toolCalls`
    /// entry's call rows.
    ///
    /// Emitted once per recorded `.response`/`.reasoning`/`.toolCalls` entry,
    /// in diff order, after that entry's own derived events (the
    /// ``toolCall(id:name:argumentsJSON:)``/``toolStatus(id:status:summary:output:)``
    /// pairs of a `.toolCalls` entry, the ``reasoningDelta(_:)`` of a
    /// `.reasoning` entry). A `.response` entry emits exactly this one event —
    /// its text already streamed live as ``textDelta(_:)`` fragments. It
    /// travels on both routes: the turn's own
    /// ``RoutedSession/streamEvents(to:maxTokens:)`` stream and
    /// ``RoutedSession/streamSessionEvents()``.
    ///
    /// - Parameters:
    ///   - id: Apple's own `Transcript.Entry.id` for the recorded entry — the
    ///     same id ``TranscriptEntryPayload/entryId`` persists, so a consumer
    ///     can join live state back to the raw transcript and the recording.
    ///     This is *never* a `Transcript.ToolCall.id`: a `.toolCalls` entry's
    ///     close carries the entry's id, while its individual calls' ids
    ///     travel on their own ``toolCall(id:name:argumentsJSON:)`` events.
    ///   - kind: Which entry kind was recorded.
    case entryRecorded(id: String, kind: RecordedEntryKind)

    /// An auto-compaction fold completed against this session, mid-turn. See
    /// this type's own documentation for when this is emitted.
    case compaction(CompactionResult)

    /// This turn's ``DiscoveryPriming`` could not seed, so the turn generated
    /// unseeded.
    ///
    /// Emitted only by a session that opted into priming
    /// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``'s
    /// `discoveryPriming:` parameter), and only when its host-side discovery
    /// call did not produce a seed. It is a report, not a failure: the turn
    /// proceeds exactly as an unprimed one would, because priming improves a
    /// turn's opening move rather than being a precondition for having one. A
    /// session with priming off never emits it.
    ///
    /// Its payload is the ``DiscoveryPrimingFailure`` saying why the seed could
    /// not be built. Because priming runs on every turn, whichever entry point
    /// started it, this is emitted on two routes: a turn started by
    /// ``RoutedSession/streamEvents(to:maxTokens:)`` yields it on that turn's own
    /// stream, and *every* turn — including the ones
    /// ``RoutedSession/respond(to:maxTokens:)`` and
    /// ``RoutedSession/dispatchNextPrompt()`` run, which hand their caller a
    /// response rather than a stream — yields it on
    /// ``RoutedSession/streamSessionEvents()``.
    case discoveryPrimingFailed(DiscoveryPrimingFailure)

    /// The generation in flight has produced nothing this session can observe
    /// for a whole reporting interval (task ^z6xcmnh).
    ///
    /// **A report, never a bound.** Nothing is cancelled, nothing fails, and
    /// the answer the turn eventually returns is exactly the answer it would
    /// have returned without this event — see
    /// ``RoutedSession/respond(to:maxTokens:)`` for the whole recorded
    /// decision, and ``GenerationStall`` for what a report carries.
    ///
    /// Emitted repeatedly while the generation stays stuck, once per further
    /// interval without progress, so a consumer sees
    /// ``GenerationStall/timeWithoutProgress`` grow. That growth is the fact
    /// that separates a stuck decode from a slow one, which from outside look
    /// identical.
    ///
    /// It travels on both routes, because a stall matters most on the surface
    /// that hands its caller no stream: the turn's own
    /// ``RoutedSession/streamEvents(to:maxTokens:)`` stream, and *every* turn's
    /// ``RoutedSession/streamSessionEvents()`` — including the ones
    /// ``RoutedSession/respond(to:maxTokens:)`` and
    /// ``RoutedSession/dispatchNextPrompt()`` run. What a report is entitled to
    /// claim differs between the two, and ``GenerationStall/visibility`` says
    /// which claim this one makes.
    case generationStalled(GenerationStall)

    /// A background run of this session settled: its one terminal
    /// ``OperationEvent``, with the run's honest ``OperationOutcome`` and
    /// bounded output tail. Yielded on the turn's own stream when the run
    /// settles inside a turn, and on ``RoutedSession/streamSessionEvents()``
    /// always; the same terminal rides the next dispatched turn to the model.
    case runSettled(OperationEvent)

    /// One physical generate attempt closed, carrying its own measured token
    /// usage and the session's resulting ``RoutedSession/contextFill``.
    ///
    /// Emitted once per *inner* generate call, not once per logical turn
    /// (compaction_plan.md §1.7, task g2hcm36): a turn auto-compaction retries
    /// after a recovered overflow (``RoutedSession/compact(prompt:budget:)``'s
    /// documented reactive pattern, driven automatically when a budget is
    /// set) is two inner calls — the failed attempt and the retry — and each
    /// closes with its own ``turnEnded(_:)``, carrying the fill measured at
    /// that moment. This is what feeds a live context meter *during* a turn
    /// rather than only once the whole (possibly retried) turn finishes.
    case turnEnded(TokenUsage)
}

/// The kind of SDK transcript entry a ``SessionEvent/entryRecorded(id:kind:)``
/// names.
///
/// Only the three kinds a live consumer mirrors as its own rows are named
/// here. A `.prompt`, `.instructions`, or `.toolOutput` entry gets no
/// ``SessionEvent/entryRecorded(id:kind:)``: a prompt and instructions are
/// inputs a consumer already holds, and a tool output's content reaches a
/// consumer as the ``ToolCallStatus/completed`` status of the call it answers.
public enum RecordedEntryKind: Sendable, Equatable {
    /// A `.response` entry — the model's answer text.
    case response

    /// A `.reasoning` entry — the model's reasoning trace.
    case reasoning

    /// A `.toolCalls` entry — one batch of tool invocations the model
    /// requested.
    case toolCalls
}

/// The lifecycle of one tool invocation a model requested, as observed
/// through the SDK's own transcript.
public enum ToolCallStatus: String, Sendable, Equatable, Codable {
    /// The model requested the call and it was dispatched to the tool — the
    /// SDK recorded a `.toolCalls` entry naming it.
    case running

    /// The tool returned output — the SDK recorded a matching `.toolOutput`
    /// entry, correlated by id.
    case completed

    /// The turn ended with no matching `.toolOutput` ever recorded for this
    /// call — the tool errored, or the turn was aborted before the SDK
    /// recorded its result.
    case failed
}

/// One generate attempt's own measured token usage — the `(input, output)`
/// delta ``RoutedSessionActor``'s chokepoint computes around it — plus the
/// session's resulting ``RoutedSession/contextFill``, wrapped for
/// ``SessionEvent/turnEnded(_:)``.
public struct TokenUsage: Sendable, Equatable {
    /// Input (prompt) tokens this attempt consumed.
    public let tokensIn: Int

    /// Output (completion) tokens this attempt produced.
    public let tokensOut: Int

    /// The session's measured ``RoutedSession/contextFill`` immediately after
    /// this attempt closed (compaction_plan.md §1.7, task g2hcm36) — the live
    /// context-meter value a driver reports mid-turn, not only once a whole
    /// (possibly retried) turn finishes. Unchanged from the prior attempt's
    /// value when this one never reached the backend (mirrors
    /// ``RoutedSession/contextFill``'s own "left untouched, not reset to a
    /// meaningless zero delta" rule).
    public let contextFill: Double

    /// Creates a token usage value.
    ///
    /// - Parameters:
    ///   - tokensIn: Input tokens this attempt consumed.
    ///   - tokensOut: Output tokens this attempt produced.
    ///   - contextFill: The session's measured ``RoutedSession/contextFill``
    ///     immediately after this attempt closed.
    public init(tokensIn: Int, tokensOut: Int, contextFill: Double) {
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.contextFill = contextFill
    }
}
