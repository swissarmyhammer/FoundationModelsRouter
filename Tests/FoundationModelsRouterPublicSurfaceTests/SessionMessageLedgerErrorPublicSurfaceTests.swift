import Foundation
import FoundationModelsExtras
import Testing

import FoundationModelsRouter

/// Holds the error of a damaged `messages.jsonl` to the access level a host
/// outside this package needs (ROUTER-4): ``RouterSessionDirectory/inbox(of:markRead:)``
/// and ``RouterSessionDirectory/message(_:to:)`` read the ledger of a session,
/// and a line before the final one that does not decode throws
/// `SessionMessageLedgerError.corruptLine`.
///
/// The import is plain, with no `@testable`, so an error type that loses
/// `public` stops this file from compiling before a single test runs. The
/// body then catches the error the way a host does.
@Suite("Message ledger errors over a plain import")
struct SessionMessageLedgerErrorPublicSurfaceTests {
    /// The name of the ledger file in the folder of a recorded session.
    private static let ledgerFileName = "messages.jsonl"

    /// Two lines that do not decode: the first is before the final line, so
    /// it is damage and not a torn append.
    private static let damagedLines = "not json\nnot json either\n"

    /// A recording root with one recorded session whose `messages.jsonl` is
    /// damaged.
    private struct DamagedRecording {
        /// The recording root.
        let root: URL

        /// The id of the recorded session.
        let id: ULID

        /// The damaged `messages.jsonl` of the session.
        let ledgerFile: URL

        /// Writes a session folder under a new recording root, with a damaged
        /// `messages.jsonl` in it.
        ///
        /// - Throws: The error of a write of the folder or of the file.
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "SessionMessageLedgerErrorPublicSurfaceTests-\(UUID().uuidString)", isDirectory: true)
            id = ULID.generate()
            let folder = root.appendingPathComponent(id.description, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ledgerFile = folder.appendingPathComponent(SessionMessageLedgerErrorPublicSurfaceTests.ledgerFileName)
            try Data(SessionMessageLedgerErrorPublicSurfaceTests.damagedLines.utf8).write(to: ledgerFile)
        }

        /// Removes the recording root.
        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The router's directory over the recording root of `recording`.
    ///
    /// - Parameter recording: The damaged recording.
    /// - Returns: The directory.
    private static func directory(over recording: DamagedRecording) async -> RouterSessionDirectory {
        let directory = Router(pool: ModelPool()).sessionDirectory
        let root = recording.root
        await directory.useRecordingRoots { [root] }
        return directory
    }

    @Test("the inbox of a session with a damaged messages.jsonl throws corruptLine, which names the file")
    func theInboxOfADamagedLedgerThrowsCorruptLine() async throws {
        let recording = try DamagedRecording()
        defer { recording.remove() }
        let directory = await Self.directory(over: recording)

        let error = await #expect(throws: SessionMessageLedgerError.corruptLine(recording.ledgerFile)) {
            _ = try await directory.inbox(of: recording.id, markRead: false)
        }

        let thrown = try #require(error)
        #expect(thrown.description.contains(recording.ledgerFile.path))
    }

    @Test("a lookup in a session with a damaged messages.jsonl throws corruptLine")
    func aLookupInADamagedLedgerThrowsCorruptLine() async throws {
        let recording = try DamagedRecording()
        defer { recording.remove() }
        let directory = await Self.directory(over: recording)

        await #expect(throws: SessionMessageLedgerError.corruptLine(recording.ledgerFile)) {
            _ = try await directory.message(MailID(), to: recording.id)
        }
    }
}
