import FoundationModels

/// Diffs a recorded `FoundationModels.Transcript` baseline against a current
/// one and maps each new entry to an identity-stamped
/// ``TranscriptEvent/Partial`` via ``TranscriptEntryMapper``. Turn-specific
/// stamps (`grammar`, `ms`, token counts) are the caller's concern.
enum TranscriptDiffer {
    /// The partials a recorder appends for `current` against `baseline`: the
    /// positional diff past the recorded count while `divergence` is `nil`,
    /// and the diff by entry id
    /// (``diffByEntryId(baseline:current:routerId:sessionId:parentId:slot:model:)``)
    /// once the transcript diverged. So every entry the record has never seen
    /// is appended, and a recorded entry is never appended a second time.
    ///
    /// - Returns: The partial events, in `current`'s order.
    static func partials(
        baseline: Baseline,
        current: Transcript,
        divergence: Divergence?,
        routerId: ULID,
        sessionId: ULID,
        parentId: ULID?,
        slot: ModelSlot,
        model: ModelRef
    ) -> [TranscriptEvent.Partial] {
        guard divergence == nil else {
            return diffByEntryId(
                baseline: baseline, current: current, routerId: routerId, sessionId: sessionId,
                parentId: parentId, slot: slot, model: model)
        }
        return diffByPosition(
            recordedCount: baseline.entryIds.count, current: current, routerId: routerId, sessionId: sessionId,
            parentId: parentId, slot: slot, model: model)
    }

    /// Maps every entry of `current` past index `recordedCount`, in order. A
    /// `current` no longer than `recordedCount` maps nothing.
    private static func diffByPosition(
        recordedCount: Int,
        current: Transcript,
        routerId: ULID,
        sessionId: ULID,
        parentId: ULID?,
        slot: ModelSlot,
        model: ModelRef
    ) -> [TranscriptEvent.Partial] {
        let newEntries = current[min(recordedCount, current.count)...]
        return mapPartials(
            newEntries, routerId: routerId, sessionId: sessionId, parentId: parentId, slot: slot, model: model)
    }

    /// Returns the ordered partial events for every entry in `current` whose
    /// `Transcript.Entry.id` is not in `lastSeen`. A compaction fold makes
    /// `current` shorter than `lastSeen`, so only entry identity can say
    /// what is new.
    ///
    /// - Returns: The partial events, in `current`'s order.
    static func diffByEntryId(
        lastSeen: Transcript,
        current: Transcript,
        routerId: ULID,
        sessionId: ULID,
        parentId: ULID?,
        slot: ModelSlot,
        model: ModelRef
    ) -> [TranscriptEvent.Partial] {
        diffByEntryId(
            seenIds: Set(lastSeen.map(\.id)), current: current, routerId: routerId, sessionId: sessionId,
            parentId: parentId, slot: slot, model: model)
    }

    /// Returns the ordered partial events for every entry in `current` whose
    /// `Transcript.Entry.id` is not in `baseline`. A diverged transcript's
    /// recorded set is the baseline's ids, not its positional prefix, so this
    /// is the diff for a turn ``divergence(from:in:)`` reported on.
    ///
    /// - Returns: The partial events, in `current`'s order.
    static func diffByEntryId(
        baseline: Baseline,
        current: Transcript,
        routerId: ULID,
        sessionId: ULID,
        parentId: ULID?,
        slot: ModelSlot,
        model: ModelRef
    ) -> [TranscriptEvent.Partial] {
        diffByEntryId(
            seenIds: Set(baseline.entryIds), current: current, routerId: routerId, sessionId: sessionId,
            parentId: parentId, slot: slot, model: model)
    }

    /// Maps every entry of `current` whose id is not in `seenIds`, in order.
    private static func diffByEntryId(
        seenIds: Set<String>,
        current: Transcript,
        routerId: ULID,
        sessionId: ULID,
        parentId: ULID?,
        slot: ModelSlot,
        model: ModelRef
    ) -> [TranscriptEvent.Partial] {
        let unseenEntries = current.filter { !seenIds.contains($0.id) }
        return mapPartials(
            unseenEntries, routerId: routerId, sessionId: sessionId, parentId: parentId, slot: slot, model: model)
    }

    /// The identity of the recorded backend-transcript prefix: the ordered
    /// entry ids plus the boundary (newest recorded) entry's mapped payload.
    /// ``divergence(from:in:)`` compares a later transcript against this.
    struct Baseline: Sendable, Equatable {
        /// The recorded entries' ids, in transcript order.
        let entryIds: [String]
        /// The boundary entry's mapped payload, or `nil` when nothing was recorded.
        let boundaryPayload: TranscriptEntryPayload?

        /// Captures `transcript`'s entry ids and its last entry's mapped payload.
        init(transcript: Transcript) {
            entryIds = transcript.map(\.id)
            boundaryPayload = transcript.last.map { TranscriptEntryMapper.event(from: $0).payload }
        }
    }

    /// One detected non-append backend-transcript change against a recorded
    /// ``Baseline``. A divergence is a note about the record, never a reason
    /// to drop an entry: the caller records the entries whose id the baseline
    /// does not hold
    /// (``partials(baseline:current:divergence:routerId:sessionId:parentId:slot:model:)``),
    /// then one ``TranscriptEvent/Kind/divergence`` marker event whose body
    /// is ``description``, logs a warning, and takes the current transcript
    /// as its next baseline.
    enum Divergence: Equatable, Sendable, CustomStringConvertible {
        /// The entry at `index` in the recorded prefix no longer carries the
        /// recorded id.
        case displaced(index: Int, recordedId: String, currentId: String)

