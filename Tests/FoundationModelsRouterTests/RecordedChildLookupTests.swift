import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// A host finds the sub-agent sessions to restore after a crash, and the
/// runs that the crash interrupted, without a restore.
/// ``RouterSessionDirectory/recordedChildren(of:)`` lists the recorded
/// children of a session, and ``RouterSessionDirectory/runStatuses(of:)``
/// gives the status of each journaled run of a session. Both only read.
///
/// The recording is real: a parent session with the `agents` tool of
/// ``AgentOperationFixtures`` starts two background runs, and a crash leaves
/// the parent open on disk. The reading router is a new router over the same
/// recordings folder, standing in for the new process.
///
/// The suite also holds the three facts of the design of the card: the tool
/// name in the journal, the restore of a spawn child as a root, and the
/// equality of the orphan `correlationID` with the `parentToolCallId`.
@Suite("RouterSessionDirectory: recorded children and run statuses without a restore")
struct RecordedChildLookupTests {
    // MARK: - Constants

    /// The prefix of the temporary folders of each test.
    private static let folderPrefix = "RecordedChildLookupTests"

    /// The name of the `agents` tool as the journal must record it.
    private static let agentsToolName = "agents"

    /// The prompt of the first submission of the parent.
    private static let startPrompt = "start two agents"

    /// The prompt of the second submission of the parent, which drains the
    /// staged events into the journal.
    private static let deliveryPrompt = "deliver the staged events"

    /// The detail of the terminal that finishes a run.
    private static let finishedDetail = "agent finished"

    /// The name of the agent of the run that finished.
    private static let finishedAgent = "finisher"

    /// The name of the agent of the run that a crash interrupted.
    private static let interruptedAgent = "interrupter"

    /// The name of the agent that wrote no journal event.
    private static let silentAgent = "sleeper"

    /// The name of the agent whose run finished and that was not marked as
    /// ended.
    private static let unmarkedAgent = "unmarked"

    /// The folder agent id of each child.
    private static let childAgentID = "folder:/Users/dev/example/agents/child"

    // MARK: - Fixture

    /// A recorded child and the token it was spawned with.
    private struct Child {
        /// The session id of the child.
        let id: ULID

        /// The completion token of the run that spawned the child.
        let token: String
    }

    /// The recording of a parent session that crashed with children on disk.
    private struct Recording {
        /// The two routers over one recordings folder.
        let pair: SessionDirectoryRouterPair

        /// The parent session. It stays open, as the session of a crashed
        /// process does.
        let parent: any RoutedSession

        /// The child whose run finished, and that the host marked as ended.
        let finished: Child

        /// The child whose run finished, and that the host did not mark.
        let unmarked: Child

        /// The child whose run a crash interrupted.
        let interrupted: Child

        /// The child that wrote no journal event in the parent.
        let silent: Child

        /// A child of another parent.
        let stranger: Child

        /// The marker that the host wrote for ``finished``.
        let finishedMarker: SessionEndedMarker

        /// The recording root, which the reading router uses.
        var root: URL { parent.recordingDirectory.deletingLastPathComponent() }
    }

    /// The configuration of a recorded child.
    private static func childConfiguration(
        of parent: ULID, token: String, agentName: String, recordingRoot: URL? = nil
    ) -> SessionConfiguration {
        SessionConfiguration(
            recordingRoot: recordingRoot,
            agentSpawn: SessionRecord.AgentSpawn(parentSessionId: parent, parentToolCallId: token),
            agentID: childAgentID,
            agentName: agentName)
    }

    /// Records a child of `parent` and closes it, so it is on disk and live
    /// nowhere.
    private static func recordChild(
        in pair: SessionDirectoryRouterPair, of parent: ULID, token: String, agentName: String,
        recordingRoot: URL? = nil
    ) async -> Child {
        let session = pair.recordingProfile.standard.makeSession(
            configuration: childConfiguration(
                of: parent, token: token, agentName: agentName, recordingRoot: recordingRoot))
        await session.close()
        return Child(id: session.id, token: token)
    }

