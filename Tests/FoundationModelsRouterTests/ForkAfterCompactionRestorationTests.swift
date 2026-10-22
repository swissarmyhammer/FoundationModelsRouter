import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^6z1msg1: a fork's cut point is recorded in append-only
/// history coordinates, so a fork taken after its parent compacted restores the
/// compaction's live window plus the fork's own entries — never the pre-compaction span
/// the compaction discarded.
///
/// Compaction is append-only: a compaction appends one boundary entry carrying its
/// ``CompactionSegment`` checkpoint and rewinds only the *backend*'s
/// positional diff baseline, never the session's position in its own
/// recorded history. A fork's cut must therefore be recorded in the recorded
/// history's own coordinates. Before this task, `fork()` recorded the
/// post-compaction backend entry count instead, so a restored fork rebuilt the
/// oldest pre-compaction entries and cut off the checkpoint.
///
/// Everything runs against stubs — a ``StubSessionBackend``-backed container
/// and a ``JSONLRecorder`` in a temp directory — mirroring
/// `SessionTreeRestorationTests`' fresh-process simulation: a second,
/// independently constructed `Router` pointed at the same id and recordings
/// root restores what the first recorded.
@Suite("Fork cuts in append-only history coordinates")
struct ForkAfterCompactionRestorationTests {
    // MARK: - Fixtures

    /// A canned response, repeated across every answer and given as the answer
    /// of the summarizer call. Six answers of it are much larger than one copy,
    /// so the summary makes the live context smaller.
    private static let cannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// How many answers a root gives before it compacts: enough copies of
    /// ``cannedText`` that the one summary makes the live context smaller.
    private static let answersBeforeCompaction = 6

