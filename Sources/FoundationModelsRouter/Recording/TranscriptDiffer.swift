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
        return newEntries.map { entry in
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
    }

    /// The text of `transcript`'s leading `.instructions` entry, or `nil` when
    /// `transcript` has none (or does not open with one).
    ///
    /// A `LanguageModelSession`'s transcript carries supplied instructions as
    /// its first entry, so this only ever looks at the transcript's first
    /// entry, not the whole sequence. Shared by
    /// ``MLXFoundationModelsContainer/makeSession(transcript:)`` (restoring a
    /// session's instructions from a persisted transcript) and
    /// ``RecordingLanguageModelState``'s lazy ``SessionIndexRecord``
    /// registration (deriving `instructions` from the first transcript this
    /// handle's diff observes) — one place instead of two independently
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
