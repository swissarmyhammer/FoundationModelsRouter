import Foundation

/// A single recorded moment in a session's life, with the provenance needed
/// to place it in the router's transcript tree.
///
/// A ``TranscriptRecorder`` appends events. The recorder stamps `seq` and
/// `ts` at append (see ``TranscriptEvent/Partial``). `seq` is the monotonic
/// total order. `ts` is the wall-clock instant. Each event encodes as one
/// self-contained JSON object. Schema v2 is additive over v1: `entry`
/// decodes as `nil` when absent, and ``Kind/toolCall`` still decodes.
/// ``agentSpawn``, ``tokensCached``, ``timeToFirstTokenMs``, ``decodeMs``,
/// ``callMs``, ``firstTokenSeen`` and ``outputBuffered`` are later optional
/// keys within v2 and decode as `nil` when absent by the same rule.
public struct TranscriptEvent: Sendable, Codable, Equatable {
    /// What kind of moment an event records. Six kinds mirror
    /// `FoundationModels.Transcript.Entry` cases. ``session``, ``embedding``,
    /// ``divergence``, ``generationCall``, ``repeatedPartRemoval``,
    /// ``watchStop`` and ``mail`` are router-only. ``unknown``
    /// carries a newer SDK case.
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
        /// One generation call of a submission ended (see
        /// ``SessionEvent/generationCall(_:)``). Router-only.
        /// ``TranscriptEvent/tokensIn`` and ``TranscriptEvent/tokensOut`` hold
        /// the counts of that one call, ``TranscriptEvent/tokensCached`` holds
        /// the part of its fed tokens that the prompt cache reused when the
        /// backend reports one, and ``TranscriptEvent/text`` holds the
        /// ``GenerationCallUsage/description``. A reader of the usage of the submission
        /// stamp skips it: the stamp stays on the last `.response` event.
        case generationCall
        /// The session removed the repeated part of a stopped attempt from
        /// the render (task ^gg49g5e). Router-only. ``TranscriptEvent/entry``
        /// holds one ``RepeatedPartRemovalSegment``, which names the cut
        /// entries and the UTF-8 length that the render keeps of each, and
        /// ``TranscriptEvent/text`` holds its description. The recorded
        /// entries stay whole. A restore reads the segment and cuts the same
        /// entries of the rebuilt render. A journal recorded before this kind
        /// holds no such event, and restores as before.
        case repeatedPartRemoval
        /// The repetition watch stopped a pass (task ^0dcsd3t): a repetition
        /// stop or a reasoning stop. Router-only. ``TranscriptEvent/entry``
        /// holds one ``WatchStopSegment``, whose ``WatchStop`` names the kind
        /// of the stop, its tokens, its limit and its recovery, and
        /// ``TranscriptEvent/text`` holds the ``WatchStop/description``. The
        /// event comes after the entries of the stopped attempt. A restore
        /// skips it. A journal recorded before this kind holds no such event.
        case watchStop
        /// One or more facts about mail of the session (`mailbox.md`,
        /// section 5, problem 10): a mail entered the queue, a signal
        /// changed it, or it got its terminal event. Router-only.
        /// ``TranscriptEvent/entry`` holds one mail record segment
        /// (`MailRecordSegment`) for each fact, and ``TranscriptEvent/text``
        /// holds the summary of each, one line for each. The delivery of
        /// a mail is not this kind: it is a segment of the recorded `.prompt`
        /// entry of the submission that delivered the mail.
        /// The context render (`ContextRenderer`) does not render this kind. A restore reads it
        /// to find the mail that a crash cut off. A journal recorded before
        /// this kind holds no such event.
        case mail
        /// A tool invocation was requested. Deprecated: ``toolCalls`` replaces
        /// it. Kept so pre-v2 recordings decode.
        case toolCall
        /// A `Transcript.Entry` case this build does not know. The payload
        /// carries one ``SegmentPayload/unknown(id:description:)`` segment.
        case unknown

