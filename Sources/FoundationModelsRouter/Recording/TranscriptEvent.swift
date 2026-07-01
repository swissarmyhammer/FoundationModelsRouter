import Foundation

/// A single recorded moment in a session's life — a prompt, a response, a tool
/// call, an embedding, or the session's own birth — together with the
/// provenance needed to place it in the router's transcript tree.
///
/// Events are the unit a ``TranscriptRecorder`` appends. The recorder, not the
/// caller, stamps `seq` and `ts` at append (see ``TranscriptEvent/Partial``),
/// so concurrent appends across forks collapse into one totally-ordered log:
/// `seq` is the monotonic total order and `ts` is the wall-clock instant the
/// recorder observed.
///
/// Provenance ids (`routerId`, `sessionId`, `parentId`) are `ULID`s: the
/// `routerId` is the recording root, `sessionId` is this session's span, and
/// `parentId` is the span that forked it (`nil` for a root session). The
/// metering fields (`tokensIn`, `tokensOut`, `ms`) and `grammar` are optional
/// because not every kind of event carries them.
///
/// The type is `Codable` in both directions and encodes one self-contained JSON
/// object — the on-disk form a ``JSONLRecorder`` writes one-per-line.
public struct TranscriptEvent: Sendable, Codable, Equatable {
    /// What kind of moment an event records.
    public enum Kind: String, Sendable, Codable, Equatable {
        /// The session was created (its first event).
        case session
        /// A prompt was submitted to a model.
        case prompt
        /// A model produced a response.
        case response
        /// A tool invocation was requested.
        case toolCall
        /// A tool returned output.
        case toolOutput
        /// An embedding was produced.
        case embedding
    }

    /// The recording root id — the router instance that owns this transcript.
    public let routerId: ULID
    /// The span id of the session this event belongs to.
    public let sessionId: ULID
    /// The span id of the session that forked this one, or `nil` for a root.
    public let parentId: ULID?
    /// The model slot this event was routed through, when applicable.
    public let slot: ModelSlot?
    /// The concrete model reference involved, when applicable.
    public let model: ModelRef?
    /// The recorder-assigned monotonic sequence number — the log's total order.
    public let seq: Int
    /// The wall-clock instant the recorder stamped at append.
    public let ts: Date
    /// What kind of moment this event records.
    public let kind: Kind
    /// The guided-generation grammar in force, when applicable.
    public let grammar: String?
    /// The event's body text — the prompt, response, or embedded input — when
    /// the recording level keeps it.
    ///
    /// Present on a ``TranscriptEvent/Kind/full`` recording and `nil` once a
    /// ``GatingRecorder`` at ``RecordingLevel/metadataOnly`` has trimmed it or a
    /// ``RecordingLevel/off`` recorder dropped the event entirely; the ``Router``'s
    /// `redact` hook, when set, transforms it before it is written.
    public let text: String?
    /// Prompt/input tokens metered for this event, when applicable.
    public let tokensIn: Int?
    /// Completion/output tokens metered for this event, when applicable.
    public let tokensOut: Int?
    /// Wall-clock duration of the event in milliseconds, when applicable.
    public let ms: Int?

    /// Creates a fully-stamped event.
    ///
    /// Callers normally do not build events directly — they hand a
    /// ``TranscriptEvent/Partial`` to a recorder, which assigns `seq` and `ts`.
    /// This initializer is the stamping point and is also used by tests.
    ///
    /// - Parameters:
    ///   - routerId: The recording root id.
    ///   - sessionId: The session span id.
    ///   - parentId: The forking session's span id, or `nil` for a root.
    ///   - slot: The routed model slot, or `nil`.
    ///   - model: The concrete model reference, or `nil`.
    ///   - seq: The monotonic sequence number assigned by the recorder.
    ///   - ts: The instant the recorder stamped.
    ///   - kind: What kind of moment this records.
    ///   - grammar: The guided-generation grammar, or `nil`.
    ///   - text: The event's body text, or `nil` when trimmed by the recording level.
    ///   - tokensIn: Input tokens metered, or `nil`.
    ///   - tokensOut: Output tokens metered, or `nil`.
    ///   - ms: Duration in milliseconds, or `nil`.
    public init(
        routerId: ULID,
        sessionId: ULID,
        parentId: ULID? = nil,
        slot: ModelSlot? = nil,
        model: ModelRef? = nil,
        seq: Int,
        ts: Date,
        kind: Kind,
        grammar: String? = nil,
        text: String? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        ms: Int? = nil
    ) {
        self.routerId = routerId
        self.sessionId = sessionId
        self.parentId = parentId
        self.slot = slot
        self.model = model
        self.seq = seq
        self.ts = ts
        self.kind = kind
        self.grammar = grammar
        self.text = text
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.ms = ms
    }

