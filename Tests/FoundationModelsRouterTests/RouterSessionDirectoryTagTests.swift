import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The tag and title changes of ``RouterSessionDirectory`` (ROUTER-2 through
/// ROUTER-3): `addTags`, `removeTags` and `setTitle`
/// check the tags, rewrite the `index.md` of the session, and send one
/// `factsChanged`. A call that changes nothing sends no event.
///
/// Router A records the sessions; router B is a new router over the same
/// recordings folder, standing in for a new process, which reaches the
/// recorded sessions through the roots the host gives with
/// `useRecordingRoots(_:)`, and restores them.
@Suite struct RouterSessionDirectoryTagTests {
    /// The two routers of one test, with the directory of each.
    struct Fixture {
        /// The two routers over one recordings folder.
        let pair: SessionDirectoryRouterPair

        /// The directory of the recording router, which holds its live
        /// sessions.
        var liveDirectory: RouterSessionDirectory { pair.recordingRouter.sessionDirectory }

        /// The directory of the reading router, which finds the sessions that
        /// the recording router recorded.
        var readingDirectory: RouterSessionDirectory { pair.directory }

        /// Vends a live root session of the recording router.
        ///
        /// - Parameter configuration: The configuration of the session.
        /// - Returns: The session.
        func makeLiveRoot(_ configuration: SessionConfiguration = SessionConfiguration()) -> any RoutedSession {
            pair.recordingProfile.standard.makeSession(configuration: configuration)
        }

        /// Records a closed root session, live nowhere, and gives
        /// ``readingDirectory`` its recording root.
        ///
        /// - Parameter configuration: The configuration of the session.
        /// - Returns: The id and the recording directory of the session.
        func recordClosedRoot(
            _ configuration: SessionConfiguration = SessionConfiguration()
        ) async -> (id: ULID, recordingDirectory: URL) {
            let recorded = await pair.recordClosedRoot(configuration)
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
        Fixture(pair: try await SessionDirectoryRouterPair.make(prefix: "RouterSessionDirectoryTagTests"))
    }

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// The tag a test adds.
    private static let reviewerTag = "reviewer"

    /// A second valid tag.
    private static let travelTag = "travel"

    /// A tag outside the tag rule: it holds a space.
    private static let invalidTag = "not valid"

    /// The title a test sets.
    private static let newTitle = "Plan the trip"

    /// The record that the `index.md` in `folder` holds.
    ///
    /// - Parameter folder: The recording directory of a session.
    /// - Returns: The record on disk.
    private static func recordOnDisk(in folder: URL) throws -> SessionRecord {
        try #require(try SessionIndexFile.read(in: folder))
    }

    /// The record that `recordedSessions(in:)` lists for the session in
    /// `folder`, read from the recording root that holds the folder.
    ///
    /// - Parameter folder: The recording directory of a root session.
    /// - Returns: The listed record of the session.
    private static func listedRecord(in folder: URL) throws -> SessionRecord {
        let records = try RouterSessionDirectory.recordedSessions(in: folder.deletingLastPathComponent())
        return try #require(records.first { $0.sessionId.description == folder.lastPathComponent })
    }

    // MARK: - Add

    /// `addTags` on a live session gives a summary with the tag, writes the
    /// tag to the `index.md` of the session, and sends one `factsChanged`.
    @Test func addTagsOnALiveSessionWritesTheIndexAndSendsFactsChanged() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot()
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.addTags([Self.reviewerTag], to: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.tags == [Self.reviewerTag])
        #expect(summary.isLive)
        #expect(session.facts.tags == [Self.reviewerTag])
        #expect(try Self.recordOnDisk(in: session.recordingDirectory).facts.tags == [Self.reviewerTag])
        #expect(received == [.factsChanged(summary), Self.marker])
        await session.close()
    }

    /// `addTags` keeps the tags the session holds and joins the new ones.
    @Test func addTagsJoinsTheTagsTheSessionHolds() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot(SessionConfiguration(tags: [Self.travelTag]))

        let summary = try await fixture.liveDirectory.addTags([Self.reviewerTag], to: session.id)

        #expect(summary.tags == [Self.travelTag, Self.reviewerTag])
        #expect(
            try Self.recordOnDisk(in: session.recordingDirectory).facts.tags == [Self.travelTag, Self.reviewerTag])
        await session.close()
    }

    /// `addTags` with a tag the live session holds gives the summary and
    /// sends no event.
    @Test func addTagsWithATagThatIsThereSendsNoEvent() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot(SessionConfiguration(tags: [Self.reviewerTag]))
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.addTags([Self.reviewerTag], to: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.tags == [Self.reviewerTag])
        #expect(received == [Self.marker])
        await session.close()
    }

    /// `addTags` on a recorded session that is not live rewrites the
    /// `index.md` of its folder and sends one `factsChanged` with its
    /// recorded summary.
    @Test func addTagsOnARecordedSessionRewritesItsIndex() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let summary = try await fixture.readingDirectory.addTags([Self.reviewerTag], to: recorded.id)
        fixture.readingDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.tags == [Self.reviewerTag])
        #expect(!summary.isLive)
        #expect(try Self.recordOnDisk(in: recorded.recordingDirectory).facts.tags == [Self.reviewerTag])
        #expect(received == [.factsChanged(summary), Self.marker])
    }

    /// `addTags` with a tag a recorded session holds gives the summary,
    /// leaves its `index.md` as it was, and sends no event.
    @Test func addTagsWithATagARecordedSessionHoldsSendsNoEvent() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot(SessionConfiguration(tags: [Self.reviewerTag]))
        let before = try Self.recordOnDisk(in: recorded.recordingDirectory)
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let summary = try await fixture.readingDirectory.addTags([Self.reviewerTag], to: recorded.id)
        fixture.readingDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.tags == [Self.reviewerTag])
        #expect(try Self.recordOnDisk(in: recorded.recordingDirectory) == before)
        #expect(received == [Self.marker])
    }

    // MARK: - Remove

    /// `removeTags` on a live session gives a summary without the tag,
    /// removes it from the `index.md`, and sends one `factsChanged`.
    @Test func removeTagsOnALiveSessionWritesTheIndexAndSendsFactsChanged() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot(SessionConfiguration(tags: [Self.reviewerTag, Self.travelTag]))
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.removeTags([Self.reviewerTag], from: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.tags == [Self.travelTag])
        #expect(session.facts.tags == [Self.travelTag])
        #expect(try Self.recordOnDisk(in: session.recordingDirectory).facts.tags == [Self.travelTag])
        #expect(received == [.factsChanged(summary), Self.marker])
        await session.close()
    }

    /// `removeTags` with a tag the live session does not hold gives the
    /// summary and sends no event.
    @Test func removeTagsWithATagThatIsNotThereSendsNoEvent() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot(SessionConfiguration(tags: [Self.travelTag]))
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.removeTags([Self.reviewerTag], from: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.tags == [Self.travelTag])
        #expect(received == [Self.marker])
        await session.close()
    }

    /// `removeTags` on a recorded session that is not live rewrites the
    /// `index.md` of its folder and sends one `factsChanged`.
    @Test func removeTagsOnARecordedSessionRewritesItsIndex() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot(SessionConfiguration(tags: [Self.reviewerTag]))
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let summary = try await fixture.readingDirectory.removeTags([Self.reviewerTag], from: recorded.id)
        fixture.readingDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.tags.isEmpty)
        #expect(try Self.recordOnDisk(in: recorded.recordingDirectory).facts.tags.isEmpty)
        #expect(received == [.factsChanged(summary), Self.marker])
    }

    // MARK: - Title

    /// `setTitle` on a live session gives a summary with the title, writes
    /// the title to the `index.md`, which `recordedSessions(in:)` reads back,
    /// and sends one `factsChanged`.
    @Test func setTitleOnALiveSessionWritesTheIndexAndSendsFactsChanged() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot()
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.setTitle(Self.newTitle, of: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.title == Self.newTitle)
        #expect(session.facts.title == Self.newTitle)
        #expect(try Self.recordOnDisk(in: session.recordingDirectory).facts.title == Self.newTitle)
        #expect(try Self.listedRecord(in: session.recordingDirectory).facts.title == Self.newTitle)
        #expect(received == [.factsChanged(summary), Self.marker])
        await session.close()
    }

    /// `setTitle` with the title the live session holds gives the summary
    /// and sends no event.
    @Test func setTitleWithTheSameTitleSendsNoEvent() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot(SessionConfiguration(title: Self.newTitle))
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        let summary = try await fixture.liveDirectory.setTitle(Self.newTitle, of: session.id)
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.title == Self.newTitle)
        #expect(received == [Self.marker])
        await session.close()
    }

    /// `setTitle` on a recorded session that is not live rewrites the
    /// `index.md` of its folder, which `recordedSessions(in:)` reads back,
    /// and sends one `factsChanged`.
    @Test func setTitleOnARecordedSessionRewritesItsIndex() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        var events = fixture.readingDirectory.events().makeAsyncIterator()

        let summary = try await fixture.readingDirectory.setTitle(Self.newTitle, of: recorded.id)
        fixture.readingDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(summary.title == Self.newTitle)
        #expect(!summary.isLive)
        #expect(try Self.recordOnDisk(in: recorded.recordingDirectory).facts.title == Self.newTitle)
        #expect(try Self.listedRecord(in: recorded.recordingDirectory).facts.title == Self.newTitle)
        #expect(received == [.factsChanged(summary), Self.marker])
    }

    // MARK: - Invalid tags

    /// `addTags` with one invalid tag among valid ones throws `invalidTag`,
    /// changes neither the session nor its `index.md`, and sends no event.
    @Test func addTagsWithAnInvalidTagChangesNothing() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot(SessionConfiguration(tags: [Self.travelTag]))
        let before = try Self.recordOnDisk(in: session.recordingDirectory)
        var events = fixture.liveDirectory.events().makeAsyncIterator()

        await #expect(throws: SessionDirectoryError.invalidTag(Self.invalidTag)) {
            try await fixture.liveDirectory.addTags([Self.reviewerTag, Self.invalidTag], to: session.id)
        }
        fixture.liveDirectory.emit(Self.marker)
        let received = await events.next(through: Self.marker)

        #expect(session.facts.tags == [Self.travelTag])
        #expect(try Self.recordOnDisk(in: session.recordingDirectory) == before)
        #expect(received == [Self.marker])
        await session.close()
    }

    /// `removeTags` with an invalid tag throws `invalidTag` and leaves the
    /// `index.md` of a recorded session as it was.
    @Test func removeTagsWithAnInvalidTagChangesNothingOnDisk() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot(SessionConfiguration(tags: [Self.reviewerTag]))
        let before = try Self.recordOnDisk(in: recorded.recordingDirectory)

        await #expect(throws: SessionDirectoryError.invalidTag(Self.invalidTag)) {
            try await fixture.readingDirectory.removeTags([Self.reviewerTag, Self.invalidTag], from: recorded.id)
        }

        #expect(try Self.recordOnDisk(in: recorded.recordingDirectory) == before)
    }

    // MARK: - Unknown sessions

    /// Each change with an id that no live or recorded session has throws
    /// `unknownSession` with that id.
    @Test func eachChangeOfAnUnknownSessionThrowsUnknownSession() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        _ = await fixture.recordClosedRoot()
        let directory = fixture.readingDirectory
        let unknown = ULID.generate()

        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await directory.addTags([Self.reviewerTag], to: unknown)
        }
        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await directory.removeTags([Self.reviewerTag], from: unknown)
        }
        await #expect(throws: SessionDirectoryError.unknownSession(unknown)) {
            try await directory.setTitle(Self.newTitle, of: unknown)
        }
    }

    // MARK: - Persist and read back

    /// A tag added to a live session is in its `index.md`, so a new router
    /// that restores the session finds it with a query by that tag.
    @Test func aTagSurvivesARestoreInANewRouterAndTheQueryByTagFindsIt() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let session = fixture.makeLiveRoot()
        _ = try await fixture.liveDirectory.addTags([Self.reviewerTag], to: session.id)
        await session.close()

        let restored = try await fixture.pair.readingProfile.standard.restoreSession(
            id: session.id, recordingRoot: session.recordingDirectory.deletingLastPathComponent())
        let found = try await fixture.readingDirectory.sessions(matching: SessionQuery(tag: Self.reviewerTag))

        #expect(found.map(\.id) == [session.id])
        #expect(found.first?.isLive == true)
        await restored.session.close()
    }

    // MARK: - Archived sessions

    /// An archived recorded session can still be tagged and renamed: only
    /// messages are refused to it.
    @Test func anArchivedRecordedSessionCanBeTaggedAndRenamed() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.remove() }
        let recorded = await fixture.recordClosedRoot()
        try RouterTestFixtures.rewriteIndex(in: recorded.recordingDirectory) { $0.facts.archivedAt = Date() }

        _ = try await fixture.readingDirectory.addTags([Self.reviewerTag], to: recorded.id)
        let summary = try await fixture.readingDirectory.setTitle(Self.newTitle, of: recorded.id)

        #expect(summary.state == .archived)
        #expect(summary.tags == [Self.reviewerTag])
        #expect(summary.title == Self.newTitle)
    }
}
