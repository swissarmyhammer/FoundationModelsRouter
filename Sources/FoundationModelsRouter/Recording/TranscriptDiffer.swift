import FoundationModels

/// Diffs a last-seen `FoundationModels.Transcript` snapshot against a current
/// one and maps each new entry to an identity-stamped
/// ``TranscriptEvent/Partial`` via ``TranscriptEntryMapper``. Turn-specific
/// stamps (`grammar`, `ms`, token counts) are the caller's concern.
enum TranscriptDiffer {
    /// Returns the ordered partial events for every entry `current` gained
    /// beyond `lastSeen`, by position. A `current` that is not longer than
    /// `lastSeen` yields an empty diff.
    ///
    /// - Returns: The partial events, empty when `current` has nothing new.
    static func diff(
        lastSeen: Transcript,
        current: Transcript,
        routerId: ULID,
        sessionId: ULID,
        parentId: ULID?,
        slot: ModelSlot,
        model: ModelRef
    ) -> [TranscriptEvent.Partial] {
        let newEntries = current[min(lastSeen.count, current.count)...]
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
        let seenIds = Set(lastSeen.map(\.id))
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
    /// ``Baseline``. On a divergence the caller records no diff, logs a
    /// warning with ``description``, records one
    /// ``TranscriptEvent/Kind/divergence`` marker event, and resets its baseline.
    enum Divergence: Equatable, Sendable, CustomStringConvertible {
        /// The entry at `index` in the recorded prefix no longer carries the
        /// recorded id.
        case displaced(index: Int, recordedId: String, currentId: String)

        /// The boundary entry carries its recorded id but its content changed.
        /// Only the boundary index is probed.
        case rewrittenInPlace(index: Int, entryId: String)

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
            }
        }
    }

    /// Returns the first non-append change `current` shows against
    /// `baseline`, or `nil` when `current` still extends the recorded prefix.
    /// Checks every recorded id at its index first, then the boundary
    /// entry's payload. A `current` shorter than `baseline` returns `nil`.
    static func divergence(from baseline: Baseline, in current: Transcript) -> Divergence? {
        guard current.count >= baseline.entryIds.count else { return nil }
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

    /// ``divergence(from:in:)`` over a ``Baseline`` captured from `lastSeen`.
    static func divergence(lastSeen: Transcript, current: Transcript) -> Divergence? {
        divergence(from: Baseline(transcript: lastSeen), in: current)
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
