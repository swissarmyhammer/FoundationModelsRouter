import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^6z1msg1: a fork's cut point is recorded in append-only
/// history coordinates, so a fork taken after its parent folded restores the
/// fold's live window plus the fork's own entries — never the pre-fold span
/// the fold discarded.
///
/// Compaction is append-only: a fold appends one boundary entry carrying its
/// ``CompactionSegment`` checkpoint and rewinds only the *backend*'s
/// positional diff baseline, never the session's position in its own
/// recorded history. A fork's cut must therefore be recorded in the recorded
/// history's own coordinates. Before this task, `fork()` recorded the
/// post-fold backend entry count instead, so a restored fork rebuilt the
/// oldest pre-fold entries and cut off the checkpoint.
///
/// Everything runs against stubs — a ``StubSessionBackend``-backed container
/// and a ``JSONLRecorder`` in a temp directory — mirroring
/// `SessionTreeRestorationTests`' fresh-process simulation: a second,
/// independently constructed `Router` pointed at the same id and recordings
/// root restores what the first recorded.
@Suite("Fork cuts in append-only history coordinates")
struct ForkAfterCompactionRestorationTests {
    // MARK: - Stub container

    /// Vends a test-retained ``StubSessionBackend`` per session — fresh
    /// (`makeSession(instructions:)`) and restore-seeded
    /// (`makeSession(transcript:)`) alike — so a test can read the live
    /// entries a session accumulated and derive an exact fold-forcing budget.
    private final class RetainingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The canned text every backend this container vends responds with.
        let responseText: String

        /// The most recently vended backend, for entry inspection.
        private(set) var lastBackend: StubSessionBackend?

