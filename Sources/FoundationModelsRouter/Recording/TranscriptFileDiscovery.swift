import Foundation

/// The one recording-file discovery path every reader in this module
/// (``TranscriptTree`` and ``MergedTranscript``) shares, so the two
/// enumerations cannot drift. Discovery is shared here the same way line
/// decoding is shared in ``TranscriptLineDecoding``.
enum TranscriptFileDiscovery {
    /// Finds every file named `fileName` nested at any depth under
    /// `directory`.
    ///
    /// - Parameters:
    ///   - fileName: The file name to match.
    ///   - directory: The recording root to search.
    /// - Returns: The discovered file URLs, in no particular order.
    static func fileURLs(named fileName: String, under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
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
