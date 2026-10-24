import Foundation
import FoundationModelsExtras
import FoundationModelsHooks
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Holds the hook plumbing of the router (task ^qstwwj1): the router gives its
/// `HookDispatcher` to each session, and each session sends `SessionStart`
/// and `SessionEnd` with the `HookSession` that the lineage rules make.
///
/// Each test resolves a stub profile through a router with a dispatcher, and
/// registers a ``RecordingHookVisitor`` on that dispatcher. Each test calls
/// `dispatcher.drain()` before it reads the post events, because a post event
/// arrives on a task of the dispatcher.
///
/// The suite also holds the one lineage function (``HookLineage``) directly,
/// for the comparison of the working directories of a restored fork node of a
/// recording.
@Suite("Hook lineage: the router gives each session its hook session")
struct HookLineageTests {
    // MARK: - Fixtures

    /// The session key that a host gives to a model-switch replacement.
    private static let replacementKey = "k"

    /// The tool call id that the recorded spawn of a sub-agent names.
    private static let spawnToolCallID = "start-agent-call"

    /// A visitor that records each `SessionStart` and each `SessionEnd`, in
    /// the order of delivery.
    final class RecordingHookVisitor: HookVisitor {
        /// One recorded session event.
        enum Event: Equatable {
            /// A `SessionStart` with its session and its origin.
            case start(HookSession, SessionOrigin)
            /// A `SessionEnd` with its session.
            case end(HookSession)

            /// The id of the Router session of the event.
            var sessionID: String {
                switch self {
                case .start(let session, _): session.sessionID
                case .end(let session): session.sessionID
                }
            }
        }

        /// The recorded events.
        private let recorded = Mutex<[Event]>([])

        /// The recorded events, in the order of delivery.
        var events: [Event] {
            recorded.withLock { $0 }
        }

        /// The recorded events of one session, in the order of delivery.
        ///
        /// - Parameter id: The id of the session.
        /// - Returns: The events of that session.
        func events(of id: ULID) -> [Event] {
            events.filter { $0.sessionID == id.description }
        }

        /// Records a `SessionStart`.
        ///
        /// - Parameter context: The session and the event.
        func post(_ context: HookContext<SessionStart>) async {
            recorded.withLock { $0.append(.start(context.session, context.event.origin)) }
        }

        /// Records a `SessionEnd`.
        ///
        /// - Parameter context: The session and the event.
        func post(_ context: HookContext<SessionEnd>) async {
            recorded.withLock { $0.append(.end(context.session)) }
        }
    }

    /// A router with a dispatcher, the profile it resolved, and the visitor
    /// that records the hook events.
    private struct HookedProfile {
        /// The router. A test keeps it alive for its whole length.
        let router: Router

        /// The resolved profile.
        let profile: LanguageModelProfile

        /// The dispatcher of the router.
        let dispatcher: HookDispatcher

        /// The visitor registered on ``dispatcher``.
        let visitor: RecordingHookVisitor

        /// The temporary directory of the test: the cache, the recordings
        /// and the hook data.
        let directory: URL
    }

