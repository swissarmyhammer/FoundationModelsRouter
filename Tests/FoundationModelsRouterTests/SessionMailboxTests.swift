import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task 3g930c4: the ``SessionMailbox`` actor — tracked background
/// runs (track/backgroundRuns/wait/cancel), the pending-elicitation registry, and
/// the ``RoutedSession/close()``-driven teardown sweep that journals exactly
/// one terminal event per background run.
///
/// Everything runs against stubs — fake tracked `Task`s, a plain
/// ``StubSessionBackend``, and an ``InMemoryRecorder`` — so the suite needs
/// no network and no GPU.
@Suite("Session mailbox: background runs, elicitations, and close()-driven sweep")
struct SessionMailboxTests {
    // MARK: - track / backgroundRuns / wait lifecycle

    @Test("track lists the run in backgroundRuns(), wait() returns its terminal event, and a settled run leaves backgroundRuns()")
    func trackListingAndWaitLifecycle() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let token = await trackFakeRun(on: mailbox, latch: latch, detailOnSettle: "exit 0")

        let pending = await mailbox.backgroundRuns()
        #expect(pending.count == 1)
        #expect(pending.first?.completionToken == token)
        #expect(pending.first?.tool == FakeRun.tool)
        #expect(pending.first?.op == FakeRun.op)
        #expect(pending.first?.kind == .swiftTask)
        #expect(pending.first?.latestProgressDetail == nil)

        await mailbox.updateProgress(completionToken: token, detail: "50%")
        #expect(await mailbox.backgroundRuns().first?.latestProgressDetail == "50%")

        await latch.open()
        let result = await mailbox.wait(completionToken: token, seconds: 5)
        guard case .settled(let terminal) = result else {
            Issue.record("expected .settled, got \(result)")
            return
        }
        #expect(terminal.correlationID == token)
        #expect(terminal.kind == .completed)
        #expect(terminal.detail == "exit 0")
        #expect(terminal.outcome == .succeeded)

