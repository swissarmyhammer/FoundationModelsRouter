import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// A host reads the first prompt of a recorded session without a restore.
/// ``RecordedChild/firstPrompt`` holds it for a recorded child, and
/// ``RouterSessionDirectory/firstPrompt(of:)`` gives it for any recorded
/// session. The read only reads the `transcript.jsonl` files, and it stops at
/// the first `.prompt` event.
///
/// The recordings are real: a session of a recording router answers, and a
/// reading router over the same recordings folder stands in for the new
/// process.
@Suite("RouterSessionDirectory: the first prompt of a recorded session without a restore")
struct RecordedChildFirstPromptTests {
    // MARK: - Constants

    /// The prefix of the temporary folders of each test.
    private static let folderPrefix = "RecordedChildFirstPromptTests"

    /// A prompt with edges that a careless read changes: outer space, line
    /// breaks, a tab, and text outside ASCII.
    private static let edgePrompt = "  first line\r\n\tsecond line \u{00E9}\u{65E5}\u{672C}  \n"

    /// The prompt of the second submission of a session.
    private static let laterPrompt = "the later prompt"

    /// The prompt that follows run mail in the first submission.
    private static let bodyPrompt = "the prompt body"

    /// The agent name of the child of a test.
    private static let agentName = "reader"

    /// The folder agent id of the child of a test.
    private static let agentID = "folder:/Users/dev/example/agents/child"

    /// The name of the tool of the run mail.
    private static let toolName = "agents"

    /// The detail of the run event that is delivered as run mail.
    private static let runDetail = "run mail detail"

    /// The bytes of a line that no transcript decoder reads, with its end.
    private static let corruptLine = Data("{\"this is not an event\n".utf8)

    /// The bytes of a torn final line: no end of line.
    private static let tornTail = Data("{\"kind\":\"prom".utf8)

    // MARK: - Fixture

    /// A recorded child of a recorded parent.
    private struct Recorded {
        /// The two routers over one recordings folder.
        let pair: SessionDirectoryRouterPair

        /// The id of the parent session.
        let parentID: ULID

        /// The id of the child session.
        let childID: ULID

        /// The recording folder of the child.
        let childFolder: URL
    }

    /// The configuration of a child of `parent`.
    private static func configuration(of parent: ULID, recordingRoot: URL? = nil) -> SessionConfiguration {
        SessionConfiguration(
            recordingRoot: recordingRoot,
            agentSpawn: SessionRecord.AgentSpawn(
                parentSessionId: parent, parentToolCallId: ToolContext.makeCompletionToken()),
            agentID: agentID,
            agentName: agentName)
    }

    /// Records a child of a recorded parent, runs `work` on the open child,
    /// closes it, and runs `body` with the recording. The folders go after,
    /// also when `body` throws.
    ///
    /// - Parameters:
    ///   - nested: `true` to put the folder of the child inside the folder of
    ///     the parent.
    ///   - work: What the child does before it closes.
    ///   - body: The check.
    private static func withRecordedChild(
        nested: Bool = false,
        work: (any RoutedSession) async throws -> Void,
        _ body: (Recorded) async throws -> Void
    ) async throws {
        let pair = try await SessionDirectoryRouterPair.make(prefix: folderPrefix)
        defer { pair.remove() }
        let parent = await pair.recordClosedRoot()
        let child = pair.recordingProfile.standard.makeSession(
            configuration: configuration(of: parent.id, recordingRoot: nested ? parent.recordingDirectory : nil))
        do {
            try await work(child)
        } catch {
            await child.close()
            throw error
        }
        await child.close()
        await pair.useRoot(of: parent.recordingDirectory)
        try await body(
            Recorded(
                pair: pair, parentID: parent.id, childID: child.id, childFolder: child.recordingDirectory))
    }

    /// The recorded child of `recorded`.
    private static func child(of recorded: Recorded) async throws -> RecordedChild {
        let children = try await recorded.pair.directory.recordedChildren(of: recorded.parentID)
        return try #require(children.first { $0.sessionID == recorded.childID })
    }

    /// The bytes of each file under `folder`, by path.
    private static func snapshot(of folder: URL) throws -> [String: Data] {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var bytes: [String: Data] = [:]
        for case let url as URL in files {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            bytes[url.path] = try Data(contentsOf: url)
        }
        return bytes
    }

    /// Appends `bytes` to the end of the transcript in `folder`.
    private static func appendToTranscript(_ bytes: Data, in folder: URL) throws {
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent(transcriptFileName))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    // MARK: - The prompt

    /// The production change that makes this test fail: a child that shows
    /// no prompt, or a text that the read changes.
    @Test("a recorded child shows its first prompt byte for byte")
    func aChildShowsItsFirstPrompt() async throws {
        try await Self.withRecordedChild(work: { child in
            _ = try await child.respond(to: Self.edgePrompt)
            _ = try await child.respond(to: Self.laterPrompt)
        }) { recorded in
            let child = try await Self.child(of: recorded)

            #expect(child.firstPrompt == Self.edgePrompt)
        }
    }

    /// The production change that makes this test fail: a directory read that
    /// is not the same read as the one of the child.
    @Test("the directory gives the first prompt of a recorded session byte for byte")
    func theDirectoryGivesTheFirstPrompt() async throws {
        try await Self.withRecordedChild(work: { child in
            _ = try await child.respond(to: Self.edgePrompt)
            _ = try await child.respond(to: Self.laterPrompt)
        }) { recorded in
            let prompt = try await recorded.pair.directory.firstPrompt(of: recorded.childID)

            #expect(prompt == Self.edgePrompt)
        }
    }

