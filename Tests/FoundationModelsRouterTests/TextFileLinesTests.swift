import Foundation
import FoundationModelsRouterTestSupport
import Testing

/// Holds ``TextFileLines`` to its contract: the non-empty lines of a UTF-8
/// file, in file order, and an error for a file that is not there.
@Suite("TextFileLines")
struct TextFileLinesTests {
    /// A fresh file path under the temporary directory. The file does not
    /// exist until a test writes it.
    private static func makeFilePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileLinesTests-\(UUID().uuidString).txt", isDirectory: false)
    }

    @Test("read(from:) returns each non-empty line in order and drops the empty lines")
    func readReturnsNonEmptyLinesInOrder() throws {
        let file = Self.makeFilePath()
        defer { try? FileManager.default.removeItem(at: file) }
        try "first\n\nsecond\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(try TextFileLines.read(from: file) == ["first", "second"])
    }

    @Test("read(from:) throws for a file that is not there")
    func readThrowsForMissingFile() {
        let missing = Self.makeFilePath()

        #expect(throws: (any Error).self) {
            try TextFileLines.read(from: missing)
        }
    }
}
