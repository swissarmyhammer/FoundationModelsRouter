import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The pin and the last use of ``RouterSessionDirectory`` (ROUTER-3, D186):
/// `use(usageStore:)` gives the directory a ``SessionUsageStore``.
/// `setPinned` and `markUsed` write the store and send one `factsChanged`.
/// Each summary gets `pinnedAt` and `lastUsedAt` from the store, and
/// `sessions(matching:)` filters by the pin and orders by the pin or by the
/// last use. The recording roots of the store join the recording roots of the
/// host, so a new router with the same store finds a recorded session.
///
/// Router A records the sessions; router B is a new router over the same
/// recordings folder, standing in for a new process. Each test removes its
/// folders in a `defer`.
@Suite struct RouterSessionDirectoryUsageTests {
    /// The two routers of one test, the directory of each, and the file of
    /// the usage store.
    struct Fixture {
        /// The two routers over one recordings folder.
        let pair: SessionDirectoryRouterPair

        /// The file of the usage store, in the cache folder of the test.
        var storeFile: URL {
            pair.directories.cacheDir
                .appendingPathComponent("usage", isDirectory: true)
                .appendingPathComponent("sessions.json", isDirectory: false)
        }

        /// The directory of the recording router, which holds its live
        /// sessions.
        var liveDirectory: RouterSessionDirectory { pair.recordingRouter.sessionDirectory }

        /// The directory of the reading router, which finds the sessions that
        /// the recording router recorded.
        var readingDirectory: RouterSessionDirectory { pair.directory }

        /// Makes a new store of ``storeFile``.
        ///
        /// - Returns: A store that has not read the file yet.
        func makeStore() -> JSONFileSessionUsageStore {
            JSONFileSessionUsageStore(fileURL: storeFile)
        }

        /// Vends a live root session of the recording router.
        ///
        /// - Returns: The session.
        func makeLiveRoot() -> any RoutedSession {
            pair.recordingProfile.standard.makeSession(configuration: SessionConfiguration())
        }

        /// Records a closed root session, live nowhere, and gives
        /// ``readingDirectory`` its recording root.
        ///
        /// - Returns: The id and the recording directory of the session.
        func recordClosedRoot() async -> (id: ULID, recordingDirectory: URL) {
            let recorded = await pair.recordClosedRoot()
            await pair.useRoot(of: recorded.recordingDirectory)
            return recorded
        }

        /// Removes the folders of the test.
        func remove() {
            pair.remove()
        }
    }

    /// Makes the two routers over one new recordings folder.
    private static func makeFixture() async throws -> Fixture {
        Fixture(pair: try await SessionDirectoryRouterPair.make(prefix: "RouterSessionDirectoryUsageTests"))
    }

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// A fixed time of a use or a pin that a test writes to the store.
    private static let firstTime = Date(timeIntervalSince1970: 1_800_000_000)

    /// A time one second after ``firstTime``.
    private static let secondTime = firstTime.addingTimeInterval(1)

    /// A query of each live and recorded session, with no limit.
    ///
    /// - Parameters:
    ///   - pinned: The pin filter of the query.
    ///   - order: The order of the query.
    /// - Returns: The query.
    private static func allSessions(pinned: Bool? = nil, order: SessionOrder = .newestFirst) -> SessionQuery {
        SessionQuery(pinned: pinned, includesRecorded: true, order: order, limit: .max)
    }

    /// Vends three live root sessions, the oldest first by id.
    ///
    /// - Parameter fixture: The fixture of the test.
    /// - Returns: The sessions, sorted by id ascending.
    private static func makeThreeLiveRoots(in fixture: Fixture) -> [any RoutedSession] {
        [fixture.makeLiveRoot(), fixture.makeLiveRoot(), fixture.makeLiveRoot()].sorted { $0.id < $1.id }
    }

    /// The summary that a `started` event carries.
    ///
    /// - Parameter event: An event, or `nil` when the stream ended.
    /// - Returns: The summary of a `started` event, or `nil` for each other
    ///   event.
    private static func startedSummary(of event: SessionDirectoryEvent?) -> SessionSummary? {
        guard case .started(let summary, _) = event else { return nil }
        return summary
    }

    /// Closes each session.
    ///
    /// - Parameter sessions: The sessions.
    private static func close(_ sessions: [any RoutedSession]) async {
        for session in sessions {
            await session.close()
        }
    }

    // MARK: - Pin and use of a live session

