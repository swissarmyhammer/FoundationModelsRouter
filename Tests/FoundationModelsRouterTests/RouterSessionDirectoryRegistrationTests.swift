import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The registration of each new session in its router's directory
/// (ROUTER-3): a profile reaches the ``RouterSessionDirectory`` of the router
/// that resolved it, and `makeSession` registers each root and subagent
/// session there before it returns.
///
/// Each test vends its sessions from a scripted model and queries the
/// directory right after the call, with no wait.
@Suite struct RouterSessionDirectoryRegistrationTests {
    /// A scripted profile and the router that resolved it.
    struct Fixture {
        /// The router that resolved ``profile``. It owns ``directory``.
        let router: Router

        /// The resolved scripted profile the sessions come from.
        let profile: LanguageModelProfile

        /// The directory under test: the router's own.
        var directory: RouterSessionDirectory { router.sessionDirectory }

        /// Vends one session from the `.standard` slot of ``profile``.
        ///
        /// - Parameter configuration: The configuration of the session.
        /// - Returns: The vended session.
        func vend(_ configuration: SessionConfiguration = SessionConfiguration()) -> any RoutedSession {
            profile.standard.makeSession(configuration: configuration)
        }
    }

    /// Makes a fixture over a scripted profile, resolved by a router of its
    /// own.
    private static func makeFixture() async throws -> Fixture {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryRegistrationTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: scratch.appendingPathComponent("cache"))
        return Fixture(router: router, profile: profile)
    }

    /// The context of a tool call of `parent` that starts a child session.
    ///
    /// - Parameter parent: The session whose tool call starts the child.
    /// - Returns: The context of the call.
    private static func parentCall(of parent: any RoutedSession) throws -> ToolContext {
        let parentActor = try #require(parent as? RoutedSessionActor)
        return ToolContext(
            sessionID: parentActor.id, runPlane: parentActor.runPlane,
            sink: DroppingEventSink(), tool: "agents", op: "start agent",
            completionToken: ToolContext.makeCompletionToken(), isCancelled: { false })
    }

    /// Closes each session in `sessions`.
    private static func close(_ sessions: [any RoutedSession]) async {
        for session in sessions {
            await session.close()
        }
    }

    // MARK: - Root

    /// A session from `router.resolve(...).standard.makeSession(configuration:)`
    /// is in the router's directory as a root, right after the call.
    @Test func aNewRootSessionIsInTheDirectoryOfItsRouter() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.vend()

        let found = try await fixture.directory.sessions(matching: SessionQuery(kind: .root))

        #expect(found.map(\.id) == [session.id])
        await Self.close([session])
    }

    /// A new root has the kind `root` and no parent.
    @Test func aNewRootHasNoParent() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.vend()

        let summary = try await SessionDirectorySummaries.summary(of: session.id, in: fixture.directory)

        #expect(summary.kind == .root)
        #expect(summary.parentID == nil)
        await Self.close([session])
    }

    // MARK: - Subagent

    /// A session that a tool call of a parent starts is a subagent of that
    /// parent.
    @Test func aSessionStartedByAParentCallIsASubagentOfThatParent() async throws {
        let fixture = try await Self.makeFixture()
        let parent = fixture.vend()
        let child = fixture.vend(SessionConfiguration(parentCall: try Self.parentCall(of: parent)))

        let summary = try await SessionDirectorySummaries.summary(of: child.id, in: fixture.directory)

        #expect(summary.kind == .subagent)
        #expect(summary.parentID == parent.id)
        await Self.close([child, parent])
    }

    /// A session with a recorded agent spawn is a subagent of the spawning
    /// session.
    @Test func aSessionWithARecordedSpawnIsASubagentOfTheSpawningSession() async throws {
        let fixture = try await Self.makeFixture()
        let spawningSessionId = ULID.generate()
        let spawn = SessionRecord.AgentSpawn(
            parentSessionId: spawningSessionId, parentToolCallId: "agents-tool-call-1")
        let child = fixture.vend(SessionConfiguration(agentSpawn: spawn))

        let summary = try await SessionDirectorySummaries.summary(of: child.id, in: fixture.directory)

        #expect(summary.kind == .subagent)
        #expect(summary.parentID == spawningSessionId)
        await Self.close([child])
    }

    // MARK: - Separation

    /// The sessions of two routers in one process stay in the directory of
    /// their own router.
    @Test func twoRoutersKeepSeparateDirectories() async throws {
        let first = try await Self.makeFixture()
        let second = try await Self.makeFixture()
        let firstSession = first.vend()
        let secondSession = second.vend()

        let inFirst = try await first.directory.sessions(matching: SessionQuery())
        let inSecond = try await second.directory.sessions(matching: SessionQuery())

        #expect(inFirst.map(\.id) == [firstSession.id])
        #expect(inSecond.map(\.id) == [secondSession.id])
        await Self.close([firstSession, secondSession])
    }

    /// A profile built by hand, with no router that resolved it, registers its
    /// sessions nowhere: not even in the router whose id it records.
    @Test func aHandBuiltProfileSessionRegistersNowhere() async throws {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryRegistrationTests")
        let container = BasicLLMContainer()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: scratch.appendingPathComponent("cache"),
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = HandBuiltProfileFixtures.makeProfile(
            definitionName: "hand-built", chosen: "org/hand-built-llm", container: container, router: router)
        let session = profile.standard.makeSession(configuration: SessionConfiguration())

        let found = try await router.sessionDirectory.sessions(matching: SessionQuery())

        #expect(found.isEmpty)
        #expect(profile.standard.sessionDirectory == nil)
        await Self.close([session])
    }
}
