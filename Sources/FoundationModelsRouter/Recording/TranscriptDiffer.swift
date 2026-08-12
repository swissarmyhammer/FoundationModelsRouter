import FoundationModels

/// Diffs a last-seen `FoundationModels.Transcript` snapshot against a current
/// one and maps every entry `current` gained beyond `lastSeen` into ordered,
/// identity-stamped ``TranscriptEvent/Partial`` values via
/// ``TranscriptEntryMapper``.
///
/// This is the single last-seen-vs-current diff implementation shared by
/// ``RoutedSessionActor``'s recorder-bracketed generate chokepoint and the
/// upcoming recording handle (`RecordingLanguageModel`): both hold a session's
/// identity fixed across every turn and only need to know what the SDK's own
/// transcript gained since the last snapshot they persisted.
///
/// Deliberately narrow in scope: it produces the mapped `kind`/`text`/`entry`
/// for each new entry plus the given session identity, and nothing else —
/// turn-specific stamps (`grammar`, `ms`, `tokensIn`/`tokensOut`) are the
/// caller's concern, since they vary per turn while the diff itself does not.
enum TranscriptDiffer {
    /// Returns the ordered partial events for every entry `current` gained
    /// beyond `lastSeen`.
    ///
    /// Slices `current` from `min(lastSeen.count, current.count)` — never a
    /// bare `current[lastSeen.count...]` — so a `current` that is no longer
    /// than `lastSeen` (nothing new, or a shrink the caller has not otherwise
    /// guarded against) safely yields an empty diff rather than trapping on an
    /// out-of-bounds slice.
    ///
    /// - Parameters:
    ///   - lastSeen: The transcript snapshot already persisted.
    ///   - current: The transcript's current state.
    ///   - routerId: The recording root id stamped onto every produced partial.
    ///   - sessionId: The session span id stamped onto every produced partial.
    ///   - parentId: The forking session's span id, or `nil` for a root,
    ///     stamped onto every produced partial.
    ///   - slot: The routed model slot stamped onto every produced partial.
    ///   - model: The concrete model reference stamped onto every produced
    ///     partial.
    /// - Returns: The ordered partial events new entries in `current` map to,
    ///   via ``TranscriptEntryMapper/event(from:)`` — empty when `current`
    ///   carries nothing beyond `lastSeen`.
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
    /// `Transcript.Entry.id` was never recorded in `lastSeen` — the identity-
    /// based counterpart to ``diff(lastSeen:current:routerId:sessionId:parentId:slot:model:)``'s
    /// positional (count-based) diff.
    ///
    /// A compaction's fold is not a mere extension of `lastSeen`: the
    /// synthesized summary entry replaces a folded span and `current` is
    /// typically *shorter* than `lastSeen`, so a positional diff cannot say
    /// what is new — only entry identity can (compaction_plan.md §1.5, §3).
    /// Used by ``RecordingLanguageModelState/noteCompaction(_:)``, the
    /// bare-session counterpart to `RoutedSessionActor`'s in-place `compact()`
    /// swap.
    ///
    /// - Parameters:
    ///   - lastSeen: The transcript snapshot already persisted — every entry
    ///     it carries is treated as already recorded, regardless of position.
    ///   - current: The transcript's current (post-fold) state.
    ///   - routerId: The recording root id stamped onto every produced partial.
    ///   - sessionId: The session span id stamped onto every produced partial.
    ///   - parentId: The forking session's span id, or `nil` for a root,
    ///     stamped onto every produced partial.
    ///   - slot: The routed model slot stamped onto every produced partial.
    ///   - model: The concrete model reference stamped onto every produced
    ///     partial.
    /// - Returns: The ordered partial events for `current`'s never-before-seen
    ///   entries, in `current`'s own order — empty when every entry in
    ///   `current` already appears in `lastSeen`.
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

    /// The identity of the backend-transcript prefix a recording chokepoint
    /// has already persisted: the ordered `Transcript.Entry.id`s of every
    /// recorded entry, plus the boundary (newest recorded) entry's mapped
    /// ``TranscriptEntryPayload`` for the in-place-rewrite probe.
    ///
    /// ``divergence(from:in:)`` compares a later backend transcript against
    /// this instead of against a bare count, so a non-append change — a
    /// mid-transcript insertion, a rewrite under a new id, or an in-place
    /// rewrite of the boundary entry under its original id — is detected
    /// rather than silently mis-recorded by the positional
    /// ``diff(lastSeen:current:routerId:sessionId:parentId:slot:model:)``.
    ///
    /// `RecordingLanguageModelState` derives one per call from the `lastSeen`
    /// snapshot it already holds; `RoutedSessionActor` — whose baseline is
    /// only a count — stores one (`persistedBaseline`) and refreshes it
    /// wherever it refreshes the count.
    struct Baseline: Sendable, Equatable {
        /// The recorded entries' ids, in transcript order.
        let entryIds: [String]
        /// The boundary (newest recorded) entry's mapped payload, or `nil`
        /// when nothing was recorded — the equality probe
        /// ``divergence(from:in:)`` runs at the boundary index only.
        let boundaryPayload: TranscriptEntryPayload?

        /// Captures `transcript`'s identity — its entry ids plus its last
        /// entry's mapped payload.
        ///
        /// - Parameter transcript: The recorded prefix to capture.
        init(transcript: Transcript) {
            entryIds = transcript.map(\.id)
            boundaryPayload = transcript.last.map { TranscriptEntryMapper.event(from: $0).payload }
        }
    }