    /// `setPinned` on a live session writes the pin to the store and sends
    /// one `factsChanged` with the time of the pin.
    @Test func setPinnedOnALiveSessionWritesTheStoreAndSendsFactsChanged() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.liveDirectory.use(usageStore: store)
        let session = fixture.makeLiveRoot()
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.setPinned(true, of: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.pinnedAt != nil)
        #expect(summary.pinnedAt == store.usage(of: session.id)?.pinnedAt)
        #expect(received == [.factsChanged(summary), Self.marker])
        await session.close()
    }

    /// `markUsed` on a live session writes the use to the store and sends one
    /// `factsChanged` with the time of the use.
    @Test func markUsedOnALiveSessionWritesTheStoreAndSendsFactsChanged() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.liveDirectory.use(usageStore: store)
        let session = fixture.makeLiveRoot()
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.markUsed(session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.lastUsedAt != nil)
        #expect(summary.lastUsedAt == store.usage(of: session.id)?.lastUsedAt)
        #expect(received == [.factsChanged(summary), Self.marker])
        await session.close()
    }

    /// A pin of a live root session writes its recording root to the store:
    /// the folder that holds its recording directory.
    @Test func setPinnedOnALiveRootWritesItsRecordingRoot() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.liveDirectory.use(usageStore: store)
        let session = fixture.makeLiveRoot()

        try await fixture.liveDirectory.setPinned(true, of: session.id)

        #expect(
            store.usage(of: session.id)?.recordingRoot?.standardizedFileURL
                == session.recordingDirectory.deletingLastPathComponent().standardizedFileURL)
        await session.close()
    }

    /// A pin of a pinned session keeps the first time and sends no event.
    @Test func setPinnedOnAPinnedSessionSendsNoEvent() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        await fixture.liveDirectory.use(usageStore: fixture.makeStore())
        let session = fixture.makeLiveRoot()
        let first = try await fixture.liveDirectory.setPinned(true, of: session.id)
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let second = try await fixture.liveDirectory.setPinned(true, of: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(second.pinnedAt == first.pinnedAt)
        #expect(received == [Self.marker])
        await session.close()
    }

    /// An unpin clears the pin of the summary and of the store.
    @Test func setPinnedFalseClearsThePin() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.liveDirectory.use(usageStore: store)
        let session = fixture.makeLiveRoot()
        try await fixture.liveDirectory.setPinned(true, of: session.id)

        let summary = try await fixture.liveDirectory.setPinned(false, of: session.id)

        #expect(summary.pinnedAt == nil)
        #expect(store.usage(of: session.id)?.pinnedAt == nil)
        await session.close()
    }

    // MARK: - Pin and use of a recorded session

    /// `setPinned` on a recorded session that is not live writes the pin and
    /// the recording root to the store, and sends one `factsChanged` with its
    /// recorded summary.
    @Test func setPinnedOnARecordedSessionWritesTheStoreAndSendsFactsChanged() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.readingDirectory.use(usageStore: store)
        let recorded = await fixture.recordClosedRoot()
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let summary = try await fixture.readingDirectory.setPinned(true, of: recorded.id)
        fixture.readingDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(!summary.isLive)
        #expect(summary.pinnedAt == store.usage(of: recorded.id)?.pinnedAt)
        #expect(
            store.usage(of: recorded.id)?.recordingRoot?.standardizedFileURL
                == recorded.recordingDirectory.deletingLastPathComponent().standardizedFileURL)
        #expect(received == [.factsChanged(summary), Self.marker])
    }

    /// `markUsed` on a recorded session that is not live writes the use to
    /// the store, and sends one `factsChanged` with its recorded summary.
    @Test func markUsedOnARecordedSessionWritesTheStoreAndSendsFactsChanged() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.readingDirectory.use(usageStore: store)
        let recorded = await fixture.recordClosedRoot()
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let summary = try await fixture.readingDirectory.markUsed(recorded.id)
        fixture.readingDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.lastUsedAt != nil)
        #expect(summary.lastUsedAt == store.usage(of: recorded.id)?.lastUsedAt)
        #expect(received == [.factsChanged(summary), Self.marker])
    }

    // MARK: - No store and no session

    /// With no store, `setPinned` gives the summary with no pin and sends no
    /// event, as the Extras default does.
    @Test func setPinnedWithNoStoreChangesNothing() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot()
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.setPinned(true, of: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.pinnedAt == nil)
        #expect(received == [Self.marker])
        await session.close()
    }

    /// With no store, `markUsed` gives the summary with no use and sends no
    /// event, as the Extras default does.
    @Test func markUsedWithNoStoreChangesNothing() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot()
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.markUsed(session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.lastUsedAt == nil)
        #expect(received == [Self.marker])
        await session.close()
    }

    /// `setPinned` of an id that no live or recorded session has throws
    /// `unknownSession` and writes nothing to the store.
    @Test func setPinnedOfAnUnknownSessionThrows() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.liveDirectory.use(usageStore: store)
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await fixture.liveDirectory.setPinned(true, of: unknown)
        }
        #expect(store.usage(of: unknown) == nil)
    }

    // MARK: - Summaries

    /// `summary(of:)` gives the pin and the last use that the store holds.
    @Test func summaryOfALiveSessionCarriesTheUsageOfTheStore() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.liveDirectory.use(usageStore: store)
        let session = fixture.makeLiveRoot()
        try store.setPinned(true, of: session.id, recordingRoot: nil, at: Self.firstTime)
        try store.markUsed(session.id, recordingRoot: nil, at: Self.secondTime)

        let summary = try #require(try await fixture.liveDirectory.summary(of: session.id))

        #expect(summary.pinnedAt == Self.firstTime)
        #expect(summary.lastUsedAt == Self.secondTime)
        await session.close()
    }

    /// `summary(of:)` of a recorded session gives the pin that the store
    /// holds.
    @Test func summaryOfARecordedSessionCarriesTheUsageOfTheStore() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.readingDirectory.use(usageStore: store)
        let recorded = await fixture.recordClosedRoot()
        try store.setPinned(true, of: recorded.id, recordingRoot: nil, at: Self.firstTime)

        let summary = try #require(try await fixture.readingDirectory.summary(of: recorded.id))

        #expect(summary.pinnedAt == Self.firstTime)
    }

    /// The `started` event of a session that a router restores gives the pin
    /// that the store holds.
    @Test func theStartedEventOfARestoredSessionCarriesThePin() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.readingDirectory.use(usageStore: store)
        let recorded = await fixture.recordClosedRoot()
        try store.setPinned(true, of: recorded.id, recordingRoot: nil, at: Self.firstTime)
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let restored = try await fixture.pair.readingProfile.standard.restoreSession(
            id: recorded.id, recordingRoot: recorded.recordingDirectory.deletingLastPathComponent())
        let first = await events.next()

        #expect(Self.startedSummary(of: first)?.pinnedAt == Self.firstTime)
        await restored.session.close()
    }

    // MARK: - Pin filter

    /// `pinned: true` gives only the pinned sessions.
    @Test func thePinnedTrueFilterGivesOnlyThePinnedSessions() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        await fixture.liveDirectory.use(usageStore: fixture.makeStore())
        let pinned = fixture.makeLiveRoot()
        let other = fixture.makeLiveRoot()
        try await fixture.liveDirectory.setPinned(true, of: pinned.id)

        let found = try await fixture.liveDirectory.sessions(matching: Self.allSessions(pinned: true))

        #expect(found.map(\.id) == [pinned.id])
        await Self.close([pinned, other])
    }

    /// `pinned: false` gives only the sessions that are not pinned.
    @Test func thePinnedFalseFilterGivesOnlyTheSessionsThatAreNotPinned() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        await fixture.liveDirectory.use(usageStore: fixture.makeStore())
        let pinned = fixture.makeLiveRoot()
        let other = fixture.makeLiveRoot()
        try await fixture.liveDirectory.setPinned(true, of: pinned.id)

        let found = try await fixture.liveDirectory.sessions(matching: Self.allSessions(pinned: false))

        #expect(found.map(\.id) == [other.id])
        await Self.close([pinned, other])
    }

    // MARK: - Order

    /// `lastUsedFirst` gives the last use first, then the sessions with no
    /// use, the newest first.
    @Test func theLastUsedFirstOrderGivesTheLastUseFirst() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.liveDirectory.use(usageStore: store)
        let sessions = Self.makeThreeLiveRoots(in: fixture)
        try store.markUsed(sessions[0].id, recordingRoot: nil, at: Self.secondTime)
        try store.markUsed(sessions[1].id, recordingRoot: nil, at: Self.firstTime)

        let found = try await fixture.liveDirectory.sessions(matching: Self.allSessions(order: .lastUsedFirst))

        #expect(found.map(\.id) == [sessions[0].id, sessions[1].id, sessions[2].id])
        await Self.close(sessions)
    }

    /// `pinOrder` gives the first pin first, then the sessions that are not
    /// pinned, the newest first.
    @Test func thePinOrderGivesTheFirstPinFirst() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await fixture.liveDirectory.use(usageStore: store)
        let sessions = Self.makeThreeLiveRoots(in: fixture)
        try store.setPinned(true, of: sessions[0].id, recordingRoot: nil, at: Self.firstTime)
        try store.setPinned(true, of: sessions[1].id, recordingRoot: nil, at: Self.secondTime)

        let found = try await fixture.liveDirectory.sessions(matching: Self.allSessions(order: .pinOrder))

        #expect(found.map(\.id) == [sessions[0].id, sessions[1].id, sessions[2].id])
        await Self.close(sessions)
    }

    // MARK: - Restart

    /// A new router that has no recording roots of the host, but the same
    /// store, finds a pinned recorded session through the recording root
    /// that the store holds.
    @Test func aNewRouterWithTheSameStoreFindsAPinnedRecordedSession() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        await fixture.liveDirectory.use(usageStore: fixture.makeStore())
        let session = fixture.makeLiveRoot()
        try await fixture.liveDirectory.setPinned(true, of: session.id)
        await session.close()
        await fixture.readingDirectory.use(usageStore: fixture.makeStore())

        let found = try await fixture.readingDirectory.sessions(matching: Self.allSessions())

        #expect(found.map(\.id) == [session.id])
        #expect(found.first?.isPinned == true)
    }
}