        /// Creates a container whose backends respond with `responseText`.
        init(responseText: String) {
            self.responseText = responseText
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(responseText: responseText, instructions: instructions)
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(responseText: responseText, entries: Array(transcript))
            lastBackend = backend
            return backend
        }
    }

    // MARK: - Fixtures

    /// A long-ish canned response, repeated across every turn, so six turns'
    /// worth of transcript carries a real byte-size estimate and the
    /// deterministic-fold budget derivation has room to sit strictly between
    /// the recency-window floor and the full pre-fold estimate.
    private static let cannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// Builds a router wired with the retaining stub container and a durable
    /// recordings root — pass the first router's `id` and `recorder` to
    /// simulate a fresh process continuing the same recording root.
    private static func makeRouter(
        id: ULID = .generate(),
        container: RetainingLLMContainer,
        recorder: JSONLRecorder,
        cacheDir: URL,
        recordingsDir: URL
    ) -> Router {
        Router(
            id: id,
            maxConcurrentForks: 4,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            probe: RouterTestFixtures.stubProbe,
            metadataSource: StubMetadataSource(raw: RouterTestFixtures.rawMetadata),
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
    }

    /// A router id's recording root under `recordingsDir`.
    private static func routerDirectory(routerId: ULID, recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(routerId.description, isDirectory: true)
    }

    /// Decodes a fork's `session.json` as a raw JSON object, so a test can
    /// assert on the literal keys a sidecar carries.
    private static func sidecarJSON(at sidecarURL: URL) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
    }

    /// The `session.json` URL of `forkId`, nested under its `rootId` parent.
    private static func forkSidecarURL(routerDirectory: URL, rootId: ULID, forkId: ULID) -> URL {
        routerDirectory
            .appendingPathComponent(rootId.description, isDirectory: true)
            .appendingPathComponent(forkId.description, isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
    }

    /// The entry ids of `sessionId`'s own recorded entry events, in order —
    /// what the session itself appended after its fork cut.
    private static func ownRecordedEntryIds(in tree: TranscriptTree, sessionId: ULID) throws -> [String] {
        try tree.events(forSession: sessionId).compactMap { $0.entry?.entryId }
    }

    // MARK: - Live fold, then fork, then restore

    @Test("a fork taken after its parent folded restores the fold's live window plus its own entries, never the pre-fold span")
    @MainActor
    func restoredForkAfterParentFoldMatchesItsLiveTranscript() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "ForkAfterCompactionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "ForkAfterCompactionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recorder = JSONLRecorder(directory: recordingsDir)
        let container = RetainingLLMContainer(responseText: Self.cannedText)
        let router1 = Self.makeRouter(
            container: container, recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        // Parent records N turns, then folds deterministically: the derived
        // budget's target sits where TurnTruncation alone lands under it.
        let root = profile1.standard.makeSession()
        try await driveTurns(6, on: root)
        let rootBackend = try #require(container.lastBackend)
        let result = try await root.compact(budget: deterministicFoldBudget(for: rootBackend.transcriptEntries()))
        #expect(!result.stagesApplied.isEmpty)

        let fork = try await root.fork(workingDirectory: nil)

        // The fork's cut in history coordinates: how many entry-kind events
        // the parent's recorded history holds at fork time — the raw,
        // unfolded count, boundary entry included.
        let routerDirectory = Self.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        let entryEventCountAtFork = try TranscriptTree.load(under: routerDirectory)
            .effectiveEntryEvents(forSession: root.id).count

        // Both continue after the fork: the parent's later turns must never
        // leak into the fork's restored conversation.
        _ = try await fork.respond(to: "fork continues after the fold")
        _ = try await root.respond(to: "root continues after the fork")

        let tree = try TranscriptTree.load(under: routerDirectory)

        // The fold's checkpoint governs the fork's restore: it sits inside
        // the fork's inherited span, before the cut.
        let checkpoint = try #require(
            TranscriptTree.newestCompactionCheckpoint(in: tree.effectiveEntryEvents(forSession: fork.id)))

        // Entry-for-entry equality with the fork's live transcript: the live
        // fork was seeded from the parent's post-fold window (exactly the
        // checkpoint's own live-window ids, boundary included) and then
        // appended its own turn's entries (exactly what its own file records).
        let forkOwnIds = try Self.ownRecordedEntryIds(in: tree, sessionId: fork.id)
        #expect(!forkOwnIds.isEmpty)
        let restoredForkIds = try tree.effectiveTranscript(forSession: fork.id).map(\.id)
        #expect(restoredForkIds == checkpoint.content.liveWindowEntryIds + forkOwnIds)

        // No resurrected pre-fold span: nothing the fold discarded comes back.
        #expect(Set(checkpoint.content.foldedEntryIds).isDisjoint(with: restoredForkIds))

        // The fork's sidecar records the cut in history coordinates alongside
        // the legacy positional baseline (which stays the post-fold backend
        // count, for readers that predate the new field).
        let sidecar = try Self.sidecarJSON(
            at: Self.forkSidecarURL(routerDirectory: routerDirectory, rootId: root.id, forkId: fork.id))
        #expect(sidecar["forkedAtHistoryOrdinal"] as? Int == entryEventCountAtFork)
        #expect(sidecar["forkedAtEntryCount"] as? Int == checkpoint.content.liveWindowEntryIds.count)

        // The whole tree restores as live sessions in a fresh process.
        let router2 = Self.makeRouter(
            id: router1.id, container: RetainingLLMContainer(responseText: Self.cannedText),
            recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        #expect(restored.session(fork.id) != nil)
    }

    // MARK: - Restore a compacted root, then fork it

    @Test("a fork taken off a restored, previously compacted root restores the restored root's window plus its own entries")
    @MainActor
    func forkOffARestoredCompactedRootRestoresTheCheckpointWindow() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "ForkAfterCompactionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "ForkAfterCompactionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recorder = JSONLRecorder(directory: recordingsDir)
        let container = RetainingLLMContainer(responseText: Self.cannedText)
        let router1 = Self.makeRouter(
            container: container, recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        // A root that folds and then keeps going, so its recorded history
        // carries a checkpoint with entries after it.
        let root = profile1.standard.makeSession()
        try await driveTurns(6, on: root)
        let rootBackend = try #require(container.lastBackend)
        let result = try await root.compact(budget: deterministicFoldBudget(for: rootBackend.transcriptEntries()))
        #expect(!result.stagesApplied.isEmpty)
        _ = try await root.respond(to: "root turn after the fold")

        // Fresh process: restore the compacted root, then fork it.
        let router2 = Self.makeRouter(
            id: router1.id, container: RetainingLLMContainer(responseText: Self.cannedText),
            recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        // What the restored root was seeded with — the checkpoint's live
        // window plus everything recorded after it. The fork taken next
        // inherits exactly this conversation.
        let routerDirectory = Self.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        let restoredRootIds = try TranscriptTree.load(under: routerDirectory)
            .effectiveTranscript(forSession: root.id).map(\.id)

        let fork = try await restored.root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "fork off the restored root")
        _ = try await restored.root.respond(to: "restored root continues after the fork")

        let tree = try TranscriptTree.load(under: routerDirectory)
        let checkpoint = try #require(
            TranscriptTree.newestCompactionCheckpoint(in: tree.effectiveEntryEvents(forSession: fork.id)))
        let forkOwnIds = try Self.ownRecordedEntryIds(in: tree, sessionId: fork.id)
        #expect(!forkOwnIds.isEmpty)
        let restoredForkIds = try tree.effectiveTranscript(forSession: fork.id).map(\.id)
        #expect(restoredForkIds == restoredRootIds + forkOwnIds)
        #expect(Set(checkpoint.content.foldedEntryIds).isDisjoint(with: restoredForkIds))

        // And the grown tree still restores end-to-end.
        let router3 = Self.makeRouter(
            id: router1.id, container: RetainingLLMContainer(responseText: Self.cannedText),
            recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile3 = try await router3.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restoredAgain = try await profile3.standard.restoreSessionTree(root: root.id)
        #expect(restoredAgain.session(fork.id) != nil)
    }

    // MARK: - Old recordings keep restoring through the legacy cut field

    @Test("a fork sidecar with no forkedAtHistoryOrdinal key (an old recording) still restores through forkedAtEntryCount")
    @MainActor
    func oldRecordingWithoutHistoryOrdinalRestoresThroughTheLegacyCutField() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "ForkAfterCompactionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "ForkAfterCompactionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recorder = JSONLRecorder(directory: recordingsDir)
        let container = RetainingLLMContainer(responseText: Self.cannedText)
        let router1 = Self.makeRouter(
            container: container, recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile1 = try await router1.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        // An unfolded parent: for a recording with no fold before the fork,
        // the legacy positional count and the history-coordinate cut agree,
        // which is exactly why old recordings keep restoring correctly.
        let root = profile1.standard.makeSession()
        _ = try await root.respond(to: "remember 42")
        let fork = try await root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "fork turn")

        // Rewrite the fork's sidecar without the new key, simulating a
        // recording written before the field existed.
        let routerDirectory = Self.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        let sidecarURL = Self.forkSidecarURL(
            routerDirectory: routerDirectory, rootId: root.id, forkId: fork.id)
        var json = try Self.sidecarJSON(at: sidecarURL)
        json.removeValue(forKey: "forkedAtHistoryOrdinal")
        try FileManager.default.removeItem(at: sidecarURL)
        try JSONSerialization.data(withJSONObject: json).write(to: sidecarURL)

        // The legacy field alone still yields the whole effective
        // conversation: root's turn at fork time plus the fork's own turn.
        let tree = try TranscriptTree.load(under: routerDirectory)
        let expectedIds =
            try tree.effectiveTranscript(forSession: root.id).map(\.id)
            + Self.ownRecordedEntryIds(in: tree, sessionId: fork.id)
        #expect(try tree.effectiveTranscript(forSession: fork.id).map(\.id) == expectedIds)

        let router2 = Self.makeRouter(
            id: router1.id, container: RetainingLLMContainer(responseText: Self.cannedText),
            recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        #expect(restored.session(fork.id) != nil)
    }
}
