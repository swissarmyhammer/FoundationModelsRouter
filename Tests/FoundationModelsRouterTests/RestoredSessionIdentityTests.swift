import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises the identity of a restored sub-agent session: its parent session
/// id, its root session id and the id of the call that started it. A restore
/// gives the tools of the session the same ids as before the stop, and the
/// ids come from the record, never from the host.
///
/// The sub-agent sessions are written flat, as top-level session folders with
/// ``SessionRecord/AgentSpawn`` set, as the host writes them. So
/// ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:)``
/// restores each level by its own id.
@Suite("A restored sub-agent session keeps its identity")
struct RestoredSessionIdentityTests {
    // MARK: - Constants

    /// The prompt that makes the scripted backend call each tool.
    private static let prompt = "record the context"

    /// The tool-call id, in the root, that started the child.
    private static let childCallID = "call-start-child"

    /// The tool-call id, in the child, that started the grandchild.
    private static let grandchildCallID = "call-start-grandchild"

    /// The name of the tool of the sessions before the stop.
    private static let originalToolName = "record_context"

    /// The name of the tool the host gives on a restore.
    private static let replacementToolName = "record_context_replacement"

    // MARK: - Fixtures

    /// The ids that a tool saw in its `ToolContext`.
    private struct Identity: Equatable {
        /// ``ToolContext/parentSessionID``.
        let parent: ULID?

        /// ``ToolContext/rootSessionID``.
        let root: ULID
    }

    /// The `ToolContext` of the last call of each session, by session id.
    private final class ContextStore: Sendable {
        private let contexts = Mutex<[ULID: ToolContext]>([:])

        /// Saves the context of one call.
        func save(_ context: ToolContext) {
            contexts.withLock { $0[context.sessionID] = context }
        }

        /// The context of the last call of `session`, or `nil` when there was none.
        func context(of session: ULID) -> ToolContext? {
            contexts.withLock { $0[session] }
        }

        /// The ids of the last call of `session`.
        func identity(of session: ULID) throws -> Identity {
            let context = try #require(context(of: session))
            return Identity(parent: context.parentSessionID, root: context.rootSessionID)
        }
    }

