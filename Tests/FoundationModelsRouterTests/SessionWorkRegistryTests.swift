import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the work registry of each session: each session owns one
/// `WorkRegistry` under its own id. Its run plane and the mount site of each
/// of its tools hold that registry, so each lease of a tool of the session
/// goes into it. A restored session owns a registry of its own,
/// and the registry of a session is never shared. ``RoutedSession/close()``
/// closes it.
///
/// Everything runs against the scripted ``BackgroundingBackend``, so the
/// suite needs no network and no GPU.
@Suite("Each session owns one work registry")
struct SessionWorkRegistryTests {
    // MARK: - Helpers

    /// Makes a session with `tools` over a ``BackgroundingBackend``.
    ///
    /// - Parameter tools: The tools of the session.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(tools: [any Tool] = []) async throws -> BackgroundingSessionFixture {
        try await BackgroundingSessionFixture.make(prefix: "SessionWorkRegistryTests", tools: tools)
    }

    /// The registry of `session`.
    ///
    /// - Parameter session: A session of the router.
    /// - Returns: The registry of the run plane of the session.
    static func registry(of session: any RoutedSession) -> WorkRegistry {
        session.runPlane.workRegistry
    }

    // MARK: - Tests

    @Test("a vended session owns a registry under its own id, and its run plane holds it")
    func aVendedSessionOwnsItsRegistry() async throws {
        let fixture = try await Self.makeFixture()
        defer { await fixture.end() }

        #expect(Self.registry(of: fixture.session).sessionID == fixture.session.id)
        #expect(Self.registry(of: fixture.session).hasWork == false)
    }

    @Test("a lease of a tool call goes into the registry of the session of the call")
    func aToolLeaseGoesIntoTheRegistryOfItsSession() async throws {
        let fixture = try await Self.makeFixture(tools: [LeaseHoldingTool()])
        defer { await fixture.end() }

        _ = try await fixture.session.respond(to: "hold one lease")

        let held = try #require(LeaseHoldingTool.held.withLock { $0 }[fixture.session.id])
        #expect(held.sessionID == fixture.session.id)
        #expect(Self.registry(of: fixture.session).openWork == [held.item])
        held.end()
        #expect(Self.registry(of: fixture.session).hasWork == false)
    }

    @Test("a session with a parent call mounts its tools on the child site of that call, with its own registry")
    func aChildSessionMountsOnTheChildSiteOfItsParentCall() async throws {
        let parentRegistry = WorkRegistry(sessionID: ULID())
        let root = ToolContext(
            sessionID: parentRegistry.sessionID, runPlane: RunPlane(workRegistry: parentRegistry),
            sink: DroppingEventSink(), tool: "agents", op: "start agent",
            completionToken: ToolContext.makeCompletionToken(), isCancelled: { false })
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: "SessionWorkRegistryTests", tools: [LeaseHoldingTool()], parentCall: root)
        defer { await fixture.end() }

        _ = try await fixture.session.respond(to: "hold one lease")

        let held = try #require(LeaseHoldingTool.held.withLock { $0 }[fixture.session.id])
        let context = try #require(LeaseHoldingTool.contexts.withLock { $0 }[fixture.session.id])
        #expect(context.parentSessionID == parentRegistry.sessionID)
        #expect(context.rootSessionID == parentRegistry.sessionID)
        #expect(held.sessionID == fixture.session.id)
        #expect(Self.registry(of: fixture.session).openWork == [held.item])
        #expect(parentRegistry.hasWork == false)
        held.end()
    }

    @Test("a session with no parent call is the root of its tree")
    func aSessionWithNoParentCallIsARoot() async throws {
        let fixture = try await Self.makeFixture(tools: [LeaseHoldingTool()])
        defer { await fixture.end() }

        _ = try await fixture.session.respond(to: "hold one lease")

        let held = try #require(LeaseHoldingTool.held.withLock { $0 }[fixture.session.id])
        let context = try #require(LeaseHoldingTool.contexts.withLock { $0 }[fixture.session.id])
        #expect(context.parentSessionID == nil)
        #expect(context.rootSessionID == fixture.session.id)
        held.end()
    }

    @Test("close closes the registry of the session, and a lease after the close is no work")
    func closeClosesTheRegistry() async throws {
        let fixture = try await Self.makeFixture()
        let registry = Self.registry(of: fixture.session)
        await fixture.end()

        #expect(registry.isClosed)
        let late = registry.begin(.backgroundRun, id: "late")
        #expect(registry.hasWork == false)
        late.end()
    }
}

/// A tool that begins one `WorkKind/shellCommand` lease through the context
/// of its call, keeps it open, and answers at once. A test reads the lease
/// from ``held`` by the id of the session of the call, and ends it.
struct LeaseHoldingTool: Tool {
    let name = "lease_holding_job"
    let description = "test-only tool that begins one background lease and keeps it open"

    /// The lease of the last call of each session, by the id of the session.
    static let held = Mutex<[ULID: BackgroundWork]>([:])

    /// The context of the last call of each session, by the id of the
    /// session.
    static let contexts = Mutex<[ULID: ToolContext]>([:])

    func call(arguments: BackgroundFixtureArguments) async throws -> String {
        guard let context = ToolContext.current else { return "no context" }
        let lease = context.beginBackgroundWork(.shellCommand, id: "held")
        Self.held.withLock { $0[context.sessionID] = lease }
        Self.contexts.withLock { $0[context.sessionID] = context }
        return "held"
    }
}

/// A sink that drops each event, for a parent call with no session.
struct DroppingEventSink: OperationEventSink {
    func post(event: OperationEvent) async {}
}
