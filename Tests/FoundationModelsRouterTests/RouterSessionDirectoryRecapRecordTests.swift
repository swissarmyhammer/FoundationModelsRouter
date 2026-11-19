import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The last summary and the recap in the record of a session (D206): the
/// directory writes the last summary to the facts at the end of each turn
/// that changed it, and the live and the recorded summary give the last
/// summary, the recap and the time of the recap. A recorded session gives
/// them after a restart.
///
/// The recording router holds the live sessions, over a scripted backend
/// that answers each call at once. The reading router is a new router over
/// the same recordings folder, standing in for a new process.
@Suite("RouterSessionDirectory: the last summary and the recap in the record of a session")
struct RouterSessionDirectoryRecapRecordTests {
    /// The backend of each session of the recording router.
    private typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// The two routers of one test.
    struct Fixture {
        /// The two routers over one recordings folder.
        let pair: SessionDirectoryRouterPair

        /// The directory of the recording router, which holds its live
        /// sessions.
        var liveDirectory: RouterSessionDirectory { pair.recordingRouter.sessionDirectory }

        /// The directory of the reading router: the router after a restart.
        var readingDirectory: RouterSessionDirectory { pair.directory }

        /// Vends a live root session of the recording router, and gives both
        /// directories the recording root of the session.
        ///
        /// - Returns: The session.
        func makeLiveRoot() async -> any RoutedSession {
            let session = pair.recordingProfile.standard.makeSession(configuration: SessionConfiguration())
            let root = session.recordingDirectory.deletingLastPathComponent()
            await liveDirectory.useRecordingRoots { [root] }
            await readingDirectory.useRecordingRoots { [root] }
            return session
        }
    }

    // MARK: - Constants

    /// The prompt of each turn.
    private static let prompt = "run the job"

    /// The number of the first call of the scripted backend.
    private static let firstCall = 1

    /// The last summary that a test writes to the facts directly.
    private static let storedSummary = "The tests pass."

    /// The recap that a test writes.
    private static let recap = "Fixed the login test; the build is green."

    /// The user that archives and unarchives a session.
    private static let user = SessionMessageSender.user(clientID: "client-a")

    /// A part of a millisecond, which a record does not keep.
    private static let submillisecond: TimeInterval = 0.000_4

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// An instant inside a second, in milliseconds since 1970, as a record
    /// keeps it.
    private static let recapMilliseconds: Int64 = 1_763_540_000_456

    /// The instant of ``recap``.
    private static var recapAt: Date {
        DateTime(millisecondsSince1970: recapMilliseconds).date
    }

    // MARK: - Helpers

    /// Makes the two routers, with a scripted backend that answers each
    /// call at once for the recording router.
    ///
    /// - Returns: The fixture.
    private static func makeFixture() async throws -> Fixture {
        let pair = try await SessionDirectoryRouterPair.make(
            prefix: "RouterSessionDirectoryRecapRecordTests",
            recordingContainer: SessionMessagePumpTests.PumpProbeContainer(backend: Backend(script: [:])))
        return Fixture(pair: pair)
    }

    /// Runs one turn of `session` and waits until the directory sends its
    /// `stateChanged` to idle with the reply.
    ///
    /// - Parameters:
    ///   - session: A live session of `directory`.
    ///   - directory: The directory that holds the session.
    /// - Returns: The reply of the turn.
    /// - Throws: The refusal of the prompt.
    private static func runTurn(of session: any RoutedSession, in directory: RouterSessionDirectory) async throws
        -> String
    {
        let reply = Backend.answer(ofCall: firstCall)
        let idle = SessionDirectoryEvent.stateChanged(id: session.id, state: .idle, lastSummary: reply)
        var events = directory.events().makeAsyncIterator()
        _ = try session.send(prompt)
        // Rule T1 quiet state: a directory that never sends the idle state
        // hangs here, and the test never passes.
        while let event = await events.next(), event != idle {}
        return reply
    }

    /// The record that the `index.md` of `session` holds.
    ///
    /// - Parameter session: A durable session.
    /// - Returns: The record on disk.
    private static func recordOnDisk(of session: any RoutedSession) throws -> SessionRecord {
        try #require(try SessionIndexFile.read(in: session.recordingDirectory))
    }

    /// Writes ``recap`` and ``recapAt`` to the facts of the live `session`.
    ///
    /// - Parameter session: A live session.
    /// - Throws: The `#require` failure when the session is not a
    ///   ``RoutedSessionActor``.
    private static func storeRecap(in session: any RoutedSession) throws {
        let actor = try #require(session as? RoutedSessionActor)
        actor.updateFacts { facts in
            facts.recap = recap
            facts.recapAt = recapAt
        }
    }

    // MARK: - The last summary

    /// The production change that makes this test fail: a directory that
    /// keeps the last summary in memory only, as before D206.
    @Test("a turn writes its last summary to the record of the session")
    func aTurnWritesTheLastSummaryToTheRecord() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()

        let reply = try await Self.runTurn(of: session, in: fixture.liveDirectory)

        #expect(try Self.recordOnDisk(of: session).facts.lastSummary == reply)
        await session.close()
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a recorded summary
    /// that gives no last summary, as before D206.
    @Test("after a restart the recorded summary gives the last summary of the session")
    func aRestartGivesTheLastSummary() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        let reply = try await Self.runTurn(of: session, in: fixture.liveDirectory)
        await session.close()

        let recorded = try #require(try await fixture.readingDirectory.summary(of: session.id))