    /// The terminal event of a run that finished.
    private static func finishedTerminal(token: String) -> OperationEvent {
        OperationEvent(
            tool: agentsToolName, op: "start agent", correlationID: token, kind: .completed,
            detail: finishedDetail, outcome: .succeeded)
    }

    /// Makes the recording and runs `body` with it. The parent closes and
    /// the folders go after, also when `body` throws.
    private static func withRecording(_ body: (Recording) async throws -> Void) async throws {
        let startGate = RunLatch()
        let startCalls = [finishedAgent, interruptedAgent].map { name in
            ScriptedMountCall(
                toolName: AgentOperationFixtures.toolName,
                argumentsJSON: AgentOperationFixtures.arguments(op: "start agent", name: name))
        }
        let container = MountCallingLLMContainer(calls: startCalls)
        let pair = try await SessionDirectoryRouterPair.make(prefix: folderPrefix, recordingContainer: container)
        let tool = try AgentOperationFixtures.makeTool(startGate: startGate)
        let parent = pair.recordingProfile.standard.makeSession(
            configuration: SessionConfiguration(tools: [tool], inlineSettleGrace: 0))
        defer {
            await SessionFixtureLifecycle.close(parent, opening: [startGate])
            pair.remove()
        }
        let backend = try #require(container.lastBackend)
        _ = try await parent.respond(to: startPrompt)
        let tokens = try backend.toolOutputs.map { try MountFixtures.decodeEnvelope($0).completionToken }
        let (finishedToken, interruptedToken) = try (#require(tokens.first), #require(tokens.last))
        let unmarkedToken = ToolContext.makeCompletionToken()
        await parent.outbox.post(event: finishedTerminal(token: finishedToken))
        await parent.outbox.post(event: finishedTerminal(token: unmarkedToken))
        _ = try await parent.respond(to: deliveryPrompt)

        let finished = await recordChild(
            in: pair, of: parent.id, token: finishedToken, agentName: finishedAgent)
        let unmarked = await recordChild(
            in: pair, of: parent.id, token: unmarkedToken, agentName: unmarkedAgent)
        let interrupted = await recordChild(
            in: pair, of: parent.id, token: interruptedToken, agentName: interruptedAgent)
        let silent = await recordChild(
            in: pair, of: parent.id, token: ToolContext.makeCompletionToken(), agentName: silentAgent)
        let stranger = await recordChild(
            in: pair, of: ULID.generate(), token: ToolContext.makeCompletionToken(), agentName: silentAgent)
        await pair.useRoot(of: parent.recordingDirectory)
        let marker = try await pair.directory.markEnded(finished.id, reason: .finished)

        try await body(
            Recording(
                pair: pair, parent: parent, finished: finished, unmarked: unmarked, interrupted: interrupted,
                silent: silent, stranger: stranger, finishedMarker: marker))
    }

    /// The bytes of each file under `folder`, by relative path.
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

    // MARK: - Listing

    /// The production change that makes this test fail: a listing that
    /// leaves out a recorded child, or takes a child of another parent.
    @Test("the recorded children of a parent are its four spawn children and no other")
    func theListingHoldsTheChildrenOfTheParent() async throws {
        try await Self.withRecording { recording in
            let children = try await recording.pair.directory.recordedChildren(of: recording.parent.id)

            let expected = [recording.finished, recording.unmarked, recording.interrupted, recording.silent]
            #expect(Set(children.map(\.sessionID)) == Set(expected.map(\.id)))
        }
    }

    /// The production change that makes this test fail: a child that shows
    /// a wrong identity, a wrong parent or a wrong spawn token.
    @Test("a recorded child shows its identity, its parent and its parent tool call id")
    func aRecordedChildShowsItsFields() async throws {
        try await Self.withRecording { recording in
            let children = try await recording.pair.directory.recordedChildren(of: recording.parent.id)

            let child = try #require(children.first { $0.sessionID == recording.interrupted.id })
            #expect(
                child
                    == RecordedChild(
                        sessionID: recording.interrupted.id, agentID: Self.childAgentID,
                        agentName: Self.interruptedAgent, parentSessionId: recording.parent.id,
                        parentToolCallId: recording.interrupted.token, ended: nil, firstPrompt: nil))
        }
    }

