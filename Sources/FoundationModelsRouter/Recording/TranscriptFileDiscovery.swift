import Foundation

/// The one recording-file discovery path every reader in this module
/// (``TranscriptTree`` and ``MergedTranscript``) shares, so the two
/// enumerations cannot drift. Discovery is shared here the same way both
/// readers share one line reader, the Extras `JSONLFile`.
enum TranscriptFileDiscovery {
    /// Finds every file named `fileName` nested at any depth under
    /// `directory`.
    ///
    /// The search skips each hidden file and each hidden folder, with what it
    /// holds. A session folder has the name of a ULID, so a hidden folder is
    /// never a session folder: it is, for example, the temporary folder of a
    /// session recording that is in progress
    /// (``RoutedModel/recordSession(from:configuration:)``), or that a stopped
    /// process left.
    ///
    /// - Parameters:
    ///   - fileName: The file name to match.
    ///   - directory: The recording root to search.
    /// - Returns: The discovered file URLs, in no particular order.
    static func fileURLs(named fileName: String, under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            files.append(url)
        }
        return files
    }
}
