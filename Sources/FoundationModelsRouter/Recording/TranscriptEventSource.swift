import Foundation

/// The source of the events of one session: the identity that each event of
/// its `transcript.jsonl` carries.
///
/// Each event that a live session records, and each event that
/// ``RoutedModel/recordSession(from:configuration:)`` writes, goes through
/// ``partialEvent(kind:grammar:text:since:entry:tokensIn:tokensCached:tokensOut:callTiming:callDuration:agentSpawn:)``.
/// Thus a written recording has the same form as the recording of a live
/// session, for example the same `grammar` on each event.
struct TranscriptEventSource: Sendable, Equatable {
    /// The id of the router that records the session.
    let routerId: ULID

    /// The id of the session.
    let sessionId: ULID

    /// The id of the parent session, or `nil` for a root session.
    let parentId: ULID?

    /// The slot of the model of the session.
    let slot: ModelSlot

    /// The model of the session.
    let model: ModelRef

    /// The number of milliseconds in one second, the scale of ``TranscriptEvent/ms``.
    private static let millisecondsPerSecond: Double = 1_000

    /// Builds an event of the given kind stamped with the identity of this
    /// source.
    ///
    /// - Parameters:
    ///   - kind: The event kind.
    ///   - grammar: The guided-generation grammar in force, or `nil`.
    ///   - text: The event's flattened body text, or `nil`.
    ///   - since: The start instant of the submission used to stamp `ms`, or `nil`.
    ///   - entry: The structural payload that mirrors `Transcript.Entry`, or `nil`.
    ///   - tokensIn: The input token delta of the submission, or `nil`.
    ///   - tokensCached: The part of `tokensIn` the prompt cache reused, or
    ///     `nil`. Only the `.generationCall` kind carries one.
    ///   - tokensOut: The output token delta of the submission, or `nil`.
    ///   - callTiming: The prefill and the decode time of one generation
    ///     call, or `nil`. Only the `.generationCall` kind carries one. Its
    ///     presence also stamps whether the session saw the first token of
    ///     the call (``TranscriptEvent/firstTokenSeen``) and whether its
    ///     output was buffered (``TranscriptEvent/outputBuffered``).
    ///   - callDuration: The whole time of one generation call, or `nil`.
    ///     Only the `.generationCall` kind carries one.
    ///   - agentSpawn: The spawn context to stamp, or `nil`. Only the
    ///     `.session` kind carries one.
    /// - Returns: The partial event for the recorder to stamp and append.
    func partialEvent(
        kind: TranscriptEvent.Kind,
        grammar: Grammar? = nil,
        text: String? = nil,
        since: Date? = nil,
        entry: TranscriptEntryPayload? = nil,
        tokensIn: Int? = nil,
        tokensCached: Int? = nil,
        tokensOut: Int? = nil,
        callTiming: GenerationCallTiming? = nil,
        callDuration: Duration? = nil,
        agentSpawn: SessionRecord.AgentSpawn? = nil
    ) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: routerId,
            sessionId: sessionId,
            parentId: parentId,
            slot: slot,
            model: model,
            kind: kind,
            grammar: grammar?.source,
            text: text,
            tokensIn: tokensIn,
            tokensCached: tokensCached,
            tokensOut: tokensOut,
            ms: since.map { Int(Date().timeIntervalSince($0) * Self.millisecondsPerSecond) },
            timeToFirstTokenMs: callTiming?.timeToFirstToken?.wholeMilliseconds,
            decodeMs: callTiming?.decodeTime?.wholeMilliseconds,
            callMs: callDuration?.wholeMilliseconds,
            firstTokenSeen: callTiming.map { $0.timeToFirstToken != nil },
            outputBuffered: callTiming?.outputBuffered,
            entry: entry,
            agentSpawn: agentSpawn
        )
    }
}
