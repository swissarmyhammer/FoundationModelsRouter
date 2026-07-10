import Foundation
import Testing

@testable import FoundationModelsRouter

/// Tests for ``openHandleForAppending(fileName:in:)``, the on-disk append
/// lifecycle shared by every JSONL sink in this module (``JSONLRecorder``,
/// ``SessionIndexWriter``).
///
/// Both current call sites pass hardcoded literals, so these aren't
/// regression tests for an exploited path — they're a hardening guarantee
/// that the shared helper itself refuses to become a directory-escape
/// primitive if a future caller ever threads an untrusted `fileName` through.
@Suite("JSONLAppend")
struct JSONLAppendTests {
    /// A fresh, empty temporary directory, removed after the test.
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test(
        "rejects a fileName that escapes the directory via a path separator and \"..\"",
        arguments: [
            "../evil.jsonl",
            "../../etc/passwd",
            "sub/transcript.jsonl",
            "/etc/passwd",
        ]
    )
    func rejectsPathTraversal(fileName: String) throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: JSONLAppendError.invalidFileName(fileName)) {
            _ = try openHandleForAppending(fileName: fileName, in: dir)
        }

        // Nothing was created outside (or even inside) the intended directory.
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test(
        "rejects bare navigation tokens as a fileName",
        arguments: ["..", "."]
    )
    func rejectsNavigationTokens(fileName: String) throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: JSONLAppendError.invalidFileName(fileName)) {
            _ = try openHandleForAppending(fileName: fileName, in: dir)
        }
    }

    @Test("rejects an empty fileName")
    func rejectsEmptyFileName() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: JSONLAppendError.invalidFileName("")) {
            _ = try openHandleForAppending(fileName: "", in: dir)
        }
    }

    @Test("opens and creates a handle for a plain single-component fileName")
    func acceptsPlainFileName() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let handle = try openHandleForAppending(fileName: "transcript.jsonl", in: dir)
        defer { try? handle.close() }

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.jsonl").path))
    }
}