        /// The boundary entry carries its recorded id but its content changed.
        /// Only the boundary index is probed.
        case rewrittenInPlace(index: Int, entryId: String)

        /// The transcript holds fewer entries than the recorded prefix, so
        /// some recorded entry is gone from the backend.
        case shrank(recordedCount: Int, currentCount: Int)

        /// What diverged, and where — the warning-log and marker-event body.
        var description: String {
            switch self {
            case .displaced(let index, let recordedId, let currentId):
                return """
                    backend transcript no longer matches the recorded prefix at entry index \(index): \
                    recorded entry id \(recordedId), current entry id \(currentId) — a mid-transcript \
                    insertion or a rewrite under a new id
                    """
            case .rewrittenInPlace(let index, let entryId):
                return """
                    backend transcript rewrote the recorded entry at index \(index) in place: entry id \
                    \(entryId) is unchanged but its content differs from what was recorded
                    """
            case .shrank(let recordedCount, let currentCount):
                return """
                    backend transcript shrank from \(recordedCount) recorded entries to \(currentCount): \
                    some recorded entry is gone from the backend
                    """
            }
        }
    }

    /// Returns the first non-append change `current` shows against
    /// `baseline`, or `nil` when `current` still extends the recorded prefix.
    /// A `current` shorter than `baseline` is
    /// ``Divergence/shrank(recordedCount:currentCount:)``. Otherwise every
    /// recorded id is checked at its index first, then the boundary entry's
    /// payload.
    static func divergence(from baseline: Baseline, in current: Transcript) -> Divergence? {
        guard current.count >= baseline.entryIds.count else {
            return .shrank(recordedCount: baseline.entryIds.count, currentCount: current.count)
        }
        for (index, (recordedId, entry)) in zip(baseline.entryIds, current).enumerated()
        where entry.id != recordedId {
            return .displaced(index: index, recordedId: recordedId, currentId: entry.id)
        }
        guard let boundaryPayload = baseline.boundaryPayload else { return nil }
        let boundaryIndex = baseline.entryIds.count - 1
        guard TranscriptEntryMapper.event(from: current[boundaryIndex]).payload == boundaryPayload else {
            return .rewrittenInPlace(index: boundaryIndex, entryId: baseline.entryIds[boundaryIndex])
        }
        return nil
    }

    /// Maps `entries` to stamped ``TranscriptEvent/Partial`` values that carry
    /// the given session identity.
    private static func mapPartials(
        _ entries: some Sequence<Transcript.Entry>,
        routerId: ULID,
        sessionId: ULID,
        parentId: ULID?,
        slot: ModelSlot,
        model: ModelRef
    ) -> [TranscriptEvent.Partial] {
        entries.map { entry in
            partial(for: entry, routerId: routerId, sessionId: sessionId, parentId: parentId, slot: slot, model: model)
        }
    }

    /// Maps one transcript entry to its stamped ``TranscriptEvent/Partial``.
    private static func partial(
        for entry: Transcript.Entry,
        routerId: ULID,
        sessionId: ULID,
        parentId: ULID?,
        slot: ModelSlot,
        model: ModelRef
    ) -> TranscriptEvent.Partial {
        let mapped = TranscriptEntryMapper.event(from: entry)
        return TranscriptEvent.Partial(
            routerId: routerId,
            sessionId: sessionId,
            parentId: parentId,
            slot: slot,
            model: model,
            kind: mapped.kind,
            text: mapped.text,
            entry: mapped.payload
        )
    }

    /// `transcript` with its leading `.instructions` entry carrying
    /// `instructions` in place of the recorded text.
    ///
    /// A backend seeded from a transcript reads its instructions from that one
    /// entry: ``LoadedLLMContainer/makeSession(transcript:tools:)`` takes no
    /// instructions argument. So this substitution is how a restore gives the
    /// model a caller's fresh instructions.
    ///
    /// A leading `.instructions` entry keeps its recorded id and its recorded
    /// tool definitions, so the entry's identity survives and a later diff
    /// still matches it. A transcript that opens with another entry, or that
    /// is empty, gets a new leading `.instructions` entry instead.
    ///
    /// The result is a new value. `transcript` itself is unchanged, and so is
    /// every recorded event it was reconstructed from.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to substitute into.
    ///   - instructions: The instructions the model must read.
    /// - Returns: The substituted transcript.
    static func replacingLeadingInstructions(
        of transcript: Transcript, with instructions: String
    ) -> Transcript {
        let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: instructions))]
        var entries = Array(transcript)
        guard let first = entries.first, case .instructions(let recorded) = first else {
            let inserted = Transcript.Instructions(segments: segments, toolDefinitions: [])
            return Transcript(entries: [.instructions(inserted)] + entries)
        }
        entries[0] = .instructions(
            Transcript.Instructions(
                id: recorded.id, segments: segments, toolDefinitions: recorded.toolDefinitions))
        return Transcript(entries: entries)
    }

    /// The joined text of `transcript`'s first entry when it is an
    /// `.instructions` entry, or `nil`.
    static func leadingInstructionsText(of transcript: Transcript) -> String? {
        guard let first = transcript.first, case .instructions(let instructions) = first else {
            return nil
        }
        let textContents = instructions.segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
        return textContents.isEmpty ? nil : textContents.joined()
    }
}
