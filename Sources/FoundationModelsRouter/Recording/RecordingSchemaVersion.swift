import Foundation

/// The registry of on-disk recording schema versions.
///
/// One version is stamped per session on its ``SessionSidecar``.
/// ``SessionSidecar/read(in:)`` refuses a version newer than ``current``.
/// An equal or older version decodes by the additive rule: a field the
/// version predates decodes as its documented absent-value.
enum RecordingSchemaVersion {
    /// Version 2: adds ``TranscriptEvent/entry`` (``TranscriptEntryPayload``),
    /// the SDK-mirroring entry kinds, and ``TranscriptEntryPayload/contentRemoved``.
    /// Later optional keys and the `unknown` and `divergence` carriers landed
    /// within v2 by the additive rule. The optional
    /// ``TranscriptEvent/agentSpawn`` key on the `session` event is one of
    /// them: absent, it decodes as `nil`.
    static let v2 = 2

    /// Version 3: the context projection changes (`mailbox.md`, section 5,
    /// problems 10 and 12). The recorded `.prompt` entry of a submission
    /// carries one ``MailRecordSegment`` for each mail that it delivered, in
    /// take order, in place of one ``OperationEventSegment`` for each run
    /// event, and its text is the render of that mail in take order
    /// (``ContextRenderer/promptText(delivering:followedBy:)``). The
    /// ``TranscriptEvent/Kind/mail`` events record the other facts about
    /// mail. A reader of this version still reads a v2 recording: a v2
    /// `.prompt` entry has no mail record, and it renders as before.
    static let v3 = 3

    /// The version writers stamp on every new sidecar.
    static let current = v3

    /// The version a sidecar with no `schemaVersion` key decodes as.
    /// Frozen at ``v2``: a future bump of ``current`` must not move this.
    static let implicit = v2
}

/// A recording stamped with a schema version newer than this reader knows.
/// Thrown by ``SessionSidecar/read(in:)`` and every reader built on it.
enum RecordingSchemaVersionError: Error, Equatable, LocalizedError {
    /// The sidecar in `directory` carries `version`, newer than `supported`.
    case recordingFromNewerRouter(directory: URL, version: Int, supported: Int)

    /// A localized message describing what error occurred.
    var errorDescription: String? {
        switch self {
        case .recordingFromNewerRouter(let directory, let version, let supported):
            return """
                Recording at \(directory.path) carries schema version \(version), newer than the \
                newest version this reader knows (\(supported)). It was written by a newer router \
                and cannot be read without misreading it.
                """
        }
    }
}
