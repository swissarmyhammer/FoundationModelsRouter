import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The ended marker of a session record: a host that owns a run calls
/// ``RouterSessionDirectory/markEnded(_:reason:)`` when the run reaches a
/// terminal state. The marker is `endedAt` and `endReason` in the `index.md`
/// of the session. It only informs: it does not close the session, it does
/// not stop work, and a close of the session never sets it.
///
/// The recording router holds the live sessions. The reading router is a new
/// router over the same recordings folder, standing in for a new process.
@Suite("RouterSessionDirectory: the ended marker of a session")
struct SessionEndedMarkerTests {
    /// The backend the held turn runs on.
    typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    // MARK: - Constants

    /// The prompt that starts the turn a test holds open.
    private static let turnPrompt = "first question"

    /// The number of the first call of the held backend.
    private static let firstCall = 1

    /// The tool-call id of the spawn of each recorded child.
    private static let spawnCallID = "call-1"

    /// The key of the end instant in the `index.md`.
    private static let endedAtKey = "endedAt"

    /// The key of the end reason in the `index.md`.
    private static let endReasonKey = "endReason"

    // MARK: - Helpers

    /// Makes the two routers over one new recordings folder.
    private static func makeFixture() async throws -> SessionDirectoryRouterPair {
        try await SessionDirectoryRouterPair.make(prefix: "SessionEndedMarkerTests")
    }

    /// The configuration of a recorded child of `parent`.
    private static func childConfiguration(of parent: ULID) -> SessionConfiguration {
        SessionConfiguration(
            agentSpawn: SessionRecord.AgentSpawn(parentSessionId: parent, parentToolCallId: spawnCallID))
    }

    /// The record that the `index.md` in `folder` holds.
    private static func record(in folder: URL) throws -> SessionRecord {
        try #require(try SessionIndexFile.read(in: folder))
    }

    // MARK: - Recorded session

    /// The production change that makes this test fail: a marker that is not
    /// written to the `index.md`, or is written without its reason.
    @Test("a mark on a recorded session is on disk and a new process reads it")
    func aMarkOnARecordedSessionIsDurable() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        await fixture.useRoot(of: recorded.recordingDirectory)

        let end = try await fixture.directory.markEnded(recorded.id, reason: .failed)

        let onDisk = try Self.record(in: recorded.recordingDirectory)
        #expect(onDisk.facts.endedAt == end.endedAt)
        #expect(onDisk.facts.endReason == .failed)
        #expect(try await fixture.directory.endMarker(of: recorded.id) == end)
    }

    /// The production change that makes this test fail: a second mark that
    /// changes the instant or the reason, or writes the `index.md` again.
    @Test("a second mark keeps the first reason and does not write the index.md")
    func aSecondMarkChangesNothing() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        await fixture.useRoot(of: recorded.recordingDirectory)
        let first = try await fixture.directory.markEnded(recorded.id, reason: .finished)
        let onDisk = try Self.record(in: recorded.recordingDirectory)

        let second = try await fixture.directory.markEnded(recorded.id, reason: .cancelled)

        #expect(second == first)
        #expect(try Self.record(in: recorded.recordingDirectory) == onDisk)
    }

    /// The production change that makes this test fail: a mark of an id that
    /// no session has that gives a marker or throws another error.
    @Test("a mark of an unknown id throws unknownSession")
    func aMarkOfAnUnknownIDThrows() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        await fixture.useRoot(of: recorded.recordingDirectory)
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await fixture.directory.markEnded(unknown, reason: .finished)
        }
    }

    // MARK: - Live session

    /// The production change that makes this test fail: a mark that writes
    /// the live facts only, or that closes the session.
    @Test("a mark on a live session is in its facts and its index.md, and the session stays live")
    func aMarkOnALiveSessionKeepsItLive() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.recordingProfile.standard.makeSession(configuration: SessionConfiguration())
        let directory = fixture.recordingRouter.sessionDirectory

        let end = try await directory.markEnded(session.id, reason: .finished)

        let live = try await directory.sessions(matching: SessionQuery())
        #expect(session.facts.endedAt == end.endedAt)
        #expect(session.facts.endReason == .finished)
        #expect(try Self.record(in: session.recordingDirectory).facts.endedAt == end.endedAt)
        #expect(live.map(\.id) == [session.id])
        await session.close()
    }

    /// The production change that makes this test fail: a close that marks
    /// the session as ended, so a session closed at the shutdown of the
    /// process, while its run works, is no longer restorable.
    @Test("an orderly close of a session with a working turn does not mark it")
    func anOrderlyCloseDoesNotMark() async throws {
        let latch = RunLatch()
        let backend = Backend(script: [Self.firstCall: .hold(latch)])
        let fixture = try await SessionDirectoryRouterPair.make(
            prefix: "SessionEndedMarkerTests",
            recordingContainer: SessionMessagePumpTests.PumpProbeContainer(backend: backend))
        defer { fixture.remove() }
        let session = fixture.recordingProfile.standard.makeSession(configuration: SessionConfiguration())
        _ = try session.send(Self.turnPrompt)
        try await backend.changes.wait(untilAtLeast: Self.firstCall) { backend.prompts.count }

        await session.close()
        await latch.open()

        let onDisk = try Self.record(in: session.recordingDirectory)
        #expect(onDisk.facts.endedAt == nil)
        #expect(onDisk.facts.endReason == nil)
    }

    // MARK: - Listing

    /// The production change that makes this test fail: a listing of the
    /// unended children that keeps an ended child, drops an unended one, or
    /// takes the children of another parent.
    @Test("the unended children of a parent leave out the ended children and the other children")
    func theUnendedChildrenLeaveOutTheEndedOnes() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let parent = ULID.generate()
        let ended = await fixture.recordClosedRoot(Self.childConfiguration(of: parent))
        let interrupted = await fixture.recordClosedRoot(Self.childConfiguration(of: parent))
        _ = await fixture.recordClosedRoot(Self.childConfiguration(of: ULID.generate()))
        await fixture.useRoot(of: ended.recordingDirectory)
        try await fixture.directory.markEnded(ended.id, reason: .finished)

        let children = try await fixture.directory.unendedChildren(of: parent)

        #expect(children.map(\.id) == [interrupted.id])
    }

    // MARK: - Old record

    /// The production change that makes this test fail: a record with no
    /// marker that reads as ended, or an `index.md` that writes empty marker
    /// keys.
    @Test("a record with no marker is not ended and its index.md has no marker key")
    func aRecordWithNoMarkerIsNotEnded() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        await fixture.useRoot(of: recorded.recordingDirectory)

        let text = try String(
            contentsOf: recorded.recordingDirectory.appendingPathComponent("index.md"), encoding: .utf8)

        #expect(try await fixture.directory.endMarker(of: recorded.id) == nil)
        #expect(!text.contains(Self.endedAtKey))
        #expect(!text.contains(Self.endReasonKey))
    }
}
