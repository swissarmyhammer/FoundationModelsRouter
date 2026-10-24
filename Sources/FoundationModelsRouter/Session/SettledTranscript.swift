import FoundationModels

/// The transcript of a session as of its last settled point, with the
/// recording cut of that same point.
///
/// A settled point is a moment when no SDK call writes the backend
/// transcript: the end of a submission, after its recording diff; a
/// tool-result boundary of the session's own open model call, where the SDK
/// waits in the tool call; and a reseed of the backend (a compaction, or the
/// render after a repetition stop). ``RoutedSessionActor`` keeps one value and
/// serves each transcript read from it. So a read waits for no submission,
/// and copies no transcript that the SDK writes on its own task.
struct SettledTranscript: Sendable {
    /// The entries of the backend transcript at the settled point.
    let entries: [Transcript.Entry]

    /// How many leading entries of ``entries`` the session had recorded at
    /// the settled point (``RoutedSessionActor/persistedEntryCount``). At a
    /// tool-result boundary, the entries of the running submission come after
    /// them: the session records them at the end of the submission.
    let recordedEntryCount: Int

    /// The entries as a transcript.
    var transcript: Transcript {
        Transcript(entries: entries)
    }
}
