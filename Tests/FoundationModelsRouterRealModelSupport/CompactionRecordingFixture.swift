import Foundation

/// The checked-in compaction recording this target bundles, and the one way
/// a suite reaches it.
///
/// The recording lives in this target's `Fixtures/CompactionRecording/`
/// directory and rides in this target's resource bundle, because two suites
/// in two different test targets read it: the gated
/// `RecordedTranscriptCompactionIntegrationTests` folds it against a real
/// model, and the hermetic `RecordedFixtureRedactionTests` scans its bytes
/// on every plain `swift test` (task ^cvsh3m9). Each `.xctest` bundles its
/// own resources, so hosting the files in either test target would hide
/// them from the other; this plain target's `Bundle.module` is visible to
/// both.
///
/// `Fixtures/CompactionRecording/README.md` records where the recording came
/// from, and `Tools/RecordCompactionFixture` is the tool that records it
/// again.
public enum CompactionRecordingFixture {
    /// The recording's path inside this target's resource bundle — one place,
    /// because the folding suite and the redaction scan must read the SAME
    /// directory or the scan proves nothing about what the fold consumed.
    public static let resourcePath = "Fixtures/CompactionRecording"

    /// The recording's root directory on disk, or `nil` when the resource
    /// bundle vends no resource URL.
    ///
    /// Optional rather than trapping, so each suite states its own failure
    /// message through its own `#require`.
    public static var directory: URL? {
        Bundle.module.resourceURL?.appendingPathComponent(resourcePath, isDirectory: true)
    }
}
