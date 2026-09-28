import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the run plane of a real ``RoutedSession``: the sweep that
/// ``RoutedSession/close()`` runs, which journals one terminal event for each
/// background run, the restore of a closed session, and the new run plane of
/// a fork.
///
/// The tests of the run plane alone moved to FoundationModelsExtras with the
/// `RunPlane` type (its `RunPlaneActorTests`). These tests stay here because
/// they drive the session of the router.
///
/// Each test runs over stubs: fake background runs, a plain
/// ``StubSessionBackend``, and an ``InMemoryRecorder`` or a
/// ``JSONLRecorder``. The suite needs no network and no GPU.
@Suite("Session run plane: close()-driven sweep, restore, and fork")
struct SessionRunPlaneTests {
    /// The prefix of the temp directories of this suite.
    private static let tempDirPrefix = "SessionRunPlaneTests"

    /// The deadline, in seconds, of each wait for a run in this suite.
    private static let waitDeadlineSeconds: Double = 5

    /// Makes a router over the stub fixtures, resolves the standard profile,
    /// and makes a session.
    ///
    /// - Parameter recorder: The recorder of the router.
    /// - Returns: The session, and the temp directory that the caller
    ///   removes.
    /// - Throws: What the resolve throws.
    private static func makeSession(
        recorder: any TranscriptRecorder
    ) async throws -> (session: RoutedSession, dir: URL) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            recorder: recorder,
            loader: StubModelLoader(
                container: UndrivenLanguageModelContainer(), dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (profile.standard.makeSession(), dir)
    }

    /// Makes a router that records to `recordingsDir` through a
    /// ``JSONLRecorder``.
    ///
    /// - Parameters:
    ///   - id: The id of the recording root. Pass the id of an earlier router
    ///     to continue its recording root, as a new process does.
    ///   - cacheDir: The cache directory of the router.
    ///   - recordingsDir: The root of the durable transcripts.
    /// - Returns: The router.
    private static func makeRecordingRouter(id: ULID = .generate(), cacheDir: URL, recordingsDir: URL) -> Router {
        RouterTestFixtures.makeRouter(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            loader: StubModelLoader(
                container: UndrivenLanguageModelContainer(), dimension: RouterTestFixtures.stubDimension)
        )
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
            await session.mailbox.awaitAnswer(to: PendingElicitationFixtures.formRequest(elicitationId: elicitationId))
        }
        #expect(
            await PendingElicitationFixtures.eventually {
                await session.mailbox.pendingElicitationIds() == [elicitationId]
            })

        await session.close()

        // Each background run's canceler ran per its kind's semantics.
        #expect(await counter.count == 2)
        // The run plane is empty: no background runs, no pending elicitations.
        #expect(await session.mailbox.backgroundRuns().isEmpty)
        #expect(await session.mailbox.pendingElicitationIds().isEmpty)
        // The pending elicitation was rejected.
        #expect(try await rejected.deliveredAnswer() == .cancel)

        // The journal opens with the session's meta line — a close that
        // journals anything records the `.session` meta event first, exactly
        // like every answer path does.
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
        let sweptWait = await session.mailbox.wait(completionToken: tokenA, seconds: Self.waitDeadlineSeconds)
        let settledTerminal: OperationEvent? = if case .settled(let terminal) = sweptWait { terminal } else { nil }
        let terminal = try #require(settledTerminal, "expected .settled after sweep, got \(sweptWait)")
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
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router1 = Self.makeRecordingRouter(cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile1.standard.makeSession()

        let latch = RunLatch()
        let token = await trackFakeRun(on: session.mailbox, latch: latch)
        await session.close()

        // "Tear down" and restore under a fresh process with no caller setup
        // at all: `OperationEventSegment` rebuilds from its own persisted
        // schema name, so the closed session's journaled terminal events come
        // back with nothing to register.
        let router2 = Self.makeRecordingRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: session.id)
        #expect(restored.root.id == session.id)

        // The reconstructed transcript carries the terminal event as a real
        // toolOutput entry whose structured segment decodes back to it — the
        // documented restore-time shape of a closed session's journal.
        let tree = try TranscriptTree.load(
            under: RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir))
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

    // MARK: - Fork gets a fresh run plane

    @Test("a fork's mailbox is a distinct, fresh instance — never shared with its parent")
    @MainActor
    func forkGetsFreshMailbox() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        let child = try await session.fork(workingDirectory: nil)
        #expect(session.mailbox !== child.mailbox)

        // Tracking on the parent never leaks into the child's run plane.
        let latch = RunLatch()
        let token = await trackFakeRun(on: session.mailbox, latch: latch)
        #expect(await session.mailbox.backgroundRuns().count == 1)
        #expect(await child.mailbox.backgroundRuns().isEmpty)

        await latch.open()
        _ = await session.mailbox.wait(completionToken: token, seconds: Self.waitDeadlineSeconds)
    }
}
