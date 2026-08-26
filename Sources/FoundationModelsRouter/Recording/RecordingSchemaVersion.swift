import Foundation

/// The registry of on-disk recording schema versions.
///
/// One version is stamped per session on its ``SessionSidecar``.
/// ``SessionSidecar/read(in:)`` refuses a version newer than ``current``.
/// An equal or older version decodes by the additive rule: a field the
/// version predates decodes as its documented absent-value.
enum RecordingSchemaVersion {
    /// Version 1: flat ``TranscriptEvent`` lines with `text` only and no
    /// ``TranscriptEvent/entry`` payload.
    static let v1 = 1

    /// Version 2: adds ``TranscriptEvent/entry`` (``TranscriptEntryPayload``),
    /// the SDK-mirroring entry kinds, and ``TranscriptEntryPayload/contentRemoved``.
    /// Later optional keys and the `unknown` and `divergence` carriers landed
    /// within v2 by the additive rule.
    static let v2 = 2

    /// The version writers stamp on every new sidecar.
    static let current = v2

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