    /// The production change that makes this test fail: a read that takes a
    /// prompt of a session that has none, or invents an empty text.
    @Test("a child that has no prompt shows nil")
    func aChildWithNoPromptShowsNil() async throws {
        try await Self.withRecordedChild(work: { _ in }) { recorded in
            let child = try await Self.child(of: recorded)

            #expect(child.firstPrompt == nil)
            #expect(try await recorded.pair.directory.firstPrompt(of: recorded.childID) == nil)
        }
    }

    /// The production change that makes this test fail: a prompt text that
    /// holds the render of the run mail that the submission delivered.
    @Test("the first prompt holds the prompt body and not the run mail that came with it")
    func theRunMailIsNotInTheFirstPrompt() async throws {
        try await Self.withRecordedChild(work: { child in
            await child.outbox.post(
                event: OperationEvent(
                    tool: Self.toolName, op: "start agent", correlationID: ToolContext.makeCompletionToken(),
                    kind: .completed, detail: Self.runDetail, outcome: .succeeded))
            _ = try await child.respond(to: Self.bodyPrompt)
        }) { recorded in
            let child = try await Self.child(of: recorded)

            #expect(child.firstPrompt == Self.bodyPrompt)
        }
    }

    /// The production change that makes this test fail: a child in a folder
    /// inside the folder of its parent that fails the read as a fork with no
    /// cut.
    @Test("a child whose folder sits inside the folder of its parent shows its first prompt")
    func aNestedChildShowsItsFirstPrompt() async throws {
        try await Self.withRecordedChild(
            nested: true,
            work: { child in _ = try await child.respond(to: Self.bodyPrompt) }
        ) { recorded in
            let child = try await Self.child(of: recorded)

            #expect(child.firstPrompt == Self.bodyPrompt)
        }
    }

    // MARK: - Forks

    /// The production change that makes this test fail: a fork that reads
    /// its own events only, so its first prompt is a later one or none.
    @Test("a fork shows the first prompt of its parent up to the cut")
    func aForkShowsTheFirstPromptOfItsParent() async throws {
        try await Self.withRecordedChild(work: { child in
            _ = try await child.respond(to: Self.bodyPrompt)
        }) { recorded in
            let root = recorded.childFolder.deletingLastPathComponent()
            let cut = try RecordedForkFixtures.cut(atEndOf: recorded.childID, under: root)
            let forkID = ULID.generate()
            try RecordedForkFixtures.writeFork(id: forkID, under: recorded.childFolder, cut: cut)

            let prompt = try await recorded.pair.directory.firstPrompt(of: forkID)

            #expect(prompt == Self.bodyPrompt)
        }
    }

    // MARK: - No side effect and the stop

    /// The production change that makes this test fail: a read that writes a
    /// file, or changes one.
    @Test("a first prompt read leaves every byte of the recordings as it was")
    func theReadHasNoSideEffect() async throws {
        try await Self.withRecordedChild(work: { child in
            _ = try await child.respond(to: Self.bodyPrompt)
        }) { recorded in
            let root = recorded.childFolder.deletingLastPathComponent()
            let before = try Self.snapshot(of: root)

            _ = try await recorded.pair.directory.recordedChildren(of: recorded.parentID)
            _ = try await recorded.pair.directory.firstPrompt(of: recorded.childID)

            #expect(try Self.snapshot(of: root) == before)
        }
    }

    /// The production change that makes this test fail: a read that does not
    /// stop at the first prompt and fails on, or takes, what comes after it.
    @Test("a line after the first prompt does not change the first prompt")
    func aLaterCorruptLineDoesNotMatter() async throws {
        try await Self.withRecordedChild(work: { child in
            _ = try await child.respond(to: Self.bodyPrompt)
        }) { recorded in
            try Self.appendToTranscript(Self.corruptLine + Self.tornTail, in: recorded.childFolder)

            let prompt = try await recorded.pair.directory.firstPrompt(of: recorded.childID)

            #expect(prompt == Self.bodyPrompt)
        }
    }

    // MARK: - Errors

    /// The production change that makes this test fail: an unknown id that
    /// gives nil instead of the error.
    @Test("a read of an unknown session throws unknownSession")
    func anUnknownSessionThrows() async throws {
        try await Self.withRecordedChild(work: { _ in }) { recorded in
            let unknown = ULID.generate()

            await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
                try await recorded.pair.directory.firstPrompt(of: unknown)
            }
        }
    }

    /// The production change that makes this test fail: a transcript that
    /// does not read and gives nil, or an untyped error.
    @Test("a transcript that does not read throws readFailed")
    func anUnreadableTranscriptThrowsTyped() async throws {
        try await Self.withRecordedChild(work: { child in
            _ = try await child.respond(to: Self.bodyPrompt)
        }) { recorded in
            let transcript = recorded.childFolder.appendingPathComponent(transcriptFileName)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: transcript.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript.path)
            }

            await #expect {
                try await recorded.pair.directory.firstPrompt(of: recorded.childID)
            } throws: { error in
                guard case JSONLFileError.readFailed = error else { return false }
                return true
            }
        }
    }

    /// The production change that makes this test fail: a damaged record of
    /// the session that gives an untyped error, or no error.
    @Test("a damaged index of the session throws indexUnreadable")
    func aDamagedIndexThrowsTyped() async throws {
        try await Self.withRecordedChild(work: { child in
            _ = try await child.respond(to: Self.bodyPrompt)
        }) { recorded in
            try Data("this is not a session record".utf8).write(
                to: recorded.childFolder.appendingPathComponent(SessionIndexFile.fileName))

            await #expect {
                try await recorded.pair.directory.firstPrompt(of: recorded.childID)
            } throws: { error in
                guard case TranscriptTreeError.indexUnreadable(let directory) = error else { return false }
                return directory.lastPathComponent == recorded.childID.description
            }
        }
    }
}
