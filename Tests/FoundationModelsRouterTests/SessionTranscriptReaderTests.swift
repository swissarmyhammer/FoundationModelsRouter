import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the reader of session transcripts that a host gives with
/// ``SessionConfiguration/transcriptReader``. A tool reads a transcript
/// through ``ToolContext/transcript(of:)``, and the router must give the
/// reader to every mount site that it makes: a root session, a session with
/// a recorded spawn, a restored session, a child session of a live parent
/// call, and the session-mount helper.
@Suite("The host reader of transcripts is visible to the tools of every session")
struct SessionTranscriptReaderTests {
    // MARK: - Constants

    /// The prompt that makes the scripted backend call each tool.
    private static let prompt = "record the context"

    /// The name of the tool of the sessions.
    private static let toolName = "record_context"

    /// The call id, in the parent, that started a spawned child.
    private static let spawnCallID = "call-start-child"

    /// The session that the reader knows.
    private static let knownSession = ULID.generate()

    /// The session that the reader does not know.
    private static let unknownSession = ULID.generate()

    /// The transcript that the reader gives for ``knownSession``.
    private static let knownTranscript = SessionTranscript(
        sessionID: knownSession,
        entries: [
            SessionTranscriptEntry(
                kind: "prompt", timestamp: Date(timeIntervalSinceReferenceDate: 1), payload: .string("hello"))
        ])

    // MARK: - Fixtures

    /// A reader that knows one session.
    private struct FixedReader: SessionTranscriptReader {
        func transcript(of sessionID: ULID) async throws -> SessionTranscript {
            guard sessionID == SessionTranscriptReaderTests.knownSession else {
                throw SessionTranscriptError.notFound(sessionID)
            }
            return SessionTranscriptReaderTests.knownTranscript
        }
    }

    /// The reader that the tests give.
    private static let reader: any SessionTranscriptReader = FixedReader()

