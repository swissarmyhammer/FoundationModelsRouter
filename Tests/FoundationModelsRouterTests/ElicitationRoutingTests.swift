import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task e6wb8ak: the ``RoutedSession``-level elicitation reply
/// surface — ``RoutedSession/respond(elicitationId:response:)`` and
/// ``RoutedSession/complete(elicitationId:)`` — routing an app host's answer
/// through the session's own `RunPlane` to the suspended
/// ``ToolContext/elicit(_:)`` continuation.
///
/// The route uses no task locals: session → that session's run plane → the
/// pending entry → its continuation, references the whole way, so answering
/// through one session can never resume another session's elicitation.
///
/// Task ^59wvx80 adds the outbound half: a pending elicitation reaches a host
/// live as ``SessionEvent/elicitationRequested(_:)``, and the id that event
/// carries is the id the reply surface takes.
///
/// Everything runs against stubs — a plain ``StubSessionBackend``, a scripted
/// model, and an ``InMemoryRecorder`` — so the suite needs no network and no
/// GPU.
@Suite("RoutedSession elicitation replies: respond and complete")
struct ElicitationRoutingTests {
    /// The output ``MountFixtures/ElicitOnceTool`` returns when its question
    /// is answered with `.accept`.
    private static let acceptedToolOutput = "answered: \(ElicitationResponse.Action.accept.rawValue)"

    /// The temp-directory prefix the scripted fixtures of this suite use.
    private static let tempDirPrefix = "ElicitationRoutingTests"

    /// The id of the one scripted call a scripted answer of this suite makes.
    private static let scriptedCallID = "call-elicit"

    /// Watches one ``SessionEvent`` stream for
    /// ``SessionEvent/elicitationRequested(_:)`` on a task of its own.
    ///
    /// A test waits *on* the first request with ``waitForFirst()`` — a
    /// suspension the producer ends, so a loaded machine makes the test slower
    /// and never red — and reads every request back with ``requests`` once the
    /// stream has ended. The wait ends when the first request arrives. The
    /// wait also ends when the stream ends, or when the test calls
    /// ``noteSourceEnded()`` (rule T1). Then ``waitForFirst()`` fails the
    /// test when no request came.
    private final class ElicitationWatch: Sendable {
        /// Sent when the first request arrives, when the stream ends, or when
        /// the source of the requests ended.
        private let firstArrived = AwaitedEvent()

        /// Every request seen so far, in stream order, behind a lock: the
        /// draining task writes while the test reads.
        private let seen: Mutex<[OperationEvent]> = Mutex([])

        /// Every ``SessionEvent/elicitationRequested(_:)`` payload the stream
        /// carried, in stream order.
        var requests: [OperationEvent] { seen.withLock { $0 } }

        /// Waits until the stream has carried at least one request, or until
        /// the stream or the source of the requests ended (rule T1).
        ///
        /// - Returns: The first request.
        /// - Throws: ``EventNeverArrived`` when the test was cancelled first,
        ///   or the error of `#require` when the wait ended with no request.
        func waitForFirst() async throws -> OperationEvent {
            try await firstArrived.wait()
            return try #require(requests.first)
        }

        /// Records that the source of the requests ended: the work that
        /// raises the request can raise no more. This ends the wait of
        /// ``waitForFirst()``.
        func noteSourceEnded() {
            firstArrived.signal()
        }

        /// Drains `stream` on a background task, recording each request. The
        /// end of the stream, also with an error, ends the wait of
        /// ``waitForFirst()``.
        ///
        /// - Parameter stream: The stream to drain.
        /// - Returns: The draining task. It ends when the stream ends.
        func drain<Events: AsyncSequence & Sendable>(_ stream: Events) -> Task<Void, Error>
        where Events.Element == SessionEvent {
            Task {
                defer { firstArrived.signal() }
                for try await event in stream {
                    guard case .elicitationRequested(let request) = event else { continue }
                    seen.withLock { $0.append(request) }
                    firstArrived.signal()
                }
            }
        }
    }

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