    /// The production change that makes this test fail: a listing that does
    /// not show the ended marker, or shows one for a child that has none.
    @Test("the listing shows the ended marker of an ended child and none for the others")
    func theListingShowsTheEndedMarker() async throws {
        try await Self.withRecording { recording in
            let children = try await recording.pair.directory.recordedChildren(of: recording.parent.id)

            let ended = children.filter { $0.ended != nil }
            #expect(ended.map(\.sessionID) == [recording.finished.id])
            #expect(ended.first?.ended == recording.finishedMarker)
        }
    }

    /// The production change that makes this test fail: a listing that reads
    /// only the folders directly under the recording root, as the recorded
    /// session listing does.
    @Test("a child whose folder sits inside the folder of its parent is listed")
    func aNestedChildIsListed() async throws {
        let fixture = try await SessionDirectoryRouterPair.make(prefix: Self.folderPrefix)
        defer { fixture.remove() }
        let parent = await fixture.recordClosedRoot()
        let nested = await Self.recordChild(
            in: fixture, of: parent.id, token: ToolContext.makeCompletionToken(), agentName: Self.silentAgent,
            recordingRoot: parent.recordingDirectory)
        await fixture.useRoot(of: parent.recordingDirectory)

        let children = try await fixture.directory.recordedChildren(of: parent.id)

        #expect(children.map(\.sessionID) == [nested.id])
    }

    // MARK: - Run statuses

    /// The production change that makes this test fail: a status map that
    /// leaves out a finished run, or an interrupted run.
    @Test("the run statuses hold a finished run as completed and an interrupted run as orphaned")
    func theRunStatusesHoldFinishedAndInterruptedRuns() async throws {
        try await Self.withRecording { recording in
            let statuses = try await recording.pair.directory.runStatuses(of: recording.parent.id)

            let finishedKey = RunKey(tool: Self.agentsToolName, correlationID: recording.finished.token)
            let interruptedKey = RunKey(tool: Self.agentsToolName, correlationID: recording.interrupted.token)
            #expect(statuses[finishedKey] == .completed(.succeeded))
            #expect(statuses[interruptedKey] == .orphaned)
        }
    }

    /// The production change that makes this test fail: a status map that
    /// invents a run for a child that wrote no journal event.
    @Test("a child that wrote no journal event is listed and has no run status")
    func aSilentChildHasNoRunStatus() async throws {
        try await Self.withRecording { recording in
            let children = try await recording.pair.directory.recordedChildren(of: recording.parent.id)
            let statuses = try await recording.pair.directory.runStatuses(of: recording.parent.id)

            let silent = try #require(children.first { $0.sessionID == recording.silent.id })
            let silentKey = RunKey(tool: Self.agentsToolName, correlationID: silent.parentToolCallId)
            #expect(statuses[silentKey] == nil)
        }
    }

    /// The production change that makes this test fail: a scan that gives
    /// another orphan set than the restore marks as lost.
    @Test("the orphan set of the run statuses equals the set that the restore marks as lost")
    func theOrphanSetEqualsTheRestoreLostSet() async throws {
        try await Self.withRecording { recording in
            let statuses = try await recording.pair.directory.runStatuses(of: recording.parent.id)
            let orphans = Set(statuses.filter { $0.value == .orphaned }.keys)

            let tree = try await recording.pair.readingProfile.standard.restoreSessionTree(
                root: recording.parent.id, recordingRoot: recording.root)
            defer { await SessionFixtureLifecycle.close(tree) }
            let lost = await tree.root.outbox.pending().events.map(\.event).filter { $0.outcome == .lost }

            #expect(orphans == Set(lost.map { RunKey(tool: $0.tool, correlationID: $0.correlationID) }))
            #expect(!orphans.isEmpty)
        }
    }