    /// Runs `body` with a standard profile over a durable recording root.
    private static func withProfile(
        _ body: (LanguageModelProfile) async throws -> Void
    ) async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionTranscriptReaderTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: ToolDrivingLLMContainer(), cacheDir: directory.appendingPathComponent("cache"),
            recordingsDir: directory.appendingPathComponent("recordings"))
        try await body(profile)
        withExtendedLifetime(router) {}
    }

    /// The tool that saves its context in `store`.
    private static func makeTool(saving store: ContextStore) -> ContextRecordingTool {
        ContextRecordingTool(name: toolName, store: store)
    }

    /// Runs one prompt on `session`, and gives the context its tool saw.
    private static func contextOfOneCall(
        on session: any RoutedSession, in store: ContextStore
    ) async throws -> ToolContext {
        _ = try await session.respond(to: prompt)
        return try #require(store.context(of: session.id))
    }

    /// The transcript that the context reads for the known session.
    private static func readKnown(through context: ToolContext) async throws -> SessionTranscript {
        try await context.transcript(of: knownSession)
    }

    // MARK: - Every mount site

    /// The production change that makes this test fail: a root site made
    /// with no reader.
    @Test("a root session gives its tools the reader of the configuration")
    func aRootSessionGivesItsToolsTheReader() async throws {
        try await Self.withProfile { profile in
            let store = ContextStore()
            let session = profile.standard.makeSession(
                configuration: SessionConfiguration(tools: [Self.makeTool(saving: store)], transcriptReader: Self.reader))

            let context = try await Self.contextOfOneCall(on: session, in: store)
            let transcript = try await Self.readKnown(through: context)
            await session.close()

            #expect(transcript == Self.knownTranscript)
        }
    }

    /// The production change that makes this test fail: a recorded-spawn
    /// site made with no reader.
    @Test("a session with a recorded spawn gives its tools the reader of the configuration")
    func aRecordedSpawnGivesItsToolsTheReader() async throws {
        try await Self.withProfile { profile in
            let store = ContextStore()
            let spawn = SessionRecord.AgentSpawn(parentSessionId: ULID.generate(), parentToolCallId: Self.spawnCallID)
            let session = profile.standard.makeSession(
                configuration: SessionConfiguration(
                    tools: [Self.makeTool(saving: store)], agentSpawn: spawn, transcriptReader: Self.reader))

            let context = try await Self.contextOfOneCall(on: session, in: store)
            let transcript = try await Self.readKnown(through: context)
            await session.close()

            #expect(transcript == Self.knownTranscript)
        }
    }

    /// The production change that makes this test fail: a restore that
    /// gives the reader to no node.
    @Test("a restored session gives its tools the reader that the host gives again")
    func aRestoredSessionGivesItsToolsTheReader() async throws {
        try await Self.withProfile { profile in
            let original = profile.standard.makeSession(configuration: SessionConfiguration())
            _ = try await original.respond(to: Self.prompt)
            await original.close()
            let store = ContextStore()

            let restored = try await profile.standard.restoreSession(
                id: original.id, tools: [Self.makeTool(saving: store)], transcriptReader: Self.reader
            ).session
            let context = try await Self.contextOfOneCall(on: restored, in: store)
            let transcript = try await Self.readKnown(through: context)
            await restored.close()

            #expect(transcript == Self.knownTranscript)
        }
    }

    /// The production change that makes this test fail: a child site that
    /// the router makes with no reader of the parent call.
    @Test("a child session of a live parent call gives its tools the reader of the parent")
    func aChildSessionKeepsTheReaderOfItsParent() async throws {
        try await Self.withProfile { profile in
            let store = ContextStore()
            let tool = Self.makeTool(saving: store)
            let parent = profile.standard.makeSession(
                configuration: SessionConfiguration(tools: [tool], transcriptReader: Self.reader))
            let parentCall = try await Self.contextOfOneCall(on: parent, in: store)
            let child = profile.standard.makeSession(
                configuration: SessionConfiguration(tools: [tool], parentCall: parentCall))

            let context = try await Self.contextOfOneCall(on: child, in: store)
            let transcript = try await Self.readKnown(through: context)
            await child.close()
            await parent.close()

            #expect(transcript == Self.knownTranscript)
        }
    }

    /// The production change that makes this test fail: a session-mount
    /// helper that makes its site with no reader.
    @Test("the session-mount helper gives the reader to the site of the tool")
    func theSessionMountHelperGivesTheReader() async throws {
        let store = ContextStore()
        let sessionID = ULID.generate()
        let mounted = ToolMounting.makeSessionMounted(
            tool: Self.makeTool(saving: store), sessionID: sessionID, runPlane: RunPlane(),
            sink: DroppingEventSink(), cappedToTokenLimit: nil, tokenCounter: CharacterTokenCounter(),
            inlineSettleGrace: 0, transcriptReader: Self.reader)
        let tool = try #require([mounted].fixtureTools.first)

        _ = try await tool.call(arguments: BackgroundFixtureArguments(value: "go"))
        let transcript = try await Self.readKnown(through: try #require(store.context(of: sessionID)))

        #expect(transcript == Self.knownTranscript)
    }

    // MARK: - The reader decides

    /// The production change that makes this test fail: a router that gives
    /// a reader of its own when the host gave none.
    @Test("a session with no reader gives its tools the no-source error")
    func aSessionWithNoReaderGivesNoSource() async throws {
        try await Self.withProfile { profile in
            let store = ContextStore()
            let session = profile.standard.makeSession(
                configuration: SessionConfiguration(tools: [Self.makeTool(saving: store)]))

            let context = try await Self.contextOfOneCall(on: session, in: store)
            await session.close()

            await #expect(throws: SessionTranscriptError.noSource) {
                _ = try await Self.readKnown(through: context)
            }
        }
    }

    /// The production change that makes this test fail: a router that
    /// replaces the error of the reader for an id that it does not know.
    @Test("an id that the reader does not know gives the not-found error of the reader")
    func anUnknownIDGivesNotFound() async throws {
        try await Self.withProfile { profile in
            let store = ContextStore()
            let session = profile.standard.makeSession(
                configuration: SessionConfiguration(tools: [Self.makeTool(saving: store)], transcriptReader: Self.reader))

            let context = try await Self.contextOfOneCall(on: session, in: store)
            await session.close()

            await #expect(throws: SessionTranscriptError.notFound(Self.unknownSession)) {
                _ = try await context.transcript(of: Self.unknownSession)
            }
        }
    }
}