        /// `true` when this kind mirrors a real `FoundationModels.Transcript.Entry`.
        /// ``TranscriptTree/effectiveEntryEvents(forSession:)``,
        /// ``RoutedSessionActor/historyOrdinal`` and
        /// ``TranscriptEvent/mirrorsTranscriptEntry`` all use this predicate.
        var isEntryKind: Bool {
            switch self {
            case .instructions, .prompt, .toolCalls, .toolOutput, .response, .reasoning, .unknown:
                return true
            case .session, .embedding, .divergence, .generationCall, .repeatedPartRemoval, .watchStop, .mail,
                .toolCall:
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
    /// The part of ``tokensIn`` the prompt cache of the backend reused. Set
    /// only on a ``Kind/generationCall`` event whose backend reports a cache
    /// count; `nil` otherwise and on a recording made before this key existed.
    public let tokensCached: Int?
    /// Completion/output tokens metered for this event, when applicable.
    public let tokensOut: Int?
    /// Wall-clock duration of the event in milliseconds, when applicable.
    public let ms: Int?
    /// The time of the prefill of one generation call in milliseconds: from
    /// the start of the call to its first output token
    /// (``GenerationCallUsage/timeToFirstToken``). Set only on a
    /// ``Kind/generationCall`` event whose session saw that token; `nil`
    /// otherwise and on a recording made before this key existed.
    public let timeToFirstTokenMs: Int?
    /// The time of the decode of one generation call in milliseconds: from
    /// its first output token to its end (``GenerationCallUsage/decodeTime``).
    /// Set and `nil` by the rule of ``timeToFirstTokenMs``.
    public let decodeMs: Int?
    /// The whole time of one generation call in milliseconds
    /// (``GenerationCallUsage/callDuration``). Set on each
    /// ``Kind/generationCall`` event that a session measured; `nil` otherwise
    /// and on a recording made before this key existed.
    public let callMs: Int?
    /// Whether the session saw the first output token of one generation call
    /// (``GenerationCallUsage/firstTokenSeen``, task ^0m997jr). Set on each
    /// ``Kind/generationCall`` event; `nil` otherwise and on a recording made
    /// before this key existed. `false` means the event has no
    /// ``timeToFirstTokenMs`` and no ``decodeMs`` because the split is
    /// unknown, not because it is zero.
    public let firstTokenSeen: Bool?
    /// Whether the output of one generation call reached the session as
    /// exactly one output event (``GenerationCallUsage/outputBuffered``,
    /// task ^kg3yjc9). Set on each ``Kind/generationCall`` event; `nil`
    /// otherwise and on a recording made before this key existed. `true`
    /// means the event's ``firstTokenSeen`` is `false` by design: the first
    /// token of a buffered call cannot be seen.
    public let outputBuffered: Bool?
    /// The structural mirror of the `FoundationModels.Transcript.Entry` this
    /// event records. `nil` for v1 recordings, and for each router-only kind
    /// except ``Kind/repeatedPartRemoval``, ``Kind/watchStop`` and
    /// ``Kind/mail``, whose payload carries its ``RepeatedPartRemovalSegment``,
    /// its ``WatchStopSegment`` or its mail record segments and mirrors no
    /// entry.
    public let entry: TranscriptEntryPayload?
    /// The parent session and tool call that spawned this event's session.
    /// Set only on the ``Kind/session`` event of a session made with an
    /// `agentSpawn`. `nil` for a root session, for a fork, on every other
    /// kind, and on a recording made before this key existed. The value
    /// matches ``SessionRecord/agentSpawn`` in the session's `index.md`.
    /// A live sink sees it when the first submission of the session begins,
    /// because the `session` event is recorded at the first submission, not at
    /// session creation.
    public let agentSpawn: SessionRecord.AgentSpawn?

    /// `true` when this event is the close the router appends to a submission
    /// of an answer that ended with no `.response` entry from the SDK (see
    /// `RoutedSessionActor.recordFailedSubmission`). The close is a `.response`
    /// with no body text and a duration stamp whose entry holds no segment:
    /// the submission answered with nothing. A recording made before the
    /// close carried an entry has `entry == nil` on the same event. The SDK
    /// never appends a `.response` entry with no segment, so the shape names
    /// the router's close and nothing else. A reader that rebuilds the SDK's
    /// transcript, or that reads a usage stamp, skips this event.
    ///
    /// The name changed in task ^5d0qx1b. The bytes on disk did not change:
    /// this value is read from the shape of the event, and no key holds it.
    public var isFailedAnswerClose: Bool {
        kind == .response && text == nil && ms != nil && (entry?.segments?.isEmpty ?? true)
    }

    /// `true` when this event mirrors a `FoundationModels.Transcript.Entry`
    /// that a reader can rebuild: an entry kind that is not the router's
    /// close of a failed submission. `false` for every router-only marker (``Kind/session``,
    /// ``Kind/embedding``, ``Kind/divergence``, ``Kind/generationCall``,
    /// ``Kind/repeatedPartRemoval``, ``Kind/watchStop``, ``Kind/mail``, the legacy ``Kind/toolCall``)
    /// and for the close, none of which mirrors an entry. A reader that
    /// rebuilds the SDK's transcript skips an event where this is `false`. An
    /// entry-kind event with no `entry` (a v1 line) still reads `true`, so that
    /// reader refuses it instead of passing over it.
    public var mirrorsTranscriptEntry: Bool {
        kind.isEntryKind && !isFailedAnswerClose
    }

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
        tokensCached: Int? = nil,
        tokensOut: Int? = nil,
        ms: Int? = nil,
        timeToFirstTokenMs: Int? = nil,
        decodeMs: Int? = nil,
        callMs: Int? = nil,
        firstTokenSeen: Bool? = nil,
        outputBuffered: Bool? = nil,
        entry: TranscriptEntryPayload? = nil,
        agentSpawn: SessionRecord.AgentSpawn? = nil
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
        self.tokensCached = tokensCached
        self.tokensOut = tokensOut
        self.ms = ms
        self.timeToFirstTokenMs = timeToFirstTokenMs
        self.decodeMs = decodeMs
        self.callMs = callMs
        self.firstTokenSeen = firstTokenSeen
        self.outputBuffered = outputBuffered
        self.entry = entry
        self.agentSpawn = agentSpawn
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
        /// The part of ``tokensIn`` the prompt cache reused, or `nil`; see
        /// ``TranscriptEvent/tokensCached``.
        public let tokensCached: Int?
        /// Output tokens metered, or `nil`.
        public let tokensOut: Int?
        /// Duration in milliseconds, or `nil`.
        public let ms: Int?
        /// The time to the first output token of a generation call in
        /// milliseconds, or `nil`; see ``TranscriptEvent/timeToFirstTokenMs``.
        public let timeToFirstTokenMs: Int?
        /// The decode time of a generation call in milliseconds, or `nil`;
        /// see ``TranscriptEvent/decodeMs``.
        public let decodeMs: Int?
        /// The whole time of a generation call in milliseconds, or `nil`;
        /// see ``TranscriptEvent/callMs``.
        public let callMs: Int?
        /// Whether the session saw the first output token of a generation
        /// call, or `nil`; see ``TranscriptEvent/firstTokenSeen``.
        public let firstTokenSeen: Bool?
        /// Whether the output of a generation call was buffered, or `nil`;
        /// see ``TranscriptEvent/outputBuffered``.
        public let outputBuffered: Bool?
        /// The structural entry payload, or `nil`.
        public let entry: TranscriptEntryPayload?
        /// The spawn context, or `nil`. Set only on a ``Kind/session``
        /// partial of a session made with an `agentSpawn`; see
        /// ``TranscriptEvent/agentSpawn``.
        public let agentSpawn: SessionRecord.AgentSpawn?

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
            tokensCached: Int? = nil,
            tokensOut: Int? = nil,
            ms: Int? = nil,
            timeToFirstTokenMs: Int? = nil,
            decodeMs: Int? = nil,
            callMs: Int? = nil,
            firstTokenSeen: Bool? = nil,
            outputBuffered: Bool? = nil,
            entry: TranscriptEntryPayload? = nil,
            agentSpawn: SessionRecord.AgentSpawn? = nil
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
            self.tokensCached = tokensCached
            self.tokensOut = tokensOut
            self.ms = ms
            self.timeToFirstTokenMs = timeToFirstTokenMs
            self.decodeMs = decodeMs
            self.callMs = callMs
            self.firstTokenSeen = firstTokenSeen
            self.outputBuffered = outputBuffered
            self.entry = entry
            self.agentSpawn = agentSpawn
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
                tokensCached: tokensCached,
                tokensOut: tokensOut ?? self.tokensOut,
                ms: ms,
                timeToFirstTokenMs: timeToFirstTokenMs,
                decodeMs: decodeMs,
                callMs: callMs,
                firstTokenSeen: firstTokenSeen,
                outputBuffered: outputBuffered,
                entry: entry ?? self.entry,
                agentSpawn: agentSpawn
            )
        }

        // sah:allow duplication forwards a Partial's fields plus the recorder-stamped seq and ts into a TranscriptEvent's memberwise initializer; the other memberwise copies in this package build a different type with a different field list, so the bodies share shape only and a change to one never applies to the other
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
                tokensCached: tokensCached,
                tokensOut: tokensOut,
                ms: ms,
                timeToFirstTokenMs: timeToFirstTokenMs,
                decodeMs: decodeMs,
                callMs: callMs,
                firstTokenSeen: firstTokenSeen,
                outputBuffered: outputBuffered,
                entry: entry,
                agentSpawn: agentSpawn
            )
        }
    }
}