    private static let configJSON = Data("""
        {
            "num_hidden_layers": 2,
            "max_position_embeddings": 8192,
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
    private static func makeSession(pool: ModelPool = ModelPool()) async throws -> (session: any RoutedSession, dir: URL) {
        let dir = makeTempDir()
        let router = Router(
            cacheDir: dir,
            recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)),
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: 8),
            pool: pool
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return (profile.standard.makeSession(), dir)
    }

    // MARK: - Elicitation scaffolding

    /// The helpers this suite shares with `SessionRunPlaneTests`.
    private typealias Pending = PendingElicitationFixtures

    private static func urlRequest(elicitationId: ULID) throws -> ElicitationRequest {
        ElicitationRequest(
            message: "open this",
            elicitationId: elicitationId,
            url: try #require(URL(string: "https://example.com/flow"))
        )
    }

    /// Suspends a real `elicit(_:)` on `session` and waits until its pending
    /// entry is registered, returning the task that resumes with the answer.
    ///
    /// The run plane makes the entry pending before it posts the request. So
    /// the post that ``ElicitationPostings`` records is the event that tells
    /// the test the entry is registered. The test reads the answer with
    /// `try await task.value`. A break on the inbound answer route keeps the
    /// task suspended, and a stack of the test process then shows the open
    /// wait.
    ///
    /// - Parameters:
    ///   - request: The request to suspend on.
    ///   - session: The session whose run plane holds the pending entry.
    ///   - downstream: Where the request's event goes after the count, or
    ///     `nil` to drop it. Pass `session.outbox` to reach the journal of the
    ///     session.
    /// - Returns: The task that resumes with the answer.
    /// - Throws: ``ConditionNeverHeld`` when the test was cancelled before the
    ///   post, or the error of `#require` when the elicit ended before its
    ///   post.
    private static func suspendOnElicitation(
        _ request: ElicitationRequest,
        on session: any RoutedSession,
        forwardingTo downstream: (any OperationEventSink)? = nil
    ) async throws -> Task<ElicitationResponse, Error> {
        let postings = ElicitationPostings(forwardingTo: downstream)
        let context = Pending.makeContext(for: session, postingTo: postings)
        let answering = Task { try await context.elicit(request) }
        let ended = RecordedWaitResult.recordingEnd(of: answering, reportingTo: postings.changes)
        defer { ended.stopRecording() }
        // Rule T1: the wait also ends when the elicit ended. In a test that
        // passes, the elicit does not end before its post: it waits for an
        // answer that the test gives after this wait.
        try await postings.changes.wait(until: { postings.postCount >= 1 }, endingOn: { ended.value != nil })
        #expect(await session.runPlane.pendingElicitationIds().contains(request.elicitationId))
        return answering
    }

    // MARK: - Form-mode round trip

    @Test("a suspended ToolContext.elicit resumes when respond() is called on the session, with the exact response passed through")
    @MainActor
    func formRoundTripThroughSessionRespond() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let elicitationId = ULID.generate()
        let answering = try await Self.suspendOnElicitation(Pending.formRequest(elicitationId: elicitationId), on: session)

        // Rule T1: an answer that is not delivered leaves the elicit
        // suspended, so the test fails here, before it waits.
        let answer = ElicitationResponse.accept(content: ["name": .string("Ada")])
        try #require(await session.respond(elicitationId: elicitationId.description, response: answer) == .delivered)
        #expect(try await answering.value == answer)
        #expect(await session.runPlane.pendingElicitationIds().isEmpty)

        // A second respond addresses an already-answered id: a safe no-op.
        #expect(await session.respond(elicitationId: elicitationId.description, response: .decline) == .noPendingElicitation)
    }

    @Test("respond(.decline) resumes the run with .decline — a declined elicitation is not a cancelled run")
    @MainActor
    func declineResumesWithDeclineNotCancel() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let elicitationId = ULID.generate()
        let answering = try await Self.suspendOnElicitation(Pending.formRequest(elicitationId: elicitationId), on: session)

        // Rule T1: an answer that is not delivered leaves the elicit
        // suspended, so the test fails here, before it waits.
        try #require(await session.respond(elicitationId: elicitationId.description, response: .decline) == .delivered)
        #expect(try await answering.value == .decline)
    }

    // MARK: - URL-mode two-step

    @Test("URL mode: after respond(.accept) the run is still running; it resumes only on complete(); a duplicate complete is a no-op")
    @MainActor
    func urlTwoStepThroughSessionSurface() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let elicitationId = ULID.generate()
        let answering = try await Self.suspendOnElicitation(try Self.urlRequest(elicitationId: elicitationId), on: session)

        // The accept only means the user agreed to open the URL — the entry
        // stays open and the run stays running.
        #expect(await session.respond(elicitationId: elicitationId.description, response: .accept(content: nil)) == .acceptedAwaitingCompletion)
        #expect(await session.runPlane.pendingElicitationIds() == [elicitationId])

        // The out-of-band flow's completion is what resumes the run. A
        // completion that does not come leaves the elicit suspended, so the
        // test fails here, before it waits (rule T1).
        try #require(await session.complete(elicitationId: elicitationId.description) == .completed)
        #expect(try await answering.value == .accept(content: nil))
        #expect(await session.runPlane.pendingElicitationIds().isEmpty)

        // A duplicate complete is a safe no-op.
        #expect(await session.complete(elicitationId: elicitationId.description) == .noPendingElicitation)
    }

    // MARK: - Independence and no-ops

    @Test("two pending elicitations on one run resolve independently: responding to one leaves the other suspended")
    @MainActor
    func doubleElicitResolvesIndependently() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstId = ULID.generate()
        let secondId = ULID.generate()
        let postings = ElicitationPostings()
        let context = Pending.makeContext(for: session, postingTo: postings)
        let firstAnswering = Task { try await context.elicit(Pending.formRequest(elicitationId: firstId)) }
        let secondAnswering = Task { try await context.elicit(Pending.formRequest(elicitationId: secondId)) }
        let firstEnded = RecordedWaitResult.recordingEnd(of: firstAnswering, reportingTo: postings.changes)
        let secondEnded = RecordedWaitResult.recordingEnd(of: secondAnswering, reportingTo: postings.changes)
        defer {
            firstEnded.stopRecording()
            secondEnded.stopRecording()
        }
        // The run plane posts each request after it made the request pending.
        // Rule T1: the wait also ends when an elicit ended. In a test that
        // passes, no elicit ends before its post: each one waits for an
        // answer that the test gives after this wait.
        try await postings.changes.wait(
            until: { postings.postCount >= 2 },
            endingOn: { firstEnded.value != nil || secondEnded.value != nil })
        #expect(await session.runPlane.pendingElicitationIds().count == 2)

        // Rule T1: an answer that is not delivered leaves the elicit
        // suspended, so the test fails here, before it waits.
        let firstAnswer = ElicitationResponse.accept(content: ["name": .string("Ada")])
        try #require(await session.respond(elicitationId: firstId.description, response: firstAnswer) == .delivered)
        #expect(try await firstAnswering.value == firstAnswer)

        // The other elicitation is untouched: still running, still pending.
        #expect(await session.runPlane.pendingElicitationIds() == [secondId])

        try #require(await session.respond(elicitationId: secondId.description, response: .decline) == .delivered)
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

    @Test("respond()/complete() accept a pending id in either case — Crockford base32 is case-insensitive")
    @MainActor
    func idCaseDoesNotAffectRouting() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Case is never what makes an id malformed: Crockford base32 is
        // case-insensitive per the ULID spec, so uppercase and lowercase forms
        // of a pending id route to its elicitation instead of falling into the
        // malformed no-op path. Cover both functions with both cases.
        let upperRespondId = ULID.generate()
        let upperAnswering = try await Self.suspendOnElicitation(try Self.urlRequest(elicitationId: upperRespondId), on: session)
        #expect(
            await session.respond(
                elicitationId: upperRespondId.description.uppercased(),
                response: .accept(content: nil)
            ) == .acceptedAwaitingCompletion
        )
        // Rule T1: a completion that does not come leaves the elicit
        // suspended, so the test fails here, before it waits.
        try #require(await session.complete(elicitationId: upperRespondId.description.lowercased()) == .completed)
        #expect(try await upperAnswering.value == .accept(content: nil))

        let lowerRespondId = ULID.generate()
        let lowerAnswering = try await Self.suspendOnElicitation(try Self.urlRequest(elicitationId: lowerRespondId), on: session)
        #expect(
            await session.respond(
                elicitationId: lowerRespondId.description.lowercased(),
                response: .accept(content: nil)
            ) == .acceptedAwaitingCompletion
        )
        try #require(await session.complete(elicitationId: lowerRespondId.description.uppercased()) == .completed)
        #expect(try await lowerAnswering.value == .accept(content: nil))
    }

    @Test("cross-session isolation: respond on session A never resumes session B's elicitation")
    @MainActor
    func respondNeverCrossesSessions() async throws {
        let (sessionA, dirA) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dirA) }
        let (sessionB, dirB) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dirB) }

        let elicitationId = ULID.generate()
        let answering = try await Self.suspendOnElicitation(Pending.formRequest(elicitationId: elicitationId), on: sessionB)

        // Session A knows nothing about B's elicitation: the answer is a
        // no-op there, and B's run stays running.
        #expect(await sessionA.respond(elicitationId: elicitationId.description, response: .decline) == .noPendingElicitation)
        #expect(await sessionA.complete(elicitationId: elicitationId.description) == .noPendingElicitation)
        #expect(await sessionB.runPlane.pendingElicitationIds() == [elicitationId])

        // The same answer through session B resumes it. An answer that is
        // not delivered leaves the elicit suspended, so the test fails here,
        // before it waits (rule T1).
        try #require(await sessionB.respond(elicitationId: elicitationId.description, response: .decline) == .delivered)
        #expect(try await answering.value == .decline)
    }

    // MARK: - The pending elicitation reaches a host live (task ^59wvx80)

    /// Builds a session over a scripted model whose one answer calls
    /// ``MountFixtures/ElicitOnceTool`` and then answers with what the tool
    /// returned. The tool runs inside the production backend's submission, so
    /// its elicitation is raised the way a real tool raises one.
    ///
    /// - Returns: The fixture. The caller removes its directory.
    /// - Throws: Whatever profile resolution throws.
    private static func makeElicitingFixture() async throws -> ScriptedSessionFixture {
        let tool = MountFixtures.ElicitOnceTool()
        let script = ScriptedAnswerScript(rounds: [
            [
                ScriptedToolCall(
                    id: scriptedCallID, toolName: tool.name,
                    argument: .literal(ScriptedToolFixture.firstStepName))
            ]
        ])
        return try await ScriptedSessionFixture.make(
            playing: script, mounting: [tool], tempDirPrefix: tempDirPrefix)
    }

    @Test(
        "a tool that elicits inside a submission reaches streamSessionEvents() as elicitationRequested before respond() resumes it"
    )
    @MainActor
    func elicitationRequestedReachesSessionEventStreamBeforeRespond() async throws {
        let fixture = try await Self.makeElicitingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = fixture.session
        defer { await session.close() }

        // Subscribed before the answer starts, so the subscription sees the
        // request whenever the answer raises it. Each task is cancelled at exit
        // so a failed assertion above its await leaves nothing suspended.
        let watch = Self.ElicitationWatch()
        let draining = watch.drain(await session.streamSessionEvents().events)
        defer { draining.cancel() }
        // The end of the answer also ends the wait for the request (rule T1).
        let answer = Task {
            defer { watch.noteSourceEnded() }
            return try await session.respond(to: ScriptedToolFixture.prompt)
        }
        defer { answer.cancel() }

        // The request arrives while the tool is still suspended: nothing has
        // answered it yet, and the answer cannot end until something does.
        let request = try await watch.waitForFirst()
        #expect(request.kind == .elicitation)
        let elicitationId = try #require(request.elicitation?.elicitationId)
        #expect(await session.runPlane.pendingElicitationIds() == [elicitationId])

        // The id the event carries is the id the reply surface takes, and the
        // answer resumes the tool with it. An answer that is not delivered
        // leaves the tool suspended, so the test fails here, before it waits
        // (rule T1).
        try #require(
            await session.respond(elicitationId: elicitationId.description, response: .accept(content: nil))
                == .delivered)
        #expect(try await answer.value == ScriptedToolFixture.answer(fromToolOutputs: [Self.acceptedToolOutput]))

        await session.close()
        try await draining.value
        #expect(watch.requests == [request])
    }

    @Test(
        "a tool that elicits inside a streamed answer reports elicitationRequested on that answer's stream and on streamSessionEvents(), once each"
    )
    @MainActor
    func elicitationRequestedReachesTheAnswerStream() async throws {
        let fixture = try await Self.makeElicitingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = fixture.session
        defer { await session.close() }

        let sessionWatch = Self.ElicitationWatch()
        let sessionDraining = sessionWatch.drain(await session.streamSessionEvents().events)
        defer { sessionDraining.cancel() }
        let answerWatch = Self.ElicitationWatch()
        let answerDraining = answerWatch.drain(await session.streamEvents(to: ScriptedToolFixture.prompt))
        defer { answerDraining.cancel() }

        let request = try await answerWatch.waitForFirst()
        let elicitationId = try #require(request.elicitation?.elicitationId)
        #expect(await session.runPlane.pendingElicitationIds() == [elicitationId])

        // Rule T1: an answer that is not delivered leaves the tool
        // suspended, so the test fails here, before it waits.
        try #require(
            await session.respond(elicitationId: elicitationId.description, response: .accept(content: nil))
                == .delivered)
        try await answerDraining.value
        #expect(answerWatch.requests == [request])
        // The answer reached the tool, and the tool's output reached the model.
        #expect(fixture.log.deliveredToolOutputs == [Self.acceptedToolOutput])

        await session.close()
        try await sessionDraining.value
        #expect(sessionWatch.requests == [request])
    }

    @Test(
        "an elicitation raised between submissions reaches streamSessionEvents()"
    )
    @MainActor
    func elicitationRequestedBetweenSubmissionsReachesTheSessionStream() async throws {
        let (session, dir) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { await session.close() }

        // The session installs its journal on the outbox at its first
        // submission. A real tool always runs inside or after a submission, so
        // this test does the same before it posts from outside one.
        _ = try await session.respond(to: "first message")
        let watch = Self.ElicitationWatch()
        let draining = watch.drain(await session.streamSessionEvents().events)
        defer { draining.cancel() }

        let elicitationId = ULID.generate()
        let answering = try await Self.suspendOnElicitation(
            Pending.formRequest(elicitationId: elicitationId), on: session, forwardingTo: session.outbox)

        let request = try await watch.waitForFirst()
        #expect(request.elicitation?.elicitationId == elicitationId)
        // Rule T1: an answer that is not delivered leaves the elicit
        // suspended, so the test fails here, before it waits.
        try #require(await session.respond(elicitationId: elicitationId.description, response: .decline) == .delivered)
        #expect(try await answering.value == .decline)

        await session.close()
        try await draining.value
        #expect(watch.requests == [request])
    }
}