    /// The production change that makes this test fail: a read that writes a
    /// file, or changes one.
    @Test("a listing and a status read leave every byte of the recordings as it was")
    func aReadHasNoSideEffect() async throws {
        try await Self.withRecording { recording in
            let before = try Self.snapshot(of: recording.root)

            _ = try await recording.pair.directory.recordedChildren(of: recording.parent.id)
            _ = try await recording.pair.directory.runStatuses(of: recording.parent.id)

            #expect(try Self.snapshot(of: recording.root) == before)
        }
    }

    /// The production change that makes this test fail: a status read of an
    /// unknown id that gives an empty map instead of the error.
    @Test("a status read of an unknown session throws unknownSession")
    func aStatusReadOfAnUnknownSessionThrows() async throws {
        try await Self.withRecording { recording in
            let unknown = ULID.generate()

            await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
                try await recording.pair.directory.runStatuses(of: unknown)
            }
        }
    }

    // MARK: - Scope of the status read

    /// The bytes that no `index.md` decoder reads.
    private static let corruptIndexBytes = Data("this is not a session record".utf8)

    /// Damages the `index.md` in `folder`.
    private static func corruptIndex(in folder: URL) throws {
        try corruptIndexBytes.write(to: folder.appendingPathComponent(SessionIndexFile.fileName))
    }

    /// Whether `error` is ``TranscriptTreeError/indexUnreadable(directory:)``
    /// for the folder of the session `id`. The folder is compared by name,
    /// because the tree gives the canonical path of the folder.
    private static func isIndexUnreadable(_ error: any Error, named id: ULID) -> Bool {
        guard case TranscriptTreeError.indexUnreadable(let directory) = error else { return false }
        return directory.lastPathComponent == id.description
    }

    /// Writes a fork of the parent of `recording` that is cut at the end of
    /// the recorded history of the parent.
    private static func writeFork(of recording: Recording) throws -> (id: ULID, folder: URL) {
        let cut = try RecordedForkFixtures.cut(atEndOf: recording.parent.id, under: recording.root)
        let id = ULID.generate()
        let folder = try RecordedForkFixtures.writeFork(id: id, under: recording.parent.recordingDirectory, cut: cut)
        return (id, folder)
    }

    /// The production change that makes this test fail: a status read that
    /// loads the whole recording root, so a damaged session beside the
    /// session fails the read.
    @Test("a damaged session beside the session does not fail the run statuses")
    func aDamagedSiblingDoesNotFailTheStatusRead() async throws {
        try await Self.withRecording { recording in
            let sibling = await recording.pair.recordClosedRoot()
            try Self.corruptIndex(in: sibling.recordingDirectory)

            let statuses = try await recording.pair.directory.runStatuses(of: recording.parent.id)

            let interruptedKey = RunKey(tool: Self.agentsToolName, correlationID: recording.interrupted.token)
            #expect(statuses[interruptedKey] == .orphaned)
        }
    }

    /// The production change that makes this test fail: a status read of a
    /// fork that loads the forks beside it, not only its chain of parents.
    @Test("a damaged fork beside a fork does not fail the run statuses of the fork")
    func aDamagedSiblingForkDoesNotFailTheStatusRead() async throws {
        try await Self.withRecording { recording in
            let fork = try Self.writeFork(of: recording)
            let damaged = try Self.writeFork(of: recording)
            try Self.corruptIndex(in: damaged.folder)

            let statuses = try await recording.pair.directory.runStatuses(of: fork.id)

            let parentStatuses = try await recording.pair.directory.runStatuses(of: recording.parent.id)
            #expect(statuses == parentStatuses)
        }
    }

    /// The production change that makes this test fail: a status read of a
    /// fork that does not read the effective events of its parents.
    @Test("the run statuses of a fork hold the runs of its parent up to the cut")
    func aForkHoldsTheRunsOfItsParent() async throws {
        try await Self.withRecording { recording in
            let fork = try Self.writeFork(of: recording)

            let statuses = try await recording.pair.directory.runStatuses(of: fork.id)

            let interruptedKey = RunKey(tool: Self.agentsToolName, correlationID: recording.interrupted.token)
            #expect(statuses[interruptedKey] == .orphaned)
        }
    }

    /// The production change that makes this test fail: a damaged record of
    /// the session itself that gives an untyped error, or no error.
    @Test("a damaged index of the session throws indexUnreadable")
    func aDamagedIndexOfTheSessionThrowsTyped() async throws {
        try await Self.withRecording { recording in
            let sibling = await recording.pair.recordClosedRoot()
            try Self.corruptIndex(in: sibling.recordingDirectory)

            await #expect {
                try await recording.pair.directory.runStatuses(of: sibling.id)
            } throws: { error in
                Self.isIndexUnreadable(error, named: sibling.id)
            }
        }
    }

    /// The production change that makes this test fail: a damaged record of
    /// a parent of the fork that is not reported as the typed error.
    @Test("a damaged index of a parent of a fork throws indexUnreadable")
    func aDamagedParentIndexThrowsTyped() async throws {
        try await Self.withRecording { recording in
            let fork = try Self.writeFork(of: recording)
            try Self.corruptIndex(in: recording.parent.recordingDirectory)

            await #expect {
                try await recording.pair.directory.runStatuses(of: fork.id)
            } throws: { error in
                Self.isIndexUnreadable(error, named: recording.parent.id)
            }
        }
    }

    // MARK: - Host rule

    /// The production change that makes this test fail: a listing or a map
    /// that cannot tell a child that finished but was not marked from a child
    /// that a crash interrupted.
    @Test("a child that is unended and whose run is not completed is a child to restore")
    func theHostRuleKeepsTheInterruptedAndTheSilentChild() async throws {
        try await Self.withRecording { recording in
            let directory = recording.pair.directory
            let children = try await directory.recordedChildren(of: recording.parent.id)
            let statuses = try await directory.runStatuses(of: recording.parent.id)

            let toRestore = children.filter { child in
                let key = RunKey(tool: Self.agentsToolName, correlationID: child.parentToolCallId)
                return child.ended == nil && statuses[key] != .completed(.succeeded)
            }

            #expect(Set(toRestore.map(\.sessionID)) == [recording.interrupted.id, recording.silent.id])
        }
    }

    // MARK: - The three facts

    /// Fact (a). The production change that makes this test fail: an `agents`
    /// tool whose runs the journal records under another tool name.
    @Test("the journal records the runs of the agents tool under the name agents")
    func theJournalRecordsTheAgentsToolName() async throws {
        try await Self.withRecording { recording in
            let statuses = try await recording.pair.directory.runStatuses(of: recording.parent.id)

            #expect(Set(statuses.keys.map(\.tool)) == [Self.agentsToolName])
        }
    }

    /// Fact (b). The production change that makes this test fail: a restore
    /// that refuses a spawn child as a root.
    @Test("a spawn child restores as a root with restoreSession")
    func aSpawnChildRestoresAsARoot() async throws {
        try await Self.withRecording { recording in
            let restored = try await recording.pair.readingProfile.standard.restoreSession(
                id: recording.interrupted.id, recordingRoot: recording.root)
            defer { await SessionFixtureLifecycle.close([restored.session]) }

            #expect(restored.session.id == recording.interrupted.id)
        }
    }

    /// Fact (c). The production change that makes this test fail: an orphan
    /// whose `correlationID` is not the token that the child records as its
    /// `parentToolCallId`.
    @Test("the orphan correlationID equals the parent tool call id of the interrupted child")
    func theOrphanCorrelationIDEqualsTheParentToolCallID() async throws {
        try await Self.withRecording { recording in
            let children = try await recording.pair.directory.recordedChildren(of: recording.parent.id)
            let statuses = try await recording.pair.directory.runStatuses(of: recording.parent.id)

            let interrupted = try #require(children.first { $0.sessionID == recording.interrupted.id })
            let orphans = statuses.filter { $0.value == .orphaned }.keys
            #expect(orphans.map(\.correlationID) == [interrupted.parentToolCallId])
        }
    }
}