    /// One detected non-append backend-transcript change against an already-
    /// recorded ``Baseline`` — what ``divergence(from:in:)`` returns.
    ///
    /// **The documented signal shape** (shared by both chokepoints,
    /// `RoutedSessionActor.recordTranscriptDelta` and
    /// `RecordingLanguageModelState.diffAndRecord`): on a detected
    /// divergence the caller records **no** diff for that call — a
    /// positional diff of a non-append change is wrong by construction — and
    /// instead emits the loud, typed signal: a warning log carrying
    /// ``description`` plus one recorded ``TranscriptEvent/Kind/divergence``
    /// marker event whose text is ``description``, then resets its baseline
    /// to the current transcript so later calls diff from reality. A thrown
    /// error was deliberately rejected: both chokepoints are non-throwing
    /// and run on the success and throwing exits of every turn, so a throw
    /// would change turn semantics far beyond recording. This mirrors the
    /// shrink guards' established "log loud, record nothing, reset the
    /// baseline" shape, with the marker event added because a divergence —
    /// unlike a shrink, which drops entries a reader can see are missing —
    /// leaves recorded content that no longer matches the backend.
    enum Divergence: Equatable, Sendable, CustomStringConvertible {
        /// The entry at `index` in the already-recorded prefix no longer
        /// carries the recorded id — a mid-transcript insertion displaced
        /// it, or a rewrite replaced it under a new id (the two are not
        /// distinguishable from ids alone).
        case displaced(index: Int, recordedId: String, currentId: String)

        /// The boundary (newest recorded) entry still carries its recorded
        /// id but its content changed — an in-place rewrite. Probed at the
        /// boundary index only, by cost: a deeper same-id rewrite would need
        /// a content comparison across the whole prefix on every call.
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
    /// `baseline`, or `nil` when `current` still extends what was recorded.
    ///
    /// Two checks, in order:
    ///
    /// 1. **Prefix ids** (cheap, ids only): every recorded id must still
    ///    stand at its recorded index. The first mismatch is
    ///    ``Divergence/displaced(index:recordedId:currentId:)``.
    /// 2. **Boundary probe** (one entry's payload equality): the newest
    ///    recorded entry, re-mapped from `current`, must equal the recorded
    ///    ``Baseline/boundaryPayload``. A mismatch is
    ///    ``Divergence/rewrittenInPlace(index:entryId:)``. Deliberately
    ///    scoped to the boundary index only — see that case's doc.
    ///
    /// Callers run their existing shrink guard first: a `current` shorter
    /// than `baseline` returns `nil` here, because a shrink already has its
    /// own established signal and reset.
    ///
    /// - Parameters:
    ///   - baseline: The recorded prefix's identity.
    ///   - current: The transcript's current state.
    /// - Returns: The first detected divergence, or `nil`.
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

    /// Returns the first non-append change `current` shows against the
    /// `lastSeen` snapshot — ``divergence(from:in:)`` over a
    /// ``Baseline`` captured from `lastSeen`, for the chokepoint
    /// (`RecordingLanguageModelState.diffAndRecord`) that holds the full
    /// prior transcript rather than a stored ``Baseline``.
    ///
    /// - Parameters:
    ///   - lastSeen: The transcript snapshot already persisted.
    ///   - current: The transcript's current state.
    /// - Returns: The first detected divergence, or `nil`.
    static func divergence(lastSeen: Transcript, current: Transcript) -> Divergence? {
        divergence(from: Baseline(transcript: lastSeen), in: current)
    }

    /// Maps a sequence of real transcript entries to their stamped
    /// ``TranscriptEvent/Partial`` values via ``partial(for:routerId:sessionId:parentId:slot:model:)``,
    /// carrying the given session identity — the single entries-to-partials
    /// mapping both ``diff(lastSeen:current:routerId:sessionId:parentId:slot:model:)``
    /// and ``diffByEntryId(lastSeen:current:routerId:sessionId:parentId:slot:model:)``
    /// share, since they differ only in *which* entries of `current` they
    /// consider new, not in how new entries become partials.
    ///
    /// - Parameters:
    ///   - entries: The new entries to map, in order.
    ///   - routerId: The recording root id stamped onto every produced partial.
    ///   - sessionId: The session span id stamped onto every produced partial.
    ///   - parentId: The forking session's span id, or `nil` for a root,
    ///     stamped onto every produced partial.
    ///   - slot: The routed model slot stamped onto every produced partial.
    ///   - model: The concrete model reference stamped onto every produced
    ///     partial.
    /// - Returns: The ordered partial events `entries` maps to.
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

    /// Maps one real transcript entry to its stamped ``TranscriptEvent/Partial``
    /// via ``TranscriptEntryMapper``, carrying the given session identity —
    /// the single per-entry mapping ``mapPartials(_:routerId:sessionId:parentId:slot:model:)``
    /// shares across both diff variants.
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

    /// The text of `transcript`'s leading `.instructions` entry, or `nil` when
    /// `transcript` has none (or does not open with one).
    ///
    /// A `LanguageModelSession`'s transcript carries supplied instructions as
    /// its first entry, so this only ever looks at the transcript's first
    /// entry, not the whole sequence. Shared by
    /// ``MLXFoundationModelsContainer/makeSession(transcript:)`` (restoring a
    /// session's instructions from a persisted transcript) and
    /// ``RecordingLanguageModelState``'s lazy ``SessionSidecar`` write
    /// (deriving `instructions` from the first transcript this handle's diff
    /// observes) — one place instead of two independently
    /// re-deriving the same fact from a transcript's shape.
    ///
    /// - Parameter transcript: The transcript to inspect.
    /// - Returns: The leading instructions' joined text-segment content, or
    ///   `nil`.
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
