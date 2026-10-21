import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The session launcher port of ``RouterSessionDirectory`` (ROUTER-8):
/// `useLauncher(_:)`, `start(_:)` and `shutdown()`.
///
/// Each test starts its sessions through a ``FakeSessionLauncher`` that vends
/// them from a scripted model. A test that must show a stream holds nothing
/// more sends one marker event through the internal emit and reads it as the
/// next event: the read never waits on an event that does not come.
@Suite struct RouterSessionDirectoryLauncherTests {
    /// A router and a launcher over the scripted profile it resolved.
    struct Fixture {
        /// The router that resolved the profile of ``launcher``. It owns
        /// ``directory``.
        let router: Router

        /// The launcher the directory starts its sessions with.
        let launcher: FakeSessionLauncher

        /// The directory under test: the router's own.
        var directory: RouterSessionDirectory { router.sessionDirectory }

        /// The one session the launcher vended.
        ///
        /// - Returns: The session.
        func launchedSession() throws -> any RoutedSession {
            try #require(launcher.sessions.only)
        }
    }

    /// Makes a router over a scripted profile of its own.
    ///
    /// - Returns: The router and its resolved profile.
    private static func makeRouter() async throws -> (router: Router, profile: LanguageModelProfile) {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryLauncherTests")
        return try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: scratch.appendingPathComponent("cache"))
    }

    /// Makes a fixture whose directory uses a launcher over the profile of
    /// its own router.
    ///
    /// - Parameter copiesRequestFacts: Whether the launcher keeps the
    ///   contract and copies the facts of the request. The default is `true`.
    /// - Returns: The fixture.
    private static func makeFixture(copiesRequestFacts: Bool = true) async throws -> Fixture {
        let (router, profile) = try await makeRouter()
        let launcher = FakeSessionLauncher(profile: profile, copiesRequestFacts: copiesRequestFacts)
        await router.sessionDirectory.useLauncher(launcher)
        return Fixture(router: router, launcher: launcher)
    }

    /// A request that sets each fact a launcher copies, and no agent and no
    /// folder.
    ///
    /// - Parameter startedBy: The session that asks for the start, or `nil`
    ///   (the default) for a start by a UI.
    /// - Returns: The request.
    private static func request(startedBy: ULID? = nil) -> SessionStartRequest {
        SessionStartRequest(
            firstMessage: firstMessage, tags: tags, title: title, startedBy: startedBy,
            requestedByClient: requestingClient, origin: origin)
    }

    /// The text of each prompt of `transcript`, in order.
    ///
    /// - Parameter transcript: The transcript of a session.
    /// - Returns: The flattened text of each prompt.
    private static func promptTexts(of transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            switch entry {
            case .prompt(let prompt): TranscriptEntryMapper.flattenedText(prompt)
            default: nil
            }
        }
    }

    /// The text of each response of `transcript`, in order.
    ///
    /// - Parameter transcript: The transcript of a session.
    /// - Returns: The text segments of each response, joined.
    private static func responseTexts(of transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            switch entry {
            case .response(let response): response.segments.compactMap(Self.text(of:)).joined()
            default: nil
            }
        }
    }

    /// The content of a text segment, or `nil` for any other segment.
    ///
    /// - Parameter segment: A segment of a response.
    /// - Returns: The text.
    private static func text(of segment: Transcript.Segment) -> String? {
        switch segment {
        case .text(let text): text.content
        default: nil
        }
    }

    // MARK: - No launcher

    /// With no launcher, `start` throws `noLauncher`.
    @Test func startWithNoLauncherThrowsNoLauncher() async throws {
        let (router, _) = try await Self.makeRouter()

        await #expect(throws: SessionDirectoryError.noLauncher) {
            try await router.sessionDirectory.start(Self.request())
        }
    }

    // MARK: - The request

    /// The launcher gets the request exactly as given: a nil agent and a nil
    /// folder stay nil.
    @Test func theLauncherGetsTheRequestUnchanged() async throws {
        let fixture = try await Self.makeFixture()
        let request = Self.request()

        _ = try await fixture.directory.start(request)

        #expect(fixture.launcher.requests == [request])
        #expect(request.agentID == nil)
        #expect(request.workingDirectory == nil)
        await fixture.launcher.closeSessions()
    }

    // MARK: - The started session

    /// The started session is live in the directory as a root, with the tags,
    /// the title, `startedBy` and the origin of the request.
    @Test func theStartedSessionIsLiveWithTheFactsOfTheRequest() async throws {
        let fixture = try await Self.makeFixture()
        let startedBy = ULID.generate()

        let returned = try await fixture.directory.start(Self.request(startedBy: startedBy))

        let session = try fixture.launchedSession()
        let summary = try #require(try await fixture.directory.summary(of: session.id))
        #expect(returned == summary)
        #expect(summary.kind == .root)
        #expect(summary.tags == Self.tags)
        #expect(summary.title == Self.title)
        #expect(summary.startedBy == startedBy)
        #expect(summary.origin == Self.origin)
        await fixture.launcher.closeSessions()
    }

    /// `start` sends exactly one `started`, and that event already holds the
    /// facts of the request and the client that asked for the start.
    @Test func startSendsExactlyOneStartedWithTheFactsOfTheRequest() async throws {
        let fixture = try await Self.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()

        let summary = try await fixture.directory.start(Self.request())
        fixture.directory.emit(Self.marker)
        let received = await events.next(count: 2)

        #expect(received == [.started(summary, requestedByClient: Self.requestingClient), Self.marker])
        #expect(summary.tags == Self.tags)
        #expect(summary.title == Self.title)
        await fixture.launcher.closeSessions()
    }

    // MARK: - The first message

    /// The first message of a start by a UI starts a turn as a user message,
    /// and the scripted model answers it.
    @Test func theFirstMessageStartsATurnThatTheModelAnswers() async throws {
        let fixture = try await Self.makeFixture()

        _ = try await fixture.directory.start(Self.request())

        let session = try fixture.launchedSession()
        #expect(await session.awaitIdle())
        let transcript = await session.transcript
        #expect(Self.promptTexts(of: transcript) == [Self.firstMessage])
        #expect(Self.responseTexts(of: transcript) == [BasicLLMContainer.defaultResponseText])
        await fixture.launcher.closeSessions()
    }

    /// The first message of a start by a session arrives as an agent message
    /// from that session, and the scripted model answers it.
    @Test func theFirstMessageOfAStartBySessionIsAnAgentMessage() async throws {
        let fixture = try await Self.makeFixture()
        let startedBy = ULID.generate()
        let agentMessage = Mail(
            sender: .session(startedBy), body: .agentMessage(from: startedBy, content: Self.firstMessage))

        _ = try await fixture.directory.start(Self.request(startedBy: startedBy))

        let session = try fixture.launchedSession()
        #expect(await session.awaitIdle())
        let transcript = await session.transcript
        #expect(Self.promptTexts(of: transcript) == [try #require(agentMessage.promptText)])
        #expect(Self.responseTexts(of: transcript) == [BasicLLMContainer.defaultResponseText])
        await fixture.launcher.closeSessions()
    }

    // MARK: - A launcher that breaks the contract

    /// A launcher that vends a session with none of the facts of the request:
    /// `start` writes them to the session and sends `factsChanged` after the
    /// one `started`.
    @Test func startWritesTheFactsALauncherDidNotCopy() async throws {
        let fixture = try await Self.makeFixture(copiesRequestFacts: false)
        let startedBy = ULID.generate()
        var events = fixture.directory.events().makeAsyncIterator()

        let summary = try await fixture.directory.start(Self.request(startedBy: startedBy))
        fixture.directory.emit(Self.marker)
        let received = await events.next(count: 3)

        let session = try fixture.launchedSession()
        let facts = session.facts
        #expect(facts.tags == Self.tags)
        #expect(facts.title == Self.title)
        #expect(facts.startedBy == startedBy)
        #expect(facts.origin == Self.origin)
        #expect(received.count == 3)
        #expect(received.dropFirst() == [.factsChanged(summary), Self.marker])
        await fixture.launcher.closeSessions()
    }

    // MARK: - A session from another router

    /// A session that the launcher vends from another router is registered by
    /// `start` itself: it is live in this directory, and its one `started`
    /// holds the facts of the request and the client.
    @Test func startRegistersASessionFromAnotherRouter() async throws {
        let (router, _) = try await Self.makeRouter()
        let (_, otherProfile) = try await Self.makeRouter()
        let launcher = FakeSessionLauncher(profile: otherProfile)
        await router.sessionDirectory.useLauncher(launcher)
        var events = router.sessionDirectory.events().makeAsyncIterator()

        let summary = try await router.sessionDirectory.start(Self.request())
        router.sessionDirectory.emit(Self.marker)
        let received = await events.next(count: 2)

        let session = try #require(launcher.sessions.only)
        #expect(try await router.sessionDirectory.summary(of: session.id) == summary)
        #expect(received == [.started(summary, requestedByClient: Self.requestingClient), Self.marker])
        #expect(summary.tags == Self.tags)
        await launcher.closeSessions()
    }

    // MARK: - Shutdown

    /// `shutdown()` releases the launcher: the directory holds no reference
    /// to it.
    @Test func shutdownReleasesTheLauncher() async throws {
        let (router, profile) = try await Self.makeRouter()
        weak var released: FakeSessionLauncher?
        do {
            let launcher = FakeSessionLauncher(profile: profile)
            released = launcher
            await router.sessionDirectory.useLauncher(launcher)
        }
        #expect(released != nil)

        await router.sessionDirectory.shutdown()

        #expect(released == nil)
    }

    /// `shutdown()` ends each open event stream.
    @Test func shutdownEndsTheOpenEventStreams() async throws {
        let fixture = try await Self.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()

        await fixture.directory.shutdown()

        #expect(await events.next() == nil)
        #expect(fixture.directory.openEventStreamCount == 0)
    }

    /// After `shutdown()`, `start` throws `noLauncher`.
    @Test func startAfterShutdownThrowsNoLauncher() async throws {
        let fixture = try await Self.makeFixture()

        await fixture.directory.shutdown()

        await #expect(throws: SessionDirectoryError.noLauncher) {
            try await fixture.directory.start(Self.request())
        }
        #expect(fixture.launcher.requests.isEmpty)
    }

    // MARK: - Constants

    /// An event no test session sends, which a test sends to mark the end of
    /// what it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// The first message of each start.
    private static let firstMessage = "Summarize the open tasks."

    /// The tags of each start.
    private static let tags: Set<String> = ["triage", "nightly"]

    /// The title of each start.
    private static let title = "Nightly triage"

    /// The origin of each start.
    private static let origin = SessionDirectoryOrigin.tool

    /// The UI client that asks for each start.
    private static let requestingClient = "client-a"
}

extension Array {
    /// The one element of the array, or `nil` when it holds none or more
    /// than one.
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