        #expect(await mailbox.backgroundRuns().isEmpty)
    }

    @Test("wait() on a run that never settles elapses its deadline and leaves the run tracked")
    func waitDeadlineElapses() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let token = await trackFakeRun(on: mailbox, latch: latch)

        let result = await mailbox.wait(completionToken: token, seconds: 0.05)
        #expect(result == .deadlineElapsed)
        #expect(await mailbox.backgroundRuns().count == 1)

        // Settle the fake run so the test tears down with no suspended
        // continuation left behind.
        await latch.open()
        _ = await mailbox.wait(completionToken: token, seconds: 5)
    }

    @Test(
        "wait() clamps an outside-supplied deadline instead of trapping",
        arguments: [-1.0, 0.0, Double.nan]
    )
    func waitClampsUntrustedSeconds(seconds: Double) async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let token = await trackFakeRun(on: mailbox, latch: latch)

        // A non-positive or non-finite deadline resolves as an immediate
        // deadline elapse — never a crash — and leaves the run tracked.
        let result = await mailbox.wait(completionToken: token, seconds: seconds)
        #expect(result == .deadlineElapsed)
        #expect(await mailbox.backgroundRuns().count == 1)

        await latch.open()
        _ = await mailbox.wait(completionToken: token, seconds: 5)
    }

    // MARK: - The run plane's deadline ceiling

    /// Nanoseconds in one second — the unit
    /// ``SessionMailbox/boundedNanoseconds(clamping:)`` reports in.
    private static let nanosecondsPerSecond: Double = 1_000_000_000

    /// The run plane's ceiling, in the nanoseconds the clamp reports.
    private static let ceilingNanoseconds = UInt64(
        ToolContext.deadlineSecondsCeiling * nanosecondsPerSecond
    )

    /// A requested deadline plainly over the ceiling.
    private static let overCeilingSeconds = ToolContext.deadlineSecondsCeiling + 1

    @Test(
        "boundedNanoseconds caps every deadline the run plane is given at its ceiling",
        arguments: [
            ToolContext.deadlineSecondsCeiling,
            Self.overCeilingSeconds,
            Double.infinity,
        ]
    )
    func boundedNanosecondsCapsAtTheCeiling(seconds: Double) {
        #expect(SessionMailbox.boundedNanoseconds(clamping: seconds) == Self.ceilingNanoseconds)
    }

    @Test("boundedNanoseconds converts a deadline under the ceiling rather than capping it")
    func boundedNanosecondsConvertsUnderTheCeiling() {
        #expect(
            SessionMailbox.boundedNanoseconds(clamping: 1) == UInt64(Self.nanosecondsPerSecond)
        )
    }

    @Test("a settled run resolves wait() immediately even with a clamped-to-zero deadline")
    func settledRunResolvesWaitDespiteZeroDeadline() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let token = await trackFakeRun(on: mailbox, latch: latch)
        await latch.open()
        _ = await mailbox.wait(completionToken: token, seconds: 5)

        let result = await mailbox.wait(completionToken: token, seconds: -1)
        guard case .settled(let terminal) = result else {
            Issue.record("expected .settled, got \(result)")
            return
        }
        #expect(terminal.correlationID == token)
    }

    @Test("wait() on a run with oversized output returns a bounded tail carrying the run identifier, never the full output")
    func waitReturnsBoundedResult() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let oversized = String(repeating: "x", count: ToolContext.terminalDetailTailLimit * 3) + "end-of-output"
        let token = await trackFakeRun(on: mailbox, latch: latch, detailOnSettle: oversized)

        await latch.open()
        let result = await mailbox.wait(completionToken: token, seconds: 5)
        guard case .settled(let terminal) = result else {
            Issue.record("expected .settled, got \(result)")
            return
        }
        #expect(terminal.correlationID == token)
        #expect(terminal.detail.count == ToolContext.terminalDetailTailLimit)
        #expect(terminal.detail.hasSuffix("end-of-output"))
    }

    // MARK: - cancel

    @Test("cancel() invokes the canceler, reports the outcome the canceler reports, and a concurrent wait() observes the cancelled terminal event")
    func cancelWhileWaiting() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let token = await trackFakeRun(on: mailbox, latch: latch)

        let waiting = Task { await mailbox.wait(completionToken: token, seconds: 5) }
        let cancelResult = await mailbox.cancel(completionToken: token)
        #expect(cancelResult == .reported(.cancelled))

        let waited = await waiting.value
        guard case .settled(let terminal) = waited else {
            Issue.record("expected .settled, got \(waited)")
            return
        }
        #expect(terminal.correlationID == token)
        #expect(terminal.outcome == .cancelled)
    }

    @Test("cancel() passes through the canceler's own outcome rather than guessing")
    func cancelReportsCancelerOutcomeVerbatim() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let token = await trackFakeRun(on: mailbox, latch: latch, cancelerOutcome: .stopped)

        let cancelResult = await mailbox.cancel(completionToken: token)
        #expect(cancelResult == .reported(.stopped))

        // Let the cooperatively-cancelled fake run settle before teardown.
        _ = await mailbox.wait(completionToken: token, seconds: 5)
    }

    @Test("cancel() on a run that already settled reports .alreadySettled with its terminal event, never .unknownToken")
    func cancelOnSettledRunReportsAlreadySettled() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let token = await trackFakeRun(on: mailbox, latch: latch, detailOnSettle: "exit 0")
        await latch.open()
        _ = await mailbox.wait(completionToken: token, seconds: 5)

        let cancelResult = await mailbox.cancel(completionToken: token)
        guard case .alreadySettled(let terminal) = cancelResult else {
            Issue.record("expected .alreadySettled, got \(cancelResult)")
            return
        }
        #expect(terminal.correlationID == token)
        #expect(terminal.outcome == .succeeded)
    }

    // MARK: - track refuses duplicate tokens

    @Test("track() with a token already in use refuses the new run and leaves the incumbent untouched")
    func trackRefusesDuplicateToken() async {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let token = await trackFakeRun(on: mailbox, latch: latch)

        let refusedSettling = Task<OperationEvent, Never> {
            OperationEvent(
                tool: FakeRun.tool,
                op: FakeRun.op,
                correlationID: token,
                kind: .completed,
                detail: "refused",
                outcome: .succeeded
            )
        }
        let refused = await mailbox.track(
            tool: FakeRun.tool,
            op: FakeRun.op,
            kind: .swiftTask,
            completionToken: token,
            settling: refusedSettling,
            canceler: { .cancelled }
        )
        #expect(refused == .duplicateToken)
        // The incumbent is still the one and only background run — no duplicate
        // background-run row, no silent overwrite.
        #expect(await mailbox.backgroundRuns().count == 1)

        await latch.open()
        let result = await mailbox.wait(completionToken: token, seconds: 5)
        guard case .settled(let terminal) = result else {
            Issue.record("expected .settled, got \(result)")
            return
        }
        // The incumbent's terminal event won — not the refused run's.
        #expect(terminal.detail == "done")
    }

    // MARK: - Bounded settled-event retention

    @Test("settled terminal events are retained under a bounded FIFO: the oldest settlement is evicted past the limit")
    func settledTerminalEventRetentionIsBounded() async {
        let mailbox = SessionMailbox()
        var tokens: [String] = []
        for _ in 0...SessionMailbox.settledTerminalEventRetentionLimit {
            let latch = RunLatch()
            let token = await trackFakeRun(on: mailbox, latch: latch)
            await latch.open()
            _ = await mailbox.wait(completionToken: token, seconds: 5)
            tokens.append(token)
        }

        // One more settlement than the limit: the oldest terminal event was
        // evicted and its token honestly reports unknown again; the newest
        // is still retained.
        let oldest = tokens[0]
        let newest = tokens[tokens.count - 1]
        #expect(await mailbox.wait(completionToken: oldest, seconds: 5) == .unknownToken)
        guard case .settled = await mailbox.wait(completionToken: newest, seconds: 5) else {
            Issue.record("expected the newest settlement to still be retained")
            return
        }
    }

    // MARK: - Unknown-id no-ops

    @Test("unknown completionToken operations are safe, reportable no-ops")
    func unknownCompletionTokenIsNoOp() async {
        let mailbox = SessionMailbox()
        let unknown = SessionMailbox.makeCompletionToken()

        #expect(await mailbox.cancel(completionToken: unknown) == .unknownToken)
        #expect(await mailbox.wait(completionToken: unknown, seconds: 5) == .unknownToken)
        await mailbox.updateProgress(completionToken: unknown, detail: "ignored")
        #expect(await mailbox.backgroundRuns().isEmpty)
    }

    @Test("unknown and already-completed elicitationIds are safe no-ops")
    func unknownElicitationIdIsNoOp() async {
        let mailbox = SessionMailbox()
        let unknown = ULID.generate()

        #expect(await mailbox.respond(elicitationId: unknown, .decline) == .noPendingElicitation)
        #expect(await mailbox.complete(elicitationId: unknown) == .noPendingElicitation)
    }

    // MARK: - Pending elicitations

    /// Polls until `condition` holds, yielding between checks, so a test can
    /// wait for an `awaitAnswer(to:)` task to register its continuation
    /// without racing it.
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

    @Test("a form-mode elicitation resumes on respond(), and a second respond is a no-op")
    func formElicitationDeliversAnswer() async throws {
        let mailbox = SessionMailbox()
        let elicitationId = ULID.generate()
        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(elicitationId)") {
            await mailbox.awaitAnswer(to: Self.formRequest(elicitationId: elicitationId))
        }
        #expect(await Self.eventually { await mailbox.pendingElicitationIds() == [elicitationId] })

        let answer = ElicitationResponse.accept(content: ["name": .string("Ada")])
        #expect(await mailbox.respond(elicitationId: elicitationId, answer) == .delivered)
        #expect(try await answering.deliveredAnswer() == answer)
        #expect(await mailbox.pendingElicitationIds().isEmpty)
        #expect(await mailbox.respond(elicitationId: elicitationId, .decline) == .noPendingElicitation)
    }

    @Test("a URL-mode elicitation stays open past accept until complete(elicitationId:)")
    func urlElicitationStaysOpenPastAccept() async throws {
        let mailbox = SessionMailbox()
        let elicitationId = ULID.generate()
        let request = ElicitationRequest(
            message: "open this",
            elicitationId: elicitationId,
            url: try #require(URL(string: "https://example.com/flow"))
        )
        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            await mailbox.awaitAnswer(to: request)
        }
        #expect(await Self.eventually { await mailbox.pendingElicitationIds() == [elicitationId] })

        #expect(await mailbox.respond(elicitationId: elicitationId, .accept(content: nil)) == .acceptedAwaitingCompletion)
        // The accept alone does not resume the run: the entry stays open.
        #expect(await mailbox.pendingElicitationIds() == [elicitationId])

        #expect(await mailbox.complete(elicitationId: elicitationId) == .completed)
        #expect(try await answering.deliveredAnswer() == .accept(content: nil))
        #expect(await mailbox.pendingElicitationIds().isEmpty)
        #expect(await mailbox.complete(elicitationId: elicitationId) == .noPendingElicitation)
    }

    @Test("a URL-mode decline resumes immediately without waiting for completion")
    func urlElicitationDeclineResumesImmediately() async throws {
        let mailbox = SessionMailbox()
        let elicitationId = ULID.generate()
        let request = ElicitationRequest(
            message: "open this",
            elicitationId: elicitationId,
            url: try #require(URL(string: "https://example.com/flow"))
        )
        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            await mailbox.awaitAnswer(to: request)
        }
        #expect(await Self.eventually { await mailbox.pendingElicitationIds() == [elicitationId] })

        #expect(await mailbox.respond(elicitationId: elicitationId, .decline) == .delivered)
        #expect(try await answering.deliveredAnswer() == .decline)
        #expect(await mailbox.pendingElicitationIds().isEmpty)
    }

    // MARK: - Stub container scaffolding (close()/fork() against a real session)

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
            .appendingPathComponent("SessionMailboxTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a fresh router + resolved profile + vended session over a plain
    /// stub backend, recording through `recorder`.
    private static func makeSession(
        recorder: any TranscriptRecorder
    ) async throws -> (session: RoutedSession, dir: URL) {
        let dir = makeTempDir()
        let router = Router(
            cacheDir: dir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)),
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: 8)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return (profile.standard.makeSession(), dir)
    }

    // MARK: - close()-driven sweep

    @Test("close() sweeps background runs: each canceler invoked, exactly one terminal event per run journaled before close() returns, pending elicitations rejected")
    @MainActor
    func closeSweepsBackgroundRunsAndJournalsTerminalEvents() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = CancelCounter()
        let latchA = RunLatch()
        let latchB = RunLatch()
        let tokenA = await trackFakeRun(on: session.mailbox, latch: latchA, counter: counter)
        let tokenB = await trackFakeRun(on: session.mailbox, latch: latchB, counter: counter)

        let elicitationId = ULID.generate()
        let rejected = AnswerDrivenRun(waitingFor: "the elicitation \(elicitationId) swept by close()") {
            await session.mailbox.awaitAnswer(to: Self.formRequest(elicitationId: elicitationId))
        }
        #expect(await Self.eventually { await session.mailbox.pendingElicitationIds() == [elicitationId] })

        await session.close()

        // Each background run's canceler ran per its kind's semantics.
        #expect(await counter.count == 2)
        // The mailbox is empty: no background runs, no pending elicitations.
        #expect(await session.mailbox.backgroundRuns().isEmpty)
        #expect(await session.mailbox.pendingElicitationIds().isEmpty)
        // The pending elicitation was rejected.
        #expect(try await rejected.deliveredAnswer() == .cancel)

        // The journal opens with the session's meta line — a close that
        // journals anything records the `.session` meta event first, exactly
        // like every turn path does.
        let recorded = await recorder.events
        #expect(recorded.first?.kind == .session)

        // Exactly one terminal event per background run was journaled before
        // close() returned — no orphans, no holes.
        let journaled: [OperationEvent] = recorded
            .filter { $0.kind == .toolOutput }
            .compactMap { event in
                guard let segments = event.entry?.segments else { return nil }
                for segment in segments {
                    if case .structure(_, let schemaName, let contentJSON) = segment,
                        schemaName == OperationEventSegment.schemaName
                    {
                        return try? JSONDecoder().decode(OperationEvent.self, from: Data(contentJSON.utf8))
                    }
                }
                return nil
            }
        #expect(journaled.map(\.correlationID) == [tokenA, tokenB])
        for terminal in journaled {
            #expect(terminal.kind == .completed)
            #expect(terminal.outcome == .cancelled)
        }

        // A swept token's wait() reports the settled terminal event rather
        // than hanging or claiming the token is unknown.
        let sweptWait = await session.mailbox.wait(completionToken: tokenA, seconds: 5)
        guard case .settled(let terminal) = sweptWait else {
            Issue.record("expected .settled after sweep, got \(sweptWait)")
            return
        }
        #expect(terminal.correlationID == tokenA)
    }

    @Test("close() on a session with nothing tracked journals nothing at all — not even the session meta line")
    @MainActor
    func closeWithEmptyMailboxIsNoOp() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        await session.close()

        // A session that never generated and never tracked a run writes no
        // events whatsoever — the "writes no file at all until it generates"
        // invariant survives close().
        #expect(await recorder.events.isEmpty)
    }

    @Test("a second close() — sequential or concurrent — never double-invokes a canceler or double-journals a terminal event")
    @MainActor
    func doubleCloseKeepsExactlyOneTerminalEventPerRun() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = CancelCounter()
        let latchA = RunLatch()
        let latchB = RunLatch()
        _ = await trackFakeRun(on: session.mailbox, latch: latchA, counter: counter)
        _ = await trackFakeRun(on: session.mailbox, latch: latchB, counter: counter)

        // Two concurrent closes, then a third sequential one.
        async let firstClose: Void = session.close()
        async let secondClose: Void = session.close()
        _ = await (firstClose, secondClose)
        await session.close()

        // Each canceler ran exactly once, and exactly one terminal event per
        // run reached the journal — never two.
        #expect(await counter.count == 2)
        let journaled = await recorder.events.filter { $0.kind == .toolOutput }
        #expect(journaled.count == 2)
    }

    // MARK: - close() then restore

    @Test("a closed session restores with no caller setup: the journaled terminal events rebuild as toolOutput entries")
    @MainActor
    func closedSessionRestoresWithNoCallerSetup() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: RawRepoMetadata(configJSON: Self.configJSON, treeJSON: Self.treeJSON)),
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: 8)
        )
        let profile1 = try await router1.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let session = profile1.standard.makeSession()

        let latch = RunLatch()
        let token = await trackFakeRun(on: session.mailbox, latch: latch)
        await session.close()

        // "Tear down" and restore under a fresh process with no caller setup
        // at all: `OperationEventSegment` rebuilds from its own persisted
        // schema name, so the closed session's journaled terminal events come
        // back with nothing to register.
        let router2 = Router(
            id: router1.id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: RawRepoMetadata(configJSON: Self.configJSON, treeJSON: Self.treeJSON)),
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: 8)
        )
        let profile2 = try await router2.resolve(profile: Self.profile, reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: session.id)
        #expect(restored.root.id == session.id)

        // The reconstructed transcript carries the terminal event as a real
        // toolOutput entry whose structured segment decodes back to it — the
        // documented restore-time shape of a closed session's journal.
        let tree = try TranscriptTree.load(
            under: recordingsDir.appendingPathComponent(router1.id.description, isDirectory: true))
        let transcript = try tree.effectiveTranscript(forSession: session.id)
        let restoredTerminals: [OperationEvent] = Array(transcript).compactMap { entry in
            guard case .toolOutput(let output) = entry,
                case .structure(let structured)? = output.segments.first,
                let operationSegment = try? OperationEventSegment(structuredSegment: structured)
            else { return nil }
            return operationSegment.content
        }
        #expect(restoredTerminals.map(\.correlationID) == [token])
        #expect(restoredTerminals.first?.kind == .completed)
        #expect(restoredTerminals.first?.outcome == .cancelled)
    }

    // MARK: - Fork gets a fresh mailbox

    @Test("a fork's mailbox is a distinct, fresh instance — never shared with its parent")
    @MainActor
    func forkGetsFreshMailbox() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        let child = try await session.fork(workingDirectory: nil)
        #expect(session.mailbox !== child.mailbox)

        // Tracking on the parent never leaks into the child's mailbox.
        let latch = RunLatch()
        let token = await trackFakeRun(on: session.mailbox, latch: latch)
        #expect(await session.mailbox.backgroundRuns().count == 1)
        #expect(await child.mailbox.backgroundRuns().isEmpty)

        await latch.open()
        _ = await session.mailbox.wait(completionToken: token, seconds: 5)
    }
}
