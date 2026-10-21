import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The live query of ``RouterSessionDirectory`` (ROUTER-3): the directory
/// holds each registered session weakly, and `sessions(matching:)` and
/// `summary(of:)` answer from the live sessions, newest first.
///
/// Each test vends its sessions from a scripted model, then registers each one
/// again by hand with the kind and parent the test needs: a second
/// registration of an id replaces the one `makeSession` made.
@Suite struct RouterSessionDirectoryQueryTests {
    /// A scripted profile and a directory to register its sessions in.
    struct Fixture {
        /// The router that resolved ``profile``. It owns ``directory``.
        let router: Router

        /// The resolved scripted profile the sessions come from.
        let profile: LanguageModelProfile

        /// A temporary directory for working folders. The OS reclaims it.
        let scratch: URL

        /// The directory under test: the router's own.
        var directory: RouterSessionDirectory { router.sessionDirectory }

        /// Vends one session with `configuration` and registers it again with
        /// `kind` and `parentID`.
        ///
        /// - Parameters:
        ///   - configuration: The configuration of the session.
        ///   - kind: The kind the directory records.
        ///   - parentID: The parent the directory records.
        /// - Returns: The vended session.
        func vend(
            _ configuration: SessionConfiguration = SessionConfiguration(),
            kind: SessionKind = .root,
            parentID: ULID? = nil
        ) -> any RoutedSession {
            let session = profile.standard.makeSession(configuration: configuration)
            directory.register(session, kind: kind, parentID: parentID)
            return session
        }
    }

    /// Makes a fixture over a scripted profile.
    private static func makeFixture() async throws -> Fixture {
        let scratch = RouterTestFixtures.makeTempDir(prefix: "RouterSessionDirectoryQueryTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: scratch.appendingPathComponent("cache"))
        return Fixture(router: router, profile: profile, scratch: scratch)
    }

    /// Closes each session in `sessions`.
    private static func close(_ sessions: [any RoutedSession]) async {
        for session in sessions {
            await session.close()
        }
    }

    /// The ids of `summaries`, in order.
    private static func ids(_ summaries: [SessionSummary]) -> [ULID] {
        summaries.map(\.id)
    }

    /// The ids of `sessions`, newest first.
    private static func newestFirst(_ sessions: [any RoutedSession]) -> [ULID] {
        sessions.map(\.id).sorted(by: >)
    }

    // MARK: - Order and limit

    /// Two registered sessions both come back from an empty query, newest
    /// first.
    @Test func anEmptyQueryGivesEachLiveSessionNewestFirst() async throws {
        let fixture = try await Self.makeFixture()
        let sessions = [fixture.vend(), fixture.vend()]

        let found = try await fixture.directory.sessions(matching: SessionQuery())

        #expect(Self.ids(found) == Self.newestFirst(sessions))
        await Self.close(sessions)
    }

    /// The result is cut to the limit, after the newest-first order.
    @Test func theResultIsCutToTheLimit() async throws {
        let fixture = try await Self.makeFixture()
        let sessions = [fixture.vend(), fixture.vend(), fixture.vend()]

        let found = try await fixture.directory.sessions(matching: SessionQuery(limit: 2))

        #expect(Self.ids(found) == Array(Self.newestFirst(sessions).prefix(2)))
        await Self.close(sessions)
    }

    // MARK: - Filters

    /// The working folder filter selects only the sessions in that folder.
    @Test func theWorkingDirectoryFilterSelectsTheSessionsInThatFolder() async throws {
        let fixture = try await Self.makeFixture()
        let folder = fixture.scratch.appendingPathComponent("project", isDirectory: true)
        let other = fixture.scratch.appendingPathComponent("other", isDirectory: true)
        let inFolder = fixture.vend(SessionConfiguration(workingDirectory: folder))
        let elsewhere = fixture.vend(SessionConfiguration(workingDirectory: other))

        let found = try await fixture.directory.sessions(matching: SessionQuery(workingDirectory: folder))

        #expect(Self.ids(found) == [inFolder.id])
        await Self.close([inFolder, elsewhere])
    }

    /// The folder comparison follows a symbolic link and ignores a trailing
    /// `/`.
    @Test func theFolderComparisonFollowsALinkAndIgnoresATrailingSlash() async throws {
        let fixture = try await Self.makeFixture()
        let folder = fixture.scratch.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = fixture.scratch.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let session = fixture.vend(SessionConfiguration(workingDirectory: folder))

        let throughLink = try await fixture.directory.sessions(matching: SessionQuery(workingDirectory: link))
        let withSlash = try await fixture.directory.sessions(
            matching: SessionQuery(workingDirectory: URL(fileURLWithPath: folder.path + "/")))

        #expect(Self.ids(throughLink) == [session.id])
        #expect(Self.ids(withSlash) == [session.id])
        await Self.close([session])
    }

    /// The agent filter selects only the sessions of that agent.
    @Test func theAgentFilterSelectsTheSessionsOfThatAgent() async throws {
        let fixture = try await Self.makeFixture()
        let reviewer = fixture.vend(SessionConfiguration(agentID: "reviewer"))
        let writer = fixture.vend(SessionConfiguration(agentID: "writer"))

        let found = try await fixture.directory.sessions(matching: SessionQuery(agentID: "reviewer"))

        #expect(Self.ids(found) == [reviewer.id])
        await Self.close([reviewer, writer])
    }

    /// The tag filter selects only the sessions that have the tag.
    @Test func theTagFilterSelectsTheSessionsWithTheTag() async throws {
        let fixture = try await Self.makeFixture()
        let tagged = fixture.vend(SessionConfiguration(tags: ["kanban", "review"]))
        let untagged = fixture.vend(SessionConfiguration(tags: ["other"]))

        let found = try await fixture.directory.sessions(matching: SessionQuery(tag: "kanban"))

        #expect(Self.ids(found) == [tagged.id])
        await Self.close([tagged, untagged])
    }

    /// The kind filter selects only the sessions of that kind.
    @Test func theKindFilterSelectsTheSessionsOfThatKind() async throws {
        let fixture = try await Self.makeFixture()
        let root = fixture.vend()
        let subagent = fixture.vend(kind: .subagent, parentID: root.id)

        let found = try await fixture.directory.sessions(matching: SessionQuery(kind: .subagent))

        #expect(Self.ids(found) == [subagent.id])
        await Self.close([subagent, root])
    }

    /// The state filter selects by work state: each live session is idle
    /// until the directory reports work states (ROUTER-9).
    @Test func theStateFilterSelectsByWorkState() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.vend()

        let idle = try await fixture.directory.sessions(matching: SessionQuery(state: .idle))
        let working = try await fixture.directory.sessions(matching: SessionQuery(state: .working))

        #expect(Self.ids(idle) == [session.id])
        #expect(working.isEmpty)
        await Self.close([session])
    }