    /// Builds a router wired with the retaining stub container and a durable
    /// recordings root — pass the first router's `id` and `recorder` to
    /// simulate a fresh process continuing the same recording root.
    private static func makeRouter(
        id: ULID = .generate(),
        container: RetainingLLMContainer,
        recorder: JSONLRecorder,
        cacheDir: URL,
        recordingsDir: URL,
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            probe: RouterTestFixtures.stubProbe,
            metadataSource: StubMetadataSource(raw: RouterTestFixtures.rawMetadata),
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension),
            pool: pool
        )
    }

    /// The entry ids of `sessionId`'s own recorded entry events, in order —
    /// what the session itself appended after its fork cut.
    private static func ownRecordedEntryIds(in tree: TranscriptTree, sessionId: ULID) throws -> [String] {
        // Only entry-kind events: a `.mail` event also holds an entry payload,
        // but it is no entry of the transcript.
        try tree.events(forSession: sessionId).filter(\.kind.isEntryKind).compactMap { $0.entry?.entryId }
    }

    // MARK: - Live compaction, then fork, then restore

    /// A fork taken after its parent compacted restores the checkpoint's
    /// live window plus its own entries, and its record holds the cut in
    /// both coordinates.
    @Test("a fork taken after its parent compacted restores the compaction's live window plus its own entries, never the pre-compaction span")
    @MainActor
    func restoredForkAfterParentCompactionMatchesItsLiveTranscript() async throws {
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

        // Parent records N answers, then compacts: the derived budget's target
        // is under the live context, so the one summarizer call runs.
        let root = profile1.standard.makeSession()
        defer { await root.close() }
        try await driveAnswers(Self.answersBeforeCompaction, on: root)
        let rootBackend = try #require(container.lastBackend)
        let result = try await root.compactAndAwait(budget: summarizingCompactionBudget(for: rootBackend.transcriptEntries()))
        #expect(result.stagesApplied == [Summarization.stageName])

        let fork = try await root.fork(workingDirectory: nil)
        defer { await fork.close() }

        // The fork's cut in history coordinates: how many entry-kind events
        // the parent's recorded history holds at fork time — the raw,
        // uncompacted count, boundary entry included.
        let routerDirectory = RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        let entryEventCountAtFork = try TranscriptTree.load(under: routerDirectory)
            .effectiveEntryEvents(forSession: root.id).count

        // Both continue after the fork: the later answers of the parent must never
        // leak into the fork's restored conversation.
        _ = try await fork.respond(to: "fork continues after the compaction")
        _ = try await root.respond(to: "root continues after the fork")

        let tree = try TranscriptTree.load(under: routerDirectory)

        // The compaction's checkpoint governs the fork's restore: it sits inside
        // the fork's inherited span, before the cut.
        let checkpoint = try #require(
            TranscriptTree.newestCompactionCheckpoint(in: tree.effectiveEntryEvents(forSession: fork.id)))

        // Entry-for-entry equality with the fork's live transcript: the live
        // fork was seeded from the parent's post-compaction window (exactly the
        // checkpoint's own live-window ids, boundary included) and then
        // appended the entries of its own answer (exactly what its own file records).
        let forkOwnIds = try Self.ownRecordedEntryIds(in: tree, sessionId: fork.id)
        #expect(!forkOwnIds.isEmpty)
        let restoredForkIds = try tree.effectiveTranscript(forSession: fork.id).map(\.id)
        #expect(restoredForkIds == checkpoint.content.liveWindowEntryIds + forkOwnIds)

        // No resurrected pre-compaction span: nothing the compaction discarded comes back.
        #expect(Set(checkpoint.content.compactedEntryIds).isDisjoint(with: restoredForkIds))

        // The fork's record holds the cut in history coordinates beside the
        // positional baseline, which stays the post-compaction backend count.
        let forkRecord = try #require(
            try SessionIndexFile.read(
                in: RouterTestFixtures.sessionDirectory(
                    of: root.id, fork.id, routerId: router1.id, recordingsDir: recordingsDir)))
        #expect(forkRecord.forkedAtHistoryOrdinal == entryEventCountAtFork)
        #expect(forkRecord.forkedAtEntryCount == checkpoint.content.liveWindowEntryIds.count)

        // The whole tree restores as live sessions in a fresh process.
        let router2 = Self.makeRouter(
            id: router1.id, container: RetainingLLMContainer(responseText: Self.cannedText),
            recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer {
            await restored.root.close()
            await restored.session(fork.id)?.close()
        }
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

        // A root that compacts and then keeps going, so its recorded history
        // carries a checkpoint with entries after it.
        let root = profile1.standard.makeSession()
        defer { await root.close() }
        try await driveAnswers(Self.answersBeforeCompaction, on: root)
        let rootBackend = try #require(container.lastBackend)
        let result = try await root.compactAndAwait(budget: summarizingCompactionBudget(for: rootBackend.transcriptEntries()))
        #expect(result.stagesApplied == [Summarization.stageName])
        _ = try await root.respond(to: "root answer after the compaction")

        // Fresh process: restore the compacted root, then fork it.
        let router2 = Self.makeRouter(
            id: router1.id, container: RetainingLLMContainer(responseText: Self.cannedText),
            recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        defer { await restored.root.close() }

        // What the restored root was seeded with — the checkpoint's live
        // window plus everything recorded after it. The fork taken next
        // inherits exactly this conversation.
        let routerDirectory = RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        let restoredRootIds = try TranscriptTree.load(under: routerDirectory)
            .effectiveTranscript(forSession: root.id).map(\.id)

        let fork = try await restored.root.fork(workingDirectory: nil)
        defer { await fork.close() }
        _ = try await fork.respond(to: "fork off the restored root")
        _ = try await restored.root.respond(to: "restored root continues after the fork")

        let tree = try TranscriptTree.load(under: routerDirectory)
        let checkpoint = try #require(
            TranscriptTree.newestCompactionCheckpoint(in: tree.effectiveEntryEvents(forSession: fork.id)))
        let forkOwnIds = try Self.ownRecordedEntryIds(in: tree, sessionId: fork.id)
        #expect(!forkOwnIds.isEmpty)
        let restoredForkIds = try tree.effectiveTranscript(forSession: fork.id).map(\.id)
        #expect(restoredForkIds == restoredRootIds + forkOwnIds)
        #expect(Set(checkpoint.content.compactedEntryIds).isDisjoint(with: restoredForkIds))

        // And the grown tree still restores end-to-end.
        let router3 = Self.makeRouter(
            id: router1.id, container: RetainingLLMContainer(responseText: Self.cannedText),
            recorder: recorder, cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile3 = try await router3.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restoredAgain = try await profile3.standard.restoreSessionTree(root: root.id)
        defer {
            await restoredAgain.root.close()
            await restoredAgain.session(fork.id)?.close()
        }
        #expect(restoredAgain.session(fork.id) != nil)
    }
}
