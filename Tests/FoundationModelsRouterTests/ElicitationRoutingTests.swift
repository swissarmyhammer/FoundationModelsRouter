import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task e6wb8ak: the ``RoutedSession``-level elicitation reply
/// surface — ``RoutedSession/respond(elicitationId:response:)`` and
/// ``RoutedSession/complete(elicitationId:)`` — routing an app host's answer
/// through the session's own ``SessionMailbox`` to the parked
/// ``ToolContext/elicit(_:)`` continuation.
///
/// The route uses no task locals: session → that session's mailbox → the
/// pending entry → its continuation, references the whole way, so answering
/// through one session can never resume another session's elicitation.
///
/// Everything runs against stubs — a plain ``StubSessionBackend`` and an
/// ``InMemoryRecorder`` — so the suite needs no network and no GPU.
@Suite("RoutedSession elicitation replies: respond and complete")
struct ElicitationRoutingTests {
    // MARK: - Stub scaffolding (real sessions over a stub backend)

    private final class BasicLLMContainer: PlainTranscriptStubContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: "stub response")
        }
    }

    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    private struct StubModelLoader: ModelLoader {
        let container: any LoadedLLMContainer
        let dimension: Int

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return container
        }

        func loadEmbedder(
            ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return StubEmbeddingContainer(dimension: dimension)
        }

        func preload(container: any LoadedModelContainer) async throws {}
    }

    /// A sink that drops every posted event — these tests observe the
    /// mailbox and the resumed continuation, never the outbound event chain.
    private struct DiscardingSink: OperationEventSink {
        func post(_ event: OperationEvent) async {}
    }

    private static let configJSON = Data("""
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    private static let treeJSON = Data("""
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    private static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElicitationRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a fresh router + resolved profile + vended session over a plain
    /// stub backend, recording through an ``InMemoryRecorder``.
    private static func makeSession() async throws -> (session: RoutedSession, dir: URL) {
        let dir = makeTempDir()
        let router = Router(
            cacheDir: dir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)),
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: 8)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return (profile.standard.makeSession(), dir)
    }

    // MARK: - Elicitation scaffolding

    /// Polls until `condition` holds, yielding between checks, so a test can
    /// wait for an `elicit(_:)` task to register its continuation without
    /// racing it.
    private static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await condition()
    }

    private static func formRequest(elicitationId: ULID) -> ElicitationRequest {
        ElicitationRequest(
            message: "name?",
            elicitationId: elicitationId,
            requestedSchema: ElicitationRequestedSchema(properties: [
                "name": .string(ElicitationStringSchema())
            ])
        )
    }

    private static func urlRequest(elicitationId: ULID) throws -> ElicitationRequest {
        ElicitationRequest(
            message: "open this",
            elicitationId: elicitationId,
            url: try #require(URL(string: "https://example.com/flow"))
        )
    }

    /// Binds a ``ToolContext`` over `session`'s own mailbox — the same shape
    /// the invoker binds around a wrapped tool call — so a test can park a
    /// real ``ToolContext/elicit(_:)`` continuation on the session.
    private static func makeContext(for session: RoutedSession) -> ToolContext {
        ToolContext(
            sessionID: session.id,
            mailbox: session.mailbox,
            sink: DiscardingSink(),
            tool: "fake",
            op: "ask user",
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { false }
        )
    }

    /// Parks a real `elicit(_:)` on `session` and waits until its pending
    /// entry is registered, returning the task that resumes with the answer.
    private static func parkElicitation(
        _ request: ElicitationRequest,
        on session: RoutedSession
    ) async -> Task<ElicitationResponse, Error> {
        let context = makeContext(for: session)
        let answering = Task { try await context.elicit(request) }
        #expect(
            await eventually {
                await session.mailbox.pendingElicitationIds().contains(request.elicitationId)
            }
        )
        return answering
    }

    // MARK: - Form-mode round trip

    @Test("a parked ToolContext.elicit resumes when respond() is called on the session, with the exact response passed through")
    @MainActor
    func formRoundTripThroughSessionRespond() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let elicitationId = ULID.generate()
        let answering = await Self.parkElicitation(Self.formRequest(elicitationId: elicitationId), on: session)

        let answer = ElicitationResponse.accept(content: ["name": .string("Ada")])
        #expect(await session.respond(elicitationId: elicitationId.description, response: answer) == .delivered)
        #expect(try await answering.value == answer)
        #expect(await session.mailbox.pendingElicitationIds().isEmpty)

        // A second respond addresses an already-answered id: a safe no-op.
        #expect(await session.respond(elicitationId: elicitationId.description, response: .decline) == .noPendingElicitation)
    }

    @Test("respond(.decline) resumes the run with .decline — a declined elicitation is not a cancelled run")
    @MainActor
    func declineResumesWithDeclineNotCancel() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let elicitationId = ULID.generate()
        let answering = await Self.parkElicitation(Self.formRequest(elicitationId: elicitationId), on: session)

        #expect(await session.respond(elicitationId: elicitationId.description, response: .decline) == .delivered)
        #expect(try await answering.value == .decline)
    }

    // MARK: - URL-mode two-step

    @Test("URL mode: after respond(.accept) the run is still parked; it resumes only on complete(); a duplicate complete is a no-op")
    @MainActor
    func urlTwoStepThroughSessionSurface() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let elicitationId = ULID.generate()
        let answering = await Self.parkElicitation(try Self.urlRequest(elicitationId: elicitationId), on: session)

        // The accept only means the user agreed to open the URL — the entry
        // stays open and the run stays parked.
        #expect(await session.respond(elicitationId: elicitationId.description, response: .accept(content: nil)) == .acceptedAwaitingCompletion)
        #expect(await session.mailbox.pendingElicitationIds() == [elicitationId])

        // The out-of-band flow's completion is what resumes the run.
        #expect(await session.complete(elicitationId: elicitationId.description) == .completed)
        #expect(try await answering.value == .accept(content: nil))
        #expect(await session.mailbox.pendingElicitationIds().isEmpty)

        // A duplicate complete is a safe no-op.
        #expect(await session.complete(elicitationId: elicitationId.description) == .noPendingElicitation)
    }

    // MARK: - Independence and no-ops

    @Test("two pending elicitations on one run resolve independently: responding to one leaves the other parked")
    @MainActor
    func doubleElicitResolvesIndependently() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstId = ULID.generate()
        let secondId = ULID.generate()
        let context = Self.makeContext(for: session)
        let firstAnswering = Task { try await context.elicit(Self.formRequest(elicitationId: firstId)) }
        let secondAnswering = Task { try await context.elicit(Self.formRequest(elicitationId: secondId)) }
        #expect(
            await Self.eventually {
                await session.mailbox.pendingElicitationIds().count == 2
            }
        )

        let firstAnswer = ElicitationResponse.accept(content: ["name": .string("Ada")])
        #expect(await session.respond(elicitationId: firstId.description, response: firstAnswer) == .delivered)
        #expect(try await firstAnswering.value == firstAnswer)

        // The other elicitation is untouched: still parked, still pending.
        #expect(await session.mailbox.pendingElicitationIds() == [secondId])

        #expect(await session.respond(elicitationId: secondId.description, response: .decline) == .delivered)
        #expect(try await secondAnswering.value == .decline)
    }

    @Test("unknown-id and malformed-id respond()/complete() are safe no-ops")
    @MainActor
    func unknownAndMalformedIdsAreNoOps() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let unknown = ULID.generate().description
        #expect(await session.respond(elicitationId: unknown, response: .decline) == .noPendingElicitation)
        #expect(await session.complete(elicitationId: unknown) == .noPendingElicitation)

        // An id that is not even a ULID routes nowhere rather than trapping.
        #expect(await session.respond(elicitationId: "not-a-ulid", response: .decline) == .noPendingElicitation)
        #expect(await session.complete(elicitationId: "not-a-ulid") == .noPendingElicitation)
    }

    @Test("cross-session isolation: respond on session A never resumes session B's elicitation")
    @MainActor
    func respondNeverCrossesSessions() async throws {
        let (sessionA, dirA) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dirA) }
        let (sessionB, dirB) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dirB) }

        let elicitationId = ULID.generate()
        let answering = await Self.parkElicitation(Self.formRequest(elicitationId: elicitationId), on: sessionB)

        // Session A knows nothing about B's elicitation: the answer is a
        // no-op there, and B's run stays parked.
        #expect(await sessionA.respond(elicitationId: elicitationId.description, response: .decline) == .noPendingElicitation)
        #expect(await sessionA.complete(elicitationId: elicitationId.description) == .noPendingElicitation)
        #expect(await sessionB.mailbox.pendingElicitationIds() == [elicitationId])

        // The same answer through session B resumes it.
        #expect(await sessionB.respond(elicitationId: elicitationId.description, response: .decline) == .delivered)
        #expect(try await answering.value == .decline)
    }
}
