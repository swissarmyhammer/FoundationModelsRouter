import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Exercises the claim of orphan runs at a restore.
///
/// A restore posts a `.lost` terminal for each orphan run. A host that
/// drives the interrupted work again wants to complete the original run with
/// the real result. So the host names the run in `claimingRuns`. The restore
/// then posts no `.lost` for it, and the restored session keeps the claim
/// open until the host completes it
/// (``RoutedSession/completeClaimedRun(_:outcome:detail:)``) or the session
/// closes, which ends the run as `.lost`.
///
/// The crash is simulated as the other restore suites do it: the recorded
/// session stays open, a second router over the same recording root restores
/// it, and the test closes both sessions at its end.
@Suite("restoreSessionTree: the host claims orphan runs")
struct ClaimOrphanRunsTests {
    /// The temp directory prefix every fixture of this suite is built with.
    private static let tempDirPrefix = "ClaimOrphanRunsTests"

    /// The tool of the orphan run.
    private static let tool = "shell"

    /// The key of the orphan run that the tests claim.
    private static let orphanKey = RunKey(tool: tool, correlationID: "run-1")

    /// The detail that the host gives to the completion.
    private static let completionDetail = "exit 0 from the second run"

    // MARK: - Fixture

    /// A recorded session with a restore of it.
    private struct Restored {
        /// The restored tree.
        let tree: RestoredSessionTree

        /// The session that the recording belongs to, still open as the
        /// session of a crashed process is.
        let recorded: any RoutedSession

        /// The directory of the recording of the router.
        let routerDirectory: URL

        /// The directories to remove at the end.
        let directories: [URL]

        /// The recorded events of the restored root, in `seq` order.
        func events() throws -> [TranscriptEvent] {
            try TranscriptTree.load(under: routerDirectory).events(forSession: tree.root.id)
        }

        /// The status of each journaled run of the restored root.
        func statuses() throws -> [RunKey: RunStatus] {
            OrphanRunScan(scanning: try events()).statuses
        }

        /// The count of the `.completed` events that the journal holds for `key`.
        func completedCount(of key: RunKey) throws -> Int {
            try events().flatMap(\.operationEvents).filter { event in
                event.kind == .completed && RunKey(tool: event.tool, correlationID: event.correlationID) == key
            }.count
        }

        /// Closes both sessions and removes the directories.
        func end() async {
            await tree.root.close()
            await recorded.close()
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// The router of one test, over a model that answers with text.
    private static func makeRouter(id: ULID = .generate(), cacheDir: URL, recordingsDir: URL, recorder: JSONLRecorder) -> Router {
        let container = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: ScriptedAnswerScript(rounds: []), log: ScriptedAnswerLog()))
        return RouterTestFixtures.makeRouter(
            id: id, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
    }