    /// A tool that saves the `ToolContext` of each call in a store.
    private struct ContextRecordingTool: Tool {
        let name: String
        let description = "test-only tool that saves the context of its call"
        let store: ContextStore

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            if let context = ToolContext.current { store.save(context) }
            return "recorded"
        }
    }

    /// A container whose backend calls each tool, also for a restored session.
    private final class ToolDrivingContainer: LoadedLLMContainer {
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeSession(instructions: instructions, tools: [])
        }

        func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
            BackgroundingBackend(tools: tools)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            makeSession(transcript: transcript, tools: [])
        }

        func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
            BackgroundingBackend(tools: tools)
        }
    }

    /// The three sessions of a chain, root to grandchild.
    private struct Chain {
        let root: any RoutedSession
        let child: any RoutedSession
        let grandchild: any RoutedSession

        /// The ids of the sessions, root to grandchild.
        var ids: [ULID] { [root.id, child.id, grandchild.id] }
    }

    /// Runs `body` with a standard profile over a durable recording root.
    private static func withProfile(
        _ body: (LanguageModelProfile, URL) async throws -> Void
    ) async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "RestoredSessionIdentityTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordings = directory.appendingPathComponent("recordings")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: ToolDrivingContainer(), cacheDir: directory.appendingPathComponent("cache"),
            recordingsDir: recordings)
        try await body(profile, recordings)
        withExtendedLifetime(router) {}
    }

    /// Makes a chain of three sessions. Each child starts with the context of
    /// a real tool call of its parent, and the spawn record of the host.
    private static func makeChain(on profile: LanguageModelProfile, store: ContextStore) async throws -> Chain {
        let tool = ContextRecordingTool(name: originalToolName, store: store)
        let root = profile.standard.makeSession(configuration: SessionConfiguration(tools: [tool]))
        _ = try await root.respond(to: prompt)
        let rootCall: ToolContext = try #require(store.context(of: root.id))
        let child = profile.standard.makeSession(
            configuration: SessionConfiguration(
                tools: [tool],
                agentSpawn: SessionRecord.AgentSpawn(parentSessionId: root.id, parentToolCallId: childCallID),
                parentCall: rootCall))
        _ = try await child.respond(to: prompt)
        let childCall: ToolContext = try #require(store.context(of: child.id))
        let grandchild = profile.standard.makeSession(
            configuration: SessionConfiguration(
                tools: [tool],
                agentSpawn: SessionRecord.AgentSpawn(parentSessionId: child.id, parentToolCallId: grandchildCallID),
                parentCall: childCall))
        _ = try await grandchild.respond(to: prompt)
        return Chain(root: root, child: child, grandchild: grandchild)
    }

    /// Closes the chain, then restores each level with a replacement tool and
    /// runs it, so the replacement tool saves the context of each level.
    ///
    /// - Returns: The restored sessions, root to grandchild.
    private static func restoreWithReplacementTool(
        _ chain: Chain, on profile: LanguageModelProfile, store: ContextStore
    ) async throws -> [any RoutedSession] {
        for session in [chain.grandchild, chain.child, chain.root] { await session.close() }
        let tool = ContextRecordingTool(name: replacementToolName, store: store)
        var restored: [any RoutedSession] = []
        for id in chain.ids {
            let session = try await profile.standard.restoreSession(id: id, tools: [tool]).session
            _ = try await session.respond(to: Self.prompt)
            restored.append(session)
        }
        return restored
    }

    // MARK: - A chain of three sessions

    /// The production change that makes this test fail: a restore that makes
    /// a sub-agent session a root, so its tools see no parent.
    @Test("a chain of three sessions: the tools see the same parent session id at every level after a restore")
    func theParentSessionIDIsTheSameAtEveryLevel() async throws {
        try await Self.withProfile { profile, _ in
            let original = ContextStore()
            let restoredStore = ContextStore()
            let chain = try await Self.makeChain(on: profile, store: original)
            let before = try chain.ids.map { try original.identity(of: $0).parent }
            let restored = try await Self.restoreWithReplacementTool(chain, on: profile, store: restoredStore)

            let after = try chain.ids.map { try restoredStore.identity(of: $0).parent }
            for session in restored { await session.close() }

            #expect(after == before)
        }
    }

    /// The production change that makes this test fail: a restore that makes
    /// the root of each restored session its own id.
    @Test("a chain of three sessions: the tools see the same root session id at every level after a restore")
    func theRootSessionIDIsTheSameAtEveryLevel() async throws {
        try await Self.withProfile { profile, _ in
            let original = ContextStore()
            let restoredStore = ContextStore()
            let chain = try await Self.makeChain(on: profile, store: original)
            let before = try chain.ids.map { try original.identity(of: $0).root }
            let restored = try await Self.restoreWithReplacementTool(chain, on: profile, store: restoredStore)

            let after = try chain.ids.map { try restoredStore.identity(of: $0).root }
            for session in restored { await session.close() }

            #expect(after == before)
        }
    }

    /// The production change that makes this test fail: a restore that drops
    /// the recorded spawn, so the completion token of the call is lost.
    @Test("a restored sub-agent session holds the recorded id of the call that started it")
    func theRestoredSessionHoldsTheRecordedCallID() async throws {
        try await Self.withProfile { profile, _ in
            let chain = try await Self.makeChain(on: profile, store: ContextStore())
            let restored = try await Self.restoreWithReplacementTool(chain, on: profile, store: ContextStore())

            let callIDs = try restored.map { try #require($0 as? RoutedSessionActor).agentSpawn?.parentToolCallId }
            for session in restored { await session.close() }

            #expect(callIDs == [nil, Self.childCallID, Self.grandchildCallID])
        }
    }

    // MARK: - A restore of a root

    /// The production change that makes this test fail: a restore that gives
    /// a root session a parent.
    @Test("a restored root session has no parent and is its own root")
    func aRestoredRootIsItsOwnRoot() async throws {
        try await Self.withProfile { profile, _ in
            let store = ContextStore()
            let chain = try await Self.makeChain(on: profile, store: ContextStore())
            let restored = try await Self.restoreWithReplacementTool(chain, on: profile, store: store)

            let identity = try store.identity(of: chain.root.id)
            for session in restored { await session.close() }

            #expect(identity == Identity(parent: nil, root: chain.root.id))
        }
    }

    // MARK: - A fresh sub-agent session with a recorded spawn

    /// The production change that makes this test fail: a fresh session whose
    /// tools are mounted on the root site when it has a spawn record and no
    /// parent call, so the tools see no parent and no root.
    @Test("a fresh session with a spawn record and no parent call gives its tools the ids that a restore gives")
    func aFreshSessionTakesItsIdsFromTheSpawnRecord() async throws {
        try await Self.withProfile { profile, _ in
            let parent = ULID.generate()
            let freshStore = ContextStore()
            let restoredStore = ContextStore()
            let spawn = SessionRecord.AgentSpawn(parentSessionId: parent, parentToolCallId: Self.childCallID)
            let tool = ContextRecordingTool(name: Self.originalToolName, store: freshStore)
            let fresh = profile.standard.makeSession(
                configuration: SessionConfiguration(tools: [tool], agentSpawn: spawn))
            _ = try await fresh.respond(to: Self.prompt)
            let before = try freshStore.identity(of: fresh.id)
            await fresh.close()

            let replacement = ContextRecordingTool(name: Self.replacementToolName, store: restoredStore)
            let restored = try await profile.standard.restoreSession(id: fresh.id, tools: [replacement]).session
            _ = try await restored.respond(to: Self.prompt)
            let after = try restoredStore.identity(of: fresh.id)
            await restored.close()

            #expect(before == Identity(parent: parent, root: parent))
            #expect(after == before)
        }
    }

    // MARK: - A parent that is not restored

    /// The production change that makes this test fail: a restore that needs
    /// the record or the live session of the parent for the identity.
    @Test("a sub-agent session restores with its recorded ids when the folder of its parent is gone")
    func aRestoreNeedsNoParentRecord() async throws {
        try await Self.withProfile { profile, recordings in
            let original = ContextStore()
            let restoredStore = ContextStore()
            let chain = try await Self.makeChain(on: profile, store: original)
            let before = try original.identity(of: chain.grandchild.id)
            for session in [chain.grandchild, chain.child, chain.root] { await session.close() }
            for gone in [chain.child.id, chain.root.id] {
                let folder = try #require(try TranscriptTree.sessionFolder(of: gone, under: recordings))
                try FileManager.default.removeItem(at: folder)
            }

            let tool = ContextRecordingTool(name: Self.replacementToolName, store: restoredStore)
            let restored = try await profile.standard.restoreSession(id: chain.grandchild.id, tools: [tool]).session
            _ = try await restored.respond(to: Self.prompt)
            let after = try restoredStore.identity(of: chain.grandchild.id)
            await restored.close()

            #expect(after == before)
        }
    }
}