    /// Resolves the standard stub profile through a router with a
    /// dispatcher, runs `body`, and removes the temporary directory.
    ///
    /// - Parameters:
    ///   - registersVisitor: Whether the dispatcher gets the recording
    ///     visitor. `false` makes a dispatcher with no visitor.
    ///   - body: The test.
    /// - Throws: What the resolve or `body` throws.
    private static func withHookedProfile(
        registersVisitor: Bool = true,
        _ body: (HookedProfile) async throws -> Void
    ) async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "HookLineageTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingsDir = directory.appendingPathComponent("recordings", isDirectory: true)
        let dispatcher = HookDispatcher(
            dataDirectory: directory.appendingPathComponent("hooks", isDirectory: true))
        let visitor = RecordingHookVisitor()
        if registersVisitor {
            dispatcher.register(visitor)
        }
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory, recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension),
            hooks: dispatcher)
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        try await body(
            HookedProfile(
                router: router, profile: profile, dispatcher: dispatcher, visitor: visitor, directory: directory))
    }

    /// The `SessionStart` of one session.
    ///
    /// - Parameters:
    ///   - id: The id of the session.
    ///   - visitor: The visitor that recorded the events.
    /// - Returns: The hook session and the origin of the start.
    /// - Throws: When the visitor recorded no start for the session.
    private static func start(
        of id: ULID, in visitor: RecordingHookVisitor
    ) throws -> (session: HookSession, origin: SessionOrigin) {
        let starts = visitor.events(of: id).compactMap { event -> (HookSession, SessionOrigin)? in
            if case .start(let session, let origin) = event {
                return (session, origin)
            }
            return nil
        }
        #expect(starts.count == 1)
        return try #require(starts.first)
    }

    /// The hook sessions of the resumed `SessionStart` events in `events`.
    ///
    /// - Parameter events: The recorded events.
    /// - Returns: The session of each `SessionStart(.resumed)`, in order.
    private static func resumedSessions(in events: [RecordingHookVisitor.Event]) -> [HookSession] {
        events.compactMap { event in
            if case .start(let session, .resumed) = event {
                return session
            }
            return nil
        }
    }

    // MARK: - No dispatcher

    @Test("a router with no dispatcher gives its sessions no hooks")
    func aRouterWithNoDispatcherGivesNoHooks() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "HookLineageTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: directory)
        let session = profile.standard.makeSession()
        let actor = try #require(session as? RoutedSessionActor)
        #expect(actor.hooks == nil)
        await session.close()
        withExtendedLifetime(router) {}
    }

    @Test("a dispatcher with no visitor gets no session event")
    func aDispatcherWithNoVisitorGetsNoEvent() async throws {
        try await Self.withHookedProfile(registersVisitor: false) { hooked in
            let session = hooked.profile.standard.makeSession()
            #expect(hooked.dispatcher.queuedSessionKeys.isEmpty)
            await session.close()
            await hooked.dispatcher.drain()
            #expect(hooked.dispatcher.queuedSessionKeys.isEmpty)
        }
    }

    // MARK: - SessionStart and SessionEnd

    @Test("a session gives one SessionStart and then one SessionEnd, also after two closes")
    func aSessionGivesOneStartAndOneEnd() async throws {
        try await Self.withHookedProfile { hooked in
            let session = hooked.profile.standard.makeSession()
            await session.close()
            await session.close()
            await hooked.dispatcher.drain()

            let hookSession = HookSession(
                sessionID: session.id.description, sessionKey: session.id.description, parentSessionID: nil,
                workingDirectory: session.workingDirectory, dataDirectory: hooked.dispatcher.dataDirectory)
            #expect(hooked.visitor.events(of: session.id) == [.start(hookSession, .new), .end(hookSession)])
        }
    }

    @Test("a session of the flash slot also gives its SessionStart")
    func aFlashSessionGivesItsStart() async throws {
        try await Self.withHookedProfile { hooked in
            let session = hooked.profile.flash.makeSession()
            await hooked.dispatcher.drain()
            let start = try Self.start(of: session.id, in: hooked.visitor)
            #expect(start.origin == .new)
            await session.close()
        }
    }

    @Test("a session with a hook key and a hook origin gets them")
    func aSessionWithAHookKeyAndOriginGetsThem() async throws {
        try await Self.withHookedProfile { hooked in
            let session = hooked.profile.standard.makeSession(
                configuration: SessionConfiguration(hookSessionKey: Self.replacementKey, hookOrigin: .replacement))
            await hooked.dispatcher.drain()

            let start = try Self.start(of: session.id, in: hooked.visitor)
            #expect(start.session.sessionKey == Self.replacementKey)
            #expect(start.origin == .replacement)
            #expect(start.session.parentSessionID == nil)
            await session.close()
        }
    }

    // MARK: - Child session

    @Test("a child session gets the subagent origin, the key of its parent and the id of its parent")
    func aChildSessionGetsTheKeyOfItsParent() async throws {
        try await Self.withHookedProfile { hooked in
            let parent = hooked.profile.standard.makeSession(
                configuration: SessionConfiguration(hookSessionKey: Self.replacementKey))
            let child = hooked.profile.standard.makeSession(
                configuration: SessionConfiguration(parentCall: .startAgentCall(of: parent)))
            await hooked.dispatcher.drain()

            let start = try Self.start(of: child.id, in: hooked.visitor)
            #expect(start.origin == .subagent)
            #expect(start.session.sessionKey == Self.replacementKey)
            #expect(start.session.parentSessionID == parent.id.description)
            await child.close()
            await parent.close()
        }
    }

    // MARK: - Restore

    @Test("restoreSession gives a resumed SessionStart with the recorded id as the key")
    func restoreSessionGivesAResumedStart() async throws {
        try await Self.withHookedProfile { hooked in
            let recorded = hooked.profile.standard.makeSession()
            await recorded.close()

            let restored = try await hooked.profile.standard.restoreSession(id: recorded.id)
            await hooked.dispatcher.drain()

            let resumed = Self.resumedSessions(in: hooked.visitor.events(of: recorded.id))
            #expect(resumed.count == 1)
            let session = try #require(resumed.first)
            #expect(session.sessionID == recorded.id.description)
            #expect(session.sessionKey == recorded.id.description)
            #expect(session.parentSessionID == nil)
            await restored.session.close()
        }
    }

    @Test("restoreSession with a hook key gives the restored session that key")
    func restoreSessionWithAHookKeyGivesThatKey() async throws {
        try await Self.withHookedProfile { hooked in
            let recorded = hooked.profile.standard.makeSession()
            await recorded.close()

            let restored = try await hooked.profile.standard.restoreSession(
                id: recorded.id, hookSessionKey: Self.replacementKey)
            await hooked.dispatcher.drain()

            let resumed = Self.resumedSessions(in: hooked.visitor.events(of: recorded.id))
            #expect(resumed.count == 1)
            let session = try #require(resumed.first)
            #expect(session.sessionID == recorded.id.description)
            #expect(session.sessionKey == Self.replacementKey)
            #expect(session.parentSessionID == nil)
            await restored.session.close()
        }
    }

    @Test("a restored sub-agent gets the hook key its restored parent was given")
    func aRestoredSubagentGetsTheHookKeyOfItsRestoredParent() async throws {
        try await Self.withHookedProfile { hooked in
            let parent = hooked.profile.standard.makeSession()
            let child = hooked.profile.standard.makeSession(
                configuration: SessionConfiguration(
                    agentSpawn: SessionRecord.AgentSpawn(
                        parentSessionId: parent.id, parentToolCallId: Self.spawnToolCallID)))
            await child.close()
            await parent.close()

            let restoredParent = try await hooked.profile.standard.restoreSession(
                id: parent.id, hookSessionKey: Self.replacementKey)
            let restoredChild = try await hooked.profile.standard.restoreSession(id: child.id)
            await hooked.dispatcher.drain()

            let resumed = Self.resumedSessions(in: hooked.visitor.events(of: child.id))
            #expect(resumed.count == 1)
            let session = try #require(resumed.first)
            #expect(session.sessionKey == Self.replacementKey)
            #expect(session.parentSessionID == parent.id.description)
            await restoredChild.session.close()
            await restoredParent.session.close()
        }
    }

    // MARK: - The lineage function

    @Test("a restored fork node whose directory differs only in its form gets the key of its parent")
    func aRestoredForkNodeInTheSameDirectoryInAnotherFormGetsTheKeyOfItsParent() {
        let directory = URL(fileURLWithPath: "/tmp/hook-lineage/work", isDirectory: true)
        let sameDirectory = URL(fileURLWithPath: "/tmp/hook-lineage/other/../work", isDirectory: false)
        let parent = HookParent.fork(
            sessionID: ULID.generate().description, sessionKey: Self.replacementKey, workingDirectory: directory)
        let lineage = HookLineage.make(
            sessionID: ULID.generate(), workingDirectory: sameDirectory, dataDirectory: directory,
            parent: parent, requestedKey: nil, requestedOrigin: nil, isRestored: false)
        #expect(lineage.session.sessionKey == Self.replacementKey)
        #expect(lineage.origin == .forked)
    }
}