    /// Records a root session that journals `journaled` with one answer, and
    /// restores it under a second router over the same recording root.
    ///
    /// - Parameters:
    ///   - journaled: The run events posted before the answer.
    ///   - claiming: The runs that the restore claims.
    /// - Returns: The restore. The caller ends it.
    /// - Throws: What the restore throws, after it closed the recorded
    ///   session and removed the directories.
    private static func recordAndRestore(
        journaled: [OperationEvent], claiming: Set<RunKey>
    ) async throws -> Restored {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = JSONLRecorder(directory: recordingsDir)
        let router1 = makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)
        let profile1 = try await router1.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        do {
            for event in journaled {
                await root.outbox.post(event: event)
            }
            _ = try await root.respond(to: "hello")
            let router2 = makeRouter(id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)
            let profile2 = try await router2.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            let tree = try await profile2.standard.restoreSessionTree(root: root.id, claimingRuns: claiming)
            return Restored(
                tree: tree, recorded: root,
                routerDirectory: RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir),
                directories: [cacheDir, recordingsDir])
        } catch {
            await root.close()
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
            throw error
        }
    }

    /// A progress event of the run `correlationID` of the tool `tool`.
    private static func progress(tool: String = tool, correlationID: String) -> OperationEvent {
        OperationEvent(tool: tool, op: "run command", correlationID: correlationID, kind: .progress, detail: "working")
    }

    /// A completed event of the run `correlationID` of the tool `tool`.
    private static func completed(tool: String = tool, correlationID: String) -> OperationEvent {
        OperationEvent(
            tool: tool, op: "run command", correlationID: correlationID, kind: .completed, detail: "exit 0",
            outcome: .succeeded)
    }

    // MARK: - Claim and complete

    @Test("a claimed run gets no lost terminal at the restore")
    @MainActor
    func claimedRunGetsNoLostTerminal() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [Self.orphanKey])
        defer { await restored.end() }

        let pending = await restored.tree.root.outbox.pending()

        #expect(pending.events.isEmpty)
    }

    @Test("a run that is not claimed still gets its lost terminal when another run is claimed")
    @MainActor
    func unclaimedRunStillGetsALostTerminal() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [
                Self.progress(correlationID: Self.orphanKey.correlationID),
                Self.progress(correlationID: "run-2"),
            ],
            claiming: [Self.orphanKey])
        defer { await restored.end() }

        let pending = await restored.tree.root.outbox.pending()

        #expect(pending.events.map(\.event.correlationID) == ["run-2"])
    }

    @Test("a claimed run completes once with the outcome of the host")
    @MainActor
    func claimedRunCompletesOnce() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [Self.orphanKey])
        defer { await restored.end() }

        let accepted = await restored.tree.root.completeClaimedRun(
            Self.orphanKey, outcome: .succeeded, detail: Self.completionDetail)

        #expect(accepted)
        #expect(try restored.statuses()[Self.orphanKey] == .completed(.succeeded))
        #expect(try restored.completedCount(of: Self.orphanKey) == 1)
    }

    @Test("a second completion of a claimed run is a no-op")
    @MainActor
    func secondCompletionIsANoOp() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [Self.orphanKey])
        defer { await restored.end() }
        _ = await restored.tree.root.completeClaimedRun(Self.orphanKey, outcome: .succeeded, detail: nil)

        let accepted = await restored.tree.root.completeClaimedRun(Self.orphanKey, outcome: .failed, detail: nil)

        #expect(!accepted)
        #expect(try restored.completedCount(of: Self.orphanKey) == 1)
        #expect(try restored.statuses()[Self.orphanKey] == .completed(.succeeded))
    }

    @Test("a completion of a key that nobody claimed is a no-op")
    @MainActor
    func completionOfAnUnclaimedKeyIsANoOp() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [])
        defer { await restored.end() }

        let accepted = await restored.tree.root.completeClaimedRun(Self.orphanKey, outcome: .succeeded, detail: nil)

        #expect(!accepted)
    }

    // MARK: - Claim and close

    @Test("a claimed run that the host never completes ends as lost when the session closes")
    @MainActor
    func claimedRunEndsAsLostAtClose() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [Self.orphanKey])
        defer { await restored.end() }

        await restored.tree.root.close()

        #expect(try restored.statuses()[Self.orphanKey] == .completed(.lost))
        #expect(try restored.completedCount(of: Self.orphanKey) == 1)
    }

    @Test("a claimed run that the host completed gets no lost terminal at close")
    @MainActor
    func completedClaimGetsNoLostTerminalAtClose() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [Self.orphanKey])
        defer { await restored.end() }
        _ = await restored.tree.root.completeClaimedRun(Self.orphanKey, outcome: .succeeded, detail: nil)

        await restored.tree.root.close()

        #expect(try restored.statuses()[Self.orphanKey] == .completed(.succeeded))
        #expect(try restored.completedCount(of: Self.orphanKey) == 1)
    }

    // MARK: - No claim

    @Test("a restore with no claim posts the lost terminal as before")
    @MainActor
    func noClaimPostsTheLostTerminal() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [])
        defer { await restored.end() }

        let pending = await restored.tree.root.outbox.pending()

        #expect(pending.events.map(\.event.outcome) == [.lost])
    }

    // MARK: - A key that cannot be claimed

    @Test("a claim of a completed run throws runNotClaimable")
    @MainActor
    func claimOfACompletedRunThrows() async throws {
        let key = Self.orphanKey
        await #expect(throws: SessionTreeRestorationError.runNotClaimable(key)) {
            let restored = try await Self.recordAndRestore(
                journaled: [
                    Self.progress(correlationID: key.correlationID),
                    Self.completed(correlationID: key.correlationID),
                ],
                claiming: [key])
            await restored.end()
        }
    }

    @Test("a claim of a run that the journal does not hold throws runNotClaimable")
    @MainActor
    func claimOfAnUnknownRunThrows() async throws {
        let unknown = RunKey(tool: Self.tool, correlationID: "no-such-run")
        await #expect(throws: SessionTreeRestorationError.runNotClaimable(unknown)) {
            let restored = try await Self.recordAndRestore(
                journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [unknown])
            await restored.end()
        }
    }

    // MARK: - Idle

    @Test("a session with an open claim is not idle")
    @MainActor
    func openClaimIsWork() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [Self.orphanKey])
        defer { await restored.end() }
        let session = try #require(restored.tree.root as? RoutedSessionActor)

        #expect(await session.isIdle() == false)
    }

    @Test("a session is idle again after the host completed its claim")
    @MainActor
    func completedClaimEndsTheWork() async throws {
        let restored = try await Self.recordAndRestore(
            journaled: [Self.progress(correlationID: Self.orphanKey.correlationID)], claiming: [Self.orphanKey])
        defer { await restored.end() }
        _ = await restored.tree.root.completeClaimedRun(Self.orphanKey, outcome: .succeeded, detail: nil)

        #expect(await restored.tree.root.awaitIdle())
    }
}
