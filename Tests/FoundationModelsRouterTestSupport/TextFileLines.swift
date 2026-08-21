import Foundation

/// Reads a UTF-8 text file and splits it into lines.
///
/// The test suites read files in two shapes: a `transcript.jsonl` a test
/// wrote, and a file the repository carries, such as the CI workflow. Each
/// suite then compares the lines, or it decodes each line. The split is the
/// same in each case, so it stands here one time. A suite that splits the
/// text itself makes a second copy, and the copies drift apart.
///
/// This module is the home for such a helper. `swift test` builds one
/// `.xctest` for each test target, and SwiftPM cannot share source between
/// two test targets. ``RecordingRedactionScan`` and ``GatedWallClock`` stand
/// here for the same reason.
public enum TextFileLines {
    /// Reads the file at `url` as UTF-8 and returns its non-empty lines.
    ///
    /// A line ends at `\n`. The function drops each empty line, so the empty
    /// tail that a final newline leaves does not reach the caller. A JSONL
    /// reader can then decode each line with no guard, and a reader that
    /// compares trimmed lines with non-empty text loses nothing.
    ///
    /// - Parameter url: The file to read.
    /// - Returns: The non-empty lines, in file order.
    /// - Throws: The error `String(contentsOf:encoding:)` throws when the
    ///   file is not there or is not UTF-8.
    public static func read(from url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }
}
