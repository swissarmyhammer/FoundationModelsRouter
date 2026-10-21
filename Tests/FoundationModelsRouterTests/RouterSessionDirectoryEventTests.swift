import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The event stream of ``RouterSessionDirectory`` (ROUTER-3): each
/// `events()` call is a stream of its own, it gets `started` for each session
/// registered after the call, and the events of one session come in order.
///
/// Each test vends its sessions from a scripted model. A test that must show
/// a stream holds nothing more sends one marker event through the internal
/// emit and reads it as the next event: the read never waits on an event that
/// does not come.
@Suite struct RouterSessionDirectoryEventTests {
    /// A scripted profile and the router that resolved it.
    struct Fixture {
        /// The router that resolved ``profile``. It owns ``directory``.
        let router: Router

        /// The resolved scripted profile the sessions come from.
        let profile: LanguageModelProfile

        /// The directory under test: the router's own.
        var directory: RouterSessionDirectory { router.sessionDirectory }

        /// Vends one session from the `.standard` slot of ``profile``. The
        /// vend registers it in ``directory``.
        ///
        /// - Returns: The vended session.
        func vend() -> any RoutedSession {
            profile.standard.makeSession(configuration: SessionConfiguration())
        }

        /// The one summary the directory holds for `session`.
        ///
        /// - Parameter session: A vended session.
        /// - Returns: The summary of `session`.
        func registeredSummary(of session: any RoutedSession) async throws -> SessionSummary {
            try #require(try await directory.summary(of: session.id))
        }
    }

