import FoundationModels

/// The transcript of a session as of its last settled point, with the
/// recording cut of that same point (`generation-queue.md`, section 5.8).
///
/// A settled point is a moment when no SDK call writes the backend
/// transcript: the end of a submission, after its recording diff; a
/// tool-result boundary of the session's own open model call, where the SDK
/// waits in the tool call; and a reseed of the backend (a compaction, or the
/// render after a repetition stop). ``RoutedSessionActor`` keeps one value and
/// serves each transcript read and each fork from it. So neither waits for a
/// submission, and neither copies a transcript that the SDK writes on its own
/// task.
struct SettledTranscript: Sendable {
    /// The entries of the backend transcript at the settled point.
    let entries: [Transcript.Entry]

    /// How many leading entries of ``entries`` the session had recorded at
    /// the settled point (``RoutedSessionActor/persistedEntryCount``). At a
    /// tool-result boundary, the entries of the running submission come after
    /// them: the session records them at the end of the submission.
    let recordedEntryCount: Int

    /// The position of the session in its own recorded history at the settled
    /// point (``RoutedSessionActor/historyOrdinal``).
    let historyOrdinal: Int

    /// The entries as a transcript.
    var transcript: Transcript {
        Transcript(entries: entries)
    }

    /// This value without the calls of the last round of tool calls that have
    /// no output (the rule of `InFlightTranscript.removingUnansweredCalls`).
    ///
    /// A fork seeds its child from it, so the child starts from a valid
    /// transcript: at a tool-result boundary, the calls of the open round have
    /// no output yet. The recorded count stops before the first entry the
    /// removal changed, so the child records the changed entry itself.
    ///
    /// - Returns: The value a fork seeds its child from.
    func removingUnansweredCalls() -> SettledTranscript {
        let seed = InFlightTranscript.removingUnansweredCalls(from: entries)
        let unchangedPrefixCount = zip(seed, entries).prefix { $0 == $1 }.count
        return SettledTranscript(
            entries: seed,
            recordedEntryCount: min(recordedEntryCount, unchangedPrefixCount),
            historyOrdinal: historyOrdinal)
    }
}