        #expect(recorded.lastSummary == reply)
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a live summary that
    /// reads the last summary from the tracking alone. A session that a
    /// restore made has no turn yet, and its record holds the last summary.
    @Test("a live session with no turn gives the last summary of its record")
    func aLiveSessionGivesTheLastSummaryOfItsRecord() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        let actor = try #require(session as? RoutedSessionActor)
        actor.updateFacts { $0.lastSummary = Self.storedSummary }

        let live = try #require(try await fixture.liveDirectory.summary(of: session.id))

        #expect(live.lastSummary == Self.storedSummary)
        await session.close()
        fixture.pair.remove()
    }

    // MARK: - The recap

    /// The production change that makes this test fail: a live summary that
    /// gives no recap.
    @Test("the live summary gives the recap of the facts")
    func theLiveSummaryGivesTheRecap() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        try Self.storeRecap(in: session)

        let live = try #require(try await fixture.liveDirectory.summary(of: session.id))

        #expect(live.recap == Self.recap)
        await session.close()
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a live summary that
    /// gives no time of the recap.
    @Test("the live summary gives the time of the recap of the facts")
    func theLiveSummaryGivesTheRecapTime() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        try Self.storeRecap(in: session)

        let live = try #require(try await fixture.liveDirectory.summary(of: session.id))

        #expect(live.recapAt == Self.recapAt)
        await session.close()
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a record that does
    /// not keep the recap, or a recorded summary that gives none.
    @Test("after a restart the recorded summary gives the recap and its time")
    func aRestartGivesTheRecap() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        try Self.storeRecap(in: session)
        await session.close()

        let recorded = try #require(try await fixture.readingDirectory.summary(of: session.id))

        #expect(recorded.recap == Self.recap)
        #expect(recorded.recapAt == Self.recapAt)
        fixture.pair.remove()
    }

    // MARK: - The recap write

    /// The recap of the summary of a `factsChanged`, or `nil` for another
    /// event.
    ///
    /// - Parameter event: A directory event.
    /// - Returns: The recap.
    private static func recap(in event: SessionDirectoryEvent?) -> String? {
        guard case .factsChanged(let summary) = event else { return nil }
        return summary.recap
    }

    /// The production change that makes this test fail: a recap write that
    /// leaves the `index.md` of a live session as it was.
    @Test("a recap write of a live session writes the recap and its time to the record")
    func aRecapWriteOfALiveSessionWritesTheRecord() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()

        try await fixture.liveDirectory.recordRecap(Self.recap, at: Self.recapAt, of: session.id)

        let facts = try Self.recordOnDisk(of: session).facts
        #expect(facts.recap == Self.recap)
        #expect(facts.recapAt == Self.recapAt)
        await session.close()
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a recap write that
    /// sends no event, or another event than `factsChanged` (the Extras port
    /// has no recap event).
    @Test("a recap write sends factsChanged with the new recap")
    func aRecapWriteSendsFactsChanged() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        try await fixture.liveDirectory.recordRecap(Self.recap, at: Self.recapAt, of: session.id)
        let received = await events.next(count: 1)

        #expect(Self.recap(in: received.first) == Self.recap)
        await session.close()
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a recap write that
    /// sends `factsChanged` also when the record holds the same recap.
    @Test("a recap write of the recap the record holds sends no event")
    func aSameRecapWriteSendsNoEvent() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        try await fixture.liveDirectory.recordRecap(Self.recap, at: Self.recapAt, of: session.id)
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        try await fixture.liveDirectory.recordRecap(Self.recap, at: Self.recapAt, of: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(count: 1)

        #expect(received == [Self.marker])
        await session.close()
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a recap time that
    /// the live session keeps with more precision than its record, so the
    /// live and the recorded summary give two times.
    @Test("a recap write keeps the time of the recap in milliseconds")
    func aRecapWriteKeepsMilliseconds() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()

        let summary = try await fixture.liveDirectory.recordRecap(
            Self.recap, at: Self.recapAt.addingTimeInterval(Self.submillisecond), of: session.id)

        #expect(summary.recapAt == Self.recapAt)
        await session.close()
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a recap write that
    /// reaches only a live session.
    @Test("a recap write of a recorded session that is not live writes its index.md")
    func aRecapWriteOfARecordedSessionWritesTheRecord() async throws {
        let fixture = try await Self.makeFixture()
        let recorded = await fixture.pair.recordClosedRoot()
        await fixture.pair.useRoot(of: recorded.recordingDirectory)

        try await fixture.readingDirectory.recordRecap(Self.recap, at: Self.recapAt, of: recorded.id)

        let record = try #require(try SessionIndexFile.read(in: recorded.recordingDirectory))
        #expect(record.facts.recap == Self.recap)
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: an archive that
    /// removes the recap from the record.
    @Test("an archive keeps the recap")
    func anArchiveKeepsTheRecap() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        try await fixture.liveDirectory.recordRecap(Self.recap, at: Self.recapAt, of: session.id)

        let archived = try await fixture.liveDirectory.archive(session.id, by: Self.user)

        #expect(archived.recap == Self.recap)
        await session.close()
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: an unarchive that
    /// removes the recap from the record.
    @Test("an unarchive keeps the recap")
    func anUnarchiveKeepsTheRecap() async throws {
        let fixture = try await Self.makeFixture()
        let session = await fixture.makeLiveRoot()
        try await fixture.liveDirectory.recordRecap(Self.recap, at: Self.recapAt, of: session.id)
        _ = try await fixture.liveDirectory.archive(session.id, by: Self.user)
        await session.close()

        let unarchived = try await fixture.readingDirectory.unarchive(session.id, by: Self.user)

        #expect(unarchived.recap == Self.recap)
        fixture.pair.remove()
    }
}