    /// The parent filter selects only the children of that parent.
    @Test func theParentFilterSelectsTheChildrenOfThatParent() async throws {
        let fixture = try await Self.makeFixture()
        let parent = fixture.vend()
        let child = fixture.vend(kind: .fork, parentID: parent.id)

        let found = try await fixture.directory.sessions(matching: SessionQuery(parentID: parent.id))

        #expect(Self.ids(found) == [child.id])
        await Self.close([child, parent])
    }

    /// The started-by filter selects only the sessions that session started.
    @Test func theStartedByFilterSelectsTheSessionsThatSessionStarted() async throws {
        let fixture = try await Self.makeFixture()
        let starter = fixture.vend()
        let started = fixture.vend(SessionConfiguration(startedBy: starter.id))

        let found = try await fixture.directory.sessions(matching: SessionQuery(startedBy: starter.id))

        #expect(Self.ids(found) == [started.id])
        await Self.close([started, starter])
    }

    // MARK: - Summary

    /// `summary(of:)` gives `nil` for an id no live session has.
    @Test func theSummaryOfAnUnknownIdIsNil() async throws {
        let fixture = try await Self.makeFixture()

        let summary = try await fixture.directory.summary(of: ULID.generate())

        #expect(summary == nil)
    }

    /// A summary carries the facts of the session and the registered kind
    /// and parent.
    @Test func aSummaryCarriesTheFactsKindAndParent() async throws {
        let fixture = try await Self.makeFixture()
        let parent = fixture.vend()
        let folder = fixture.scratch.appendingPathComponent("project", isDirectory: true)
        let starter = ULID.generate()
        let session = fixture.vend(
            SessionConfiguration(
                workingDirectory: folder, agentID: "reviewer", agentName: "Reviewer", tags: ["kanban"],
                title: "Review", startedBy: starter, origin: FoundationModelsExtras.SessionDirectoryOrigin.tool),
            kind: .subagent, parentID: parent.id)

        let summary = try #require(try await fixture.directory.summary(of: session.id))

        #expect(summary.agentID == "reviewer")
        #expect(summary.agentName == "Reviewer")
        #expect(summary.workingDirectory == folder)
        #expect(summary.title == "Review")
        #expect(summary.tags == ["kanban"])
        #expect(summary.kind == .subagent)
        #expect(summary.parentID == parent.id)
        #expect(summary.startedBy == starter)
        #expect(summary.origin == .tool)
        #expect(summary.state == .idle)
        #expect(summary.isLive)
        await Self.close([session, parent])
    }

    /// A session with no agent and no origin maps to the agent `default` and
    /// the origin `client`; `createdAt` is the time of its ULID and
    /// `updatedAt` starts there.
    @Test func theFieldMappingFillsTheRequiredFields() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.vend()

        let summary = try #require(try await fixture.directory.summary(of: session.id))

        #expect(summary.agentID == "default")
        #expect(summary.origin == .client)
        #expect(summary.createdAt == session.id.timestamp)
        #expect(summary.updatedAt == summary.createdAt)
        await Self.close([session])
    }

    // MARK: - Weak hold

    /// The directory holds a session weakly: with its last strong reference
    /// gone, it leaves the live list.
    @Test func aReleasedSessionLeavesTheLiveList() async throws {
        let fixture = try await Self.makeFixture()
        var id: ULID?
        do {
            let session = fixture.vend()
            id = session.id
            await session.close()
        }
        let releasedId = try #require(id)

        let found = try await fixture.directory.sessions(matching: SessionQuery())
        let summary = try await fixture.directory.summary(of: releasedId)

        #expect(found.isEmpty)
        #expect(summary == nil)
    }

    /// `unregister` takes a live session off the list.
    @Test func anUnregisteredSessionLeavesTheLiveList() async throws {
        let fixture = try await Self.makeFixture()
        let session = fixture.vend()

        fixture.directory.unregister(session.id)
        let found = try await fixture.directory.sessions(matching: SessionQuery())

        #expect(found.isEmpty)
        await Self.close([session])
    }
}