    /// Makes a fixture over a scripted profile, resolved by a router of its
    /// own.
    private static func makeFixture() async throws -> Fixture {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryEventTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: scratch.appendingPathComponent("cache"))
        return Fixture(router: router, profile: profile)
    }

    /// Reads the next `count` events of a stream. A stream that ends first
    /// gives fewer.
    ///
    /// - Parameters:
    ///   - count: How many events to read.
    ///   - iterator: The iterator of the stream; the read moves it on.
    /// - Returns: The events, in stream order.
    private static func next(
        _ count: Int, from iterator: inout AsyncStream<SessionDirectoryEvent>.Iterator
    ) async -> [SessionDirectoryEvent] {
        var events: [SessionDirectoryEvent] = []
        while events.count < count, let event = await iterator.next() {
            events.append(event)
        }
        return events
    }

    /// Closes each session in `sessions`.
    private static func close(_ sessions: [any RoutedSession]) async {
        for session in sessions {
            await session.close()
        }
    }

    // MARK: - Started

    /// A stream opened before a vend gets `started` with the summary of the
    /// vended session.
    @Test func aStreamOpenedBeforeAVendGetsStartedWithTheSummary() async throws {
        let fixture = try await Self.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()
        let session = fixture.vend()

        let received = await Self.next(1, from: &events)

        let summary = try await fixture.registeredSummary(of: session)
        #expect(received == [.started(summary, requestedByClient: nil)])
        await Self.close([session])
    }

    /// Two streams opened before a vend each get `started`.
    @Test func twoStreamsOpenedBeforeAVendEachGetStarted() async throws {
        let fixture = try await Self.makeFixture()
        var first = fixture.directory.events().makeAsyncIterator()
        var second = fixture.directory.events().makeAsyncIterator()
        let session = fixture.vend()

        let receivedByFirst = await Self.next(1, from: &first)
        let receivedBySecond = await Self.next(1, from: &second)

        let started = SessionDirectoryEvent.started(
            try await fixture.registeredSummary(of: session), requestedByClient: nil)
        #expect(receivedByFirst == [started])
        #expect(receivedBySecond == [started])
        await Self.close([session])
    }

    /// A stream opened after a vend does not get the `started` of that
    /// session: the first event it gets is the marker sent after it opened.
    @Test func aStreamOpenedAfterAVendDoesNotGetItsStarted() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.vend()
        var events = fixture.directory.events().makeAsyncIterator()
        fixture.directory.emit(Self.marker)

        let received = await Self.next(1, from: &events)

        #expect(received == [Self.marker])
        await Self.close([session])
    }

    /// `register` puts the client that asked for the start in the one
    /// `started` of the session.
    @Test func startedCarriesTheClientThatAskedForTheStart() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.vend()
        fixture.directory.unregister(session.id)
        var events = fixture.directory.events().makeAsyncIterator()
        fixture.directory.register(session, kind: .root, parentID: nil, requestedByClient: Self.requestingClient)

        let received = await Self.next(1, from: &events)

        let summary = try await fixture.registeredSummary(of: session)
        #expect(received == [.started(summary, requestedByClient: Self.requestingClient)])
        await Self.close([session])
    }

    /// A second registration of a session that is still live sends no
    /// second `started`.
    @Test func aSecondRegistrationOfALiveSessionSendsNoSecondStarted() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.vend()
        var events = fixture.directory.events().makeAsyncIterator()
        fixture.directory.register(session, kind: .root, parentID: nil)
        fixture.directory.emit(Self.marker)

        let received = await Self.next(1, from: &events)

        #expect(received == [Self.marker])
        await Self.close([session])
    }

    // MARK: - Order

    /// For one session, `started` comes before a later event of that session.
    @Test func startedComesBeforeALaterEventOfTheSession() async throws {
        let fixture = try await Self.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()
        let session = fixture.vend()
        let stateChanged = SessionDirectoryEvent.stateChanged(id: session.id, state: .working, lastSummary: nil)
        fixture.directory.emit(stateChanged)

        let received = await Self.next(2, from: &events)

        let summary = try await fixture.registeredSummary(of: session)
        #expect(received == [.started(summary, requestedByClient: nil), stateChanged])
        await Self.close([session])
    }

    // MARK: - Buffer

    /// A stream nobody reads while the directory sends 300 events keeps the
    /// newest 256 of them, and no more.
    @Test func aStreamNobodyReadsKeepsTheNewest256Events() async {
        let directory = RouterSessionDirectory()
        var events = directory.events().makeAsyncIterator()
        let sent = (0..<Self.unreadEventCount).map { _ in SessionDirectoryEvent.archived(id: ULID.generate()) }
        for event in sent {
            directory.emit(event)
        }

        let buffered = await Self.next(Self.bufferedEventCount, from: &events)
        directory.emit(Self.marker)
        let afterTheBuffer = await Self.next(1, from: &events)

        #expect(buffered == Array(sent.suffix(Self.bufferedEventCount)))
        #expect(afterTheBuffer == [Self.marker])
    }

    // MARK: - Ended streams

    /// A stream whose reader drops it leaves the directory.
    @Test func aDroppedStreamLeavesTheDirectory() {
        let directory = RouterSessionDirectory()

        do {
            let stream = directory.events()
            withExtendedLifetime(stream) {
                #expect(directory.openEventStreamCount == 1)
            }
        }

        #expect(directory.openEventStreamCount == 0)
    }

    // MARK: - No cursor

    /// An encoded event holds no sequence number and no cursor: the
    /// `sessions` graph adds those when it records the event.
    @Test func anEncodedEventHoldsNoSequenceAndNoCursor() throws {
        let encoded = String(decoding: try JSONEncoder().encode(Self.marker), as: UTF8.self)

        #expect(!encoded.contains("seq"))
        #expect(!encoded.contains("cursor"))
    }

    /// No Router source names the change log type of the Extras GraphQL
    /// toolkit: the `sessions` graph wraps the events, Router does not.
    @Test func noRouterSourceNamesTheChangeLog() throws {
        let files = try LibrarySourceFiles.urls(under: RepositoryRoot.url())

        let naming = try files.filter { file in
            try String(contentsOf: file, encoding: .utf8).contains(Self.changeLogTypeName)
        }

        #expect(naming.isEmpty, "these files name \(Self.changeLogTypeName): \(naming.map(\.lastPathComponent))")
    }

    // MARK: - Constants

    /// An event no test session sends, which a test sends to mark the end of
    /// what it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// The UI client that asks for a start.
    private static let requestingClient = "client-a"

    /// How many events the buffer test sends to a stream nobody reads.
    private static let unreadEventCount = 300

    /// How many events one stream buffers (session.md section 7, rule 1).
    private static let bufferedEventCount = 256

    /// The type name of the change log of the Extras GraphQL toolkit.
    private static let changeLogTypeName = "ChangeLog"
}
