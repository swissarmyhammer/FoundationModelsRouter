import Foundation

/// A single recorded moment in a session's life, with the provenance needed
/// to place it in the router's transcript tree.
///
/// A ``TranscriptRecorder`` appends events. The recorder stamps `seq` and
/// `ts` at append (see ``TranscriptEvent/Partial``). `seq` is the monotonic
/// total order. `ts` is the wall-clock instant. Each event encodes as one
/// self-contained JSON object. Schema v2 is additive over v1: `entry`
/// decodes as `nil` when absent, and ``Kind/toolCall`` still decodes.
public struct TranscriptEvent: Sendable, Codable, Equatable {
    /// What kind of moment an event records. Six kinds mirror
    /// `FoundationModels.Transcript.Entry` cases. ``session``, ``embedding``,
    /// and ``divergence`` are router-only. ``unknown`` carries a newer SDK case.
    public enum Kind: String, Sendable, Codable, Equatable {
        /// The session was created (its first event).
        case session
        /// An `.instructions` entry was appended to the SDK's own transcript.
        case instructions
        /// A `.prompt` entry was appended to the SDK's own transcript.
        case prompt
        /// A `.toolCalls` entry was appended to the SDK's own transcript.
        case toolCalls
        /// A tool returned output.
        case toolOutput
        /// A `.response` entry was appended to the SDK's own transcript.
        case response
        /// A `.reasoning` entry was appended to the SDK's own transcript.
        case reasoning
        /// An embedding was produced. No longer written: an embed call is no
        /// part of any session's conversation. Kept so recordings made before
        /// that change still decode.
        case embedding
        /// The backend's transcript changed in a non-append way against the
        /// recorded baseline (see ``TranscriptDiffer/divergence(from:in:)``).
        /// Router-only. ``TranscriptEvent/text`` holds the description.
        case divergence
        /// A tool invocation was requested. Deprecated: ``toolCalls`` replaces
        /// it. Kept so pre-v2 recordings decode.
        case toolCall
        /// A `Transcript.Entry` case this build does not know. The payload
        /// carries one ``SegmentPayload/unknown(id:description:)`` segment.
        case unknown

        /// `true` when this kind mirrors a real `FoundationModels.Transcript.Entry`.
        /// ``TranscriptTree/effectiveEntryEvents(forSession:)`` and
        /// ``RoutedSessionActor/historyOrdinal`` both use this predicate.
        var isEntryKind: Bool {
            switch self {
            case .instructions, .prompt, .toolCalls, .toolOutput, .response, .reasoning, .unknown:
                return true
            case .session, .embedding, .divergence, .toolCall:
                return false
            }
        }
    }

    /// The recording root id — the router instance that owns this transcript.
    let routerId: ULID
    /// The span id of the session this event belongs to.
    public let sessionId: ULID
    /// The span id of the session that forked this one, or `nil` for a root.
    public let parentId: ULID?
    /// The model slot this event was routed through, when applicable.
    public let slot: ModelSlot?
    /// The concrete model reference involved, when applicable.
    let model: ModelRef?
    /// The recorder-assigned monotonic sequence number — the log's total order.
    public let seq: Int
    /// The wall-clock instant the recorder stamped at append.
    let ts: Date
    /// What kind of moment this event records.
    public let kind: Kind
    /// The guided-generation grammar in force, when applicable.
    let grammar: String?
    /// The event's body text. `nil` when the event carries no body, which is
    /// the case for router-only kinds.
    public let text: String?
    /// Prompt/input tokens metered for this event, when applicable.
    public let tokensIn: Int?
    /// Completion/output tokens metered for this event, when applicable.
    public let tokensOut: Int?
    /// Wall-clock duration of the event in milliseconds, when applicable.
    public let ms: Int?
    /// The structural mirror of the `FoundationModels.Transcript.Entry` this
    /// event records. `nil` for router-only kinds and for v1 recordings.
    public let entry: TranscriptEntryPayload?

    /// Creates a fully-stamped event. Callers normally hand a
    /// ``TranscriptEvent/Partial`` to a recorder instead.
    init(
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
        ms: Int? = nil,
        entry: TranscriptEntryPayload? = nil
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
        self.entry = entry
    }

    /// An event minus the fields a recorder owns (`seq` and `ts`). The
    /// recorder assigns both atomically at append.
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
        /// The event's body text, or `nil` when the event carries no body.
        public let text: String?
        /// Input tokens metered, or `nil`.
        public let tokensIn: Int?
        /// Output tokens metered, or `nil`.
        public let tokensOut: Int?
        /// Duration in milliseconds, or `nil`.
        public let ms: Int?
        /// The structural entry payload, or `nil`.
        public let entry: TranscriptEntryPayload?

        /// Describes an event without its recorder-owned ordering fields.
        init(
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
            ms: Int? = nil,
            entry: TranscriptEntryPayload? = nil
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
            self.entry = entry
        }

        /// Returns a copy with ``text`` and ``entry`` replaced by
        /// `transform(text, entry)`. A ``GatingRecorder`` uses this to apply
        /// the recording level and redaction to both fields together.
        ///
        /// - Parameter transform: The transform applied to the body text and
        ///   the entry payload together.
        func mapBody(
            _ transform: (String?, TranscriptEntryPayload?) -> (String?, TranscriptEntryPayload?)
        ) -> Partial {
            let (mappedText, mappedEntry) = transform(text, entry)
            return with(text: mappedText, entry: mappedEntry)
        }

        /// Returns a copy with ``tokensIn`` and ``tokensOut`` replaced by the
        /// given values.
        func stampingUsage(tokensIn: Int?, tokensOut: Int?) -> Partial {
            with(tokensIn: tokensIn, tokensOut: tokensOut)
        }

        /// Returns a copy with the given fields replaced. Each parameter is
        /// doubly optional: the outer `nil` (the default) keeps the field.
        /// `.some(nil)` sets the field to `nil`.
        private func with(
            text: String?? = nil,
            tokensIn: Int?? = nil,
            tokensOut: Int?? = nil,
            entry: TranscriptEntryPayload?? = nil
        ) -> Partial {
            Partial(
                routerId: routerId,
                sessionId: sessionId,
                parentId: parentId,
                slot: slot,
                model: model,
                kind: kind,
                grammar: grammar,
                text: text ?? self.text,
                tokensIn: tokensIn ?? self.tokensIn,
                tokensOut: tokensOut ?? self.tokensOut,
                ms: ms,
                entry: entry ?? self.entry
            )
        }

        // sah:allow duplication forwards a Partial's fields plus the recorder-stamped seq and ts into a TranscriptEvent's memberwise initializer; withCompactionCount in SessionSidecar.swift copies a SessionSidecar, a different type with a different field list, so the two bodies share shape only and a change to one never applies to the other
        /// Stamps this partial with a recorder-assigned `seq` and `ts`, and
        /// returns the finished ``TranscriptEvent``.
        func stamped(seq: Int, ts: Date) -> TranscriptEvent {
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
                ms: ms,
                entry: entry
            )
        }
    }
}