    /// An event minus the fields a recorder owns (`seq` and `ts`).
    ///
    /// A caller describes *what* happened; the recorder decides *when* in the
    /// total order it lands. Handing the recorder a `Partial` — rather than a
    /// finished event — is what lets it assign a monotonic `seq` and a stamped
    /// `ts` atomically at append, so concurrent appends cannot collide on order.
    public struct Partial: Sendable, Equatable {
        /// The recording root id.
        public let routerId: ULID
        /// The session span id.
        public let sessionId: ULID
        /// The forking session's span id, or `nil` for a root.
        public let parentId: ULID?
        /// The routed model slot, or `nil`.
        public let slot: ModelSlot?
        /// The concrete model reference, or `nil`.
        public let model: ModelRef?
        /// What kind of moment this records.
        public let kind: Kind
        /// The guided-generation grammar, or `nil`.
        public let grammar: String?
        /// The event's body text — the prompt, response, or embedded input — or
        /// `nil` when the event carries no body.
        public let text: String?
        /// Input tokens metered, or `nil`.
        public let tokensIn: Int?
        /// Output tokens metered, or `nil`.
        public let tokensOut: Int?
        /// Duration in milliseconds, or `nil`.
        public let ms: Int?

        /// Describes an event without its recorder-owned ordering fields.
        ///
        /// - Parameters:
        ///   - routerId: The recording root id.
        ///   - sessionId: The session span id.
        ///   - parentId: The forking session's span id, or `nil` for a root.
        ///   - slot: The routed model slot, or `nil`.
        ///   - model: The concrete model reference, or `nil`.
        ///   - kind: What kind of moment this records.
        ///   - grammar: The guided-generation grammar, or `nil`.
        ///   - text: The event's body text, or `nil` when the event carries no body.
        ///   - tokensIn: Input tokens metered, or `nil`.
        ///   - tokensOut: Output tokens metered, or `nil`.
        ///   - ms: Duration in milliseconds, or `nil`.
        public init(
            routerId: ULID,
            sessionId: ULID,
            parentId: ULID? = nil,
            slot: ModelSlot? = nil,
            model: ModelRef? = nil,
            kind: Kind,
            grammar: String? = nil,
            text: String? = nil,
            tokensIn: Int? = nil,
            tokensOut: Int? = nil,
            ms: Int? = nil
        ) {
            self.routerId = routerId
            self.sessionId = sessionId
            self.parentId = parentId
            self.slot = slot
            self.model = model
            self.kind = kind
            self.grammar = grammar
            self.text = text
            self.tokensIn = tokensIn
            self.tokensOut = tokensOut
            self.ms = ms
        }

        /// Returns a copy of this partial with its ``text`` replaced by
        /// `transform(text)`, leaving every other field untouched.
        ///
        /// The transform seam a ``GatingRecorder`` uses to enforce the recording
        /// level and redaction before the event is stamped and written: mapping
        /// the body to `nil` trims it (``RecordingLevel/metadataOnly``) and
        /// mapping it through the ``Router``'s `redact` hook redacts it.
        ///
        /// - Parameter transform: The body-text transform to apply.
        /// - Returns: A copy carrying the transformed body text.
        func mapText(_ transform: (String?) -> String?) -> Partial {
            Partial(
                routerId: routerId,
                sessionId: sessionId,
                parentId: parentId,
                slot: slot,
                model: model,
                kind: kind,
                grammar: grammar,
                text: transform(text),
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                ms: ms
            )
        }

        /// Stamps this partial with a recorder-assigned `seq` and `ts`, yielding
        /// a finished ``TranscriptEvent``.
        ///
        /// - Parameters:
        ///   - seq: The monotonic sequence number to assign.
        ///   - ts: The instant to record.
        /// - Returns: The fully-stamped event.
        public func stamped(seq: Int, ts: Date) -> TranscriptEvent {
            TranscriptEvent(
                routerId: routerId,
                sessionId: sessionId,
                parentId: parentId,
                slot: slot,
                model: model,
                seq: seq,
                ts: ts,
                kind: kind,
                grammar: grammar,
                text: text,
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                ms: ms
            )
        }
    }
}
