import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^tcep2pc: a session restored from disk restores the context
/// counter that the live session had at the same point.
///
/// The live counter is the size of the render: the fed and generated tokens
/// of the newest generation call of the newest submission that recorded a
/// `.response` (task ^tpsc0nf). A compaction restarts it. The `.response`
/// stamp of a submission is the sum of the calls of the attempt, which is the
/// cost of the attempt and not a size of the render. So the restore reads the
/// `.generationCall` event that closes the newest stamped `.response`. It
/// reads the stamp only for an old journal, which records no call.
@Suite("Restored render counter: the newest generation call, not the sum on the response stamp")
struct RestoredRenderCounterTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "RestoredRenderCounterTests"

    /// The working context every session resolves at, so a fill is an exact
    /// fraction of a round number.
    private static let contextTokens = 1_000

    /// The scripted usage of the three calls of one tool-loop submission: two
    /// calls that ask for the tool, then the call that answers.
    private static let threeCalls = [
        MeteredGenerationCall(tokensIn: 100, tokensOut: 30),
        MeteredGenerationCall(tokensIn: 200, tokensOut: 50),
        MeteredGenerationCall(tokensIn: 300, tokensOut: 70),
    ]

    /// The prompt every live answer is driven with. The metered model never
    /// reads it.
    private static let prompt = "look things up, then tell me what you found"

    /// The size of the render after the last of ``threeCalls``.
    private static let lastCallContext = 370

    /// The compaction snapshot size every checkpoint fixture records.
    private static let snapshotTokens = 300

    // MARK: - Event fixtures

    /// The usage of a call of a later submission that asked for a tool, and
    /// then stopped before the submission recorded its entries. It is larger
    /// than any call of ``threeCalls``, so a reader that reads it gives a wrong
    /// count.
    private static let unfinishedCall = MeteredGenerationCall(tokensIn: 900, tokensOut: 40)

    /// The ids every synthetic event of one journal carries.
    private struct JournalIds {
        /// The session the events belong to.
        let sessionId: ULID

        /// The router that owns the recording.
        let routerId: ULID

        /// Creates the ids of one journal.
        ///
        /// - Parameters:
        ///   - sessionId: The session the events belong to. Defaults to a new id.
        ///   - routerId: The router that owns the recording. Defaults to a new id.
        init(sessionId: ULID = .generate(), routerId: ULID = .generate()) {
            self.sessionId = sessionId
            self.routerId = routerId
        }
    }

    /// Builds the `.generationCall` event of ``unfinishedCall``.
    ///
    /// - Parameters:
    ///   - seq: The sequence number of the event.
    ///   - ids: The ids of the journal.
    /// - Returns: The event.
    private static func unfinishedCallEvent(seq: Int, ids: JournalIds) -> TranscriptEvent {
        generationCallEvent(
            seq: seq, ids: ids, tokensIn: unfinishedCall.tokensIn, tokensOut: unfinishedCall.tokensOut)
    }

    /// Builds a `.generationCall` event with the counts of one call.
    ///
    /// - Parameters:
    ///   - seq: The sequence number of the event.
    ///   - ids: The ids of the journal.
    ///   - tokensIn: The fed tokens of the call.
    ///   - tokensOut: The generated tokens of the call.
    /// - Returns: The event.
    private static func generationCallEvent(
        seq: Int, ids: JournalIds, tokensIn: Int, tokensOut: Int
    ) -> TranscriptEvent {
        TranscriptEvent(
            routerId: ids.routerId,
            sessionId: ids.sessionId,
            seq: seq,
            ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .generationCall,
            text: "fed \(tokensIn) tokens, generated \(tokensOut) tokens",
            tokensIn: tokensIn,
            tokensOut: tokensOut
        )
    }

    /// Builds an entry-kind event with one text segment and, when both
    /// counts are given, the usage stamp of a submission.
    ///
    /// - Parameters:
    ///   - kind: The entry kind of the event.
    ///   - seq: The sequence number of the event.
    ///   - ids: The ids of the journal.
    ///   - tokensIn: The stamped input tokens, or `nil` for no stamp.
    ///   - tokensOut: The stamped output tokens, or `nil` for no stamp.
    /// - Returns: The event.
    private static func entryEvent(
        _ kind: TranscriptEvent.Kind, seq: Int, ids: JournalIds, tokensIn: Int? = nil, tokensOut: Int? = nil
    ) -> TranscriptEvent {
        let entryId = "\(kind.rawValue)-\(seq)"
        return TranscriptEvent(
            routerId: ids.routerId,
            sessionId: ids.sessionId,
            seq: seq,
            ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: kind,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            entry: TranscriptEntryPayload(
                entryId: entryId,
                segments: [.text(id: "\(entryId)-text", content: "text of \(entryId)")],
                assetIds: []
            )
        )
    }

    /// Builds a compaction checkpoint event that records ``snapshotTokens``.
    ///
    /// - Parameters:
    ///   - seq: The sequence number of the event.
    ///   - ids: The ids of the journal.
    /// - Returns: The event.
    /// - Throws: Whatever encoding the checkpoint content throws.
    private static func checkpointEvent(seq: Int, ids: JournalIds) throws -> TranscriptEvent {
        try TranscriptFixtures.compactionCheckpointEvent(
            seq: seq,
            sessionId: ids.sessionId,
            routerId: ids.routerId,
            entryId: "checkpoint-\(seq)",
            content: CompactionSegment.Content(
                liveWindowEntryIds: ["checkpoint-\(seq)"],
                compactedEntryIds: [],
                tokensBefore: contextTokens,
                tokensAfter: snapshotTokens,
                stagesApplied: ["Summarization"],
                promptName: "default"
            )
        )
    }

    /// The journal of one tool-loop submission in the order the session
    /// records it: the two calls that ask for the tool at each tool open, then
    /// the entries of the attempt with the sum of the calls stamped on the
    /// `.response`, then the call that answered.
    ///
    /// - Parameters:
    ///   - firstSeq: The sequence number of the first event.
    ///   - ids: The ids of the journal.
    /// - Returns: The events, oldest first.
    private static func toolLoopSubmission(firstSeq: Int, ids: JournalIds) -> [TranscriptEvent] {
        let summedIn = threeCalls.map(\.tokensIn).reduce(0, +)
        let summedOut = threeCalls.map(\.tokensOut).reduce(0, +)
        return [
            generationCallEvent(
                seq: firstSeq, ids: ids, tokensIn: threeCalls[0].tokensIn, tokensOut: threeCalls[0].tokensOut),
            generationCallEvent(
                seq: firstSeq + 1, ids: ids, tokensIn: threeCalls[1].tokensIn, tokensOut: threeCalls[1].tokensOut),
            entryEvent(.prompt, seq: firstSeq + 2, ids: ids),
            entryEvent(.toolCalls, seq: firstSeq + 3, ids: ids),
            entryEvent(.toolOutput, seq: firstSeq + 4, ids: ids),
            entryEvent(.toolCalls, seq: firstSeq + 5, ids: ids),
            entryEvent(.toolOutput, seq: firstSeq + 6, ids: ids),
            entryEvent(.response, seq: firstSeq + 7, ids: ids, tokensIn: summedIn, tokensOut: summedOut),
            generationCallEvent(
                seq: firstSeq + 8, ids: ids, tokensIn: threeCalls[2].tokensIn, tokensOut: threeCalls[2].tokensOut),
        ]
    }

    // MARK: - The restored counter of one journal

    @Test("a journal with a tool loop of three calls restores the counter of the last call, not the sum on the response stamp")
    func toolLoopRestoresTheLastCall() {
        let ids = JournalIds()

        let state = TranscriptTree.restoredUsageState(in: Self.toolLoopSubmission(firstSeq: 0, ids: ids))

        #expect(state == .measured(input: Self.threeCalls[2].tokensIn, output: Self.threeCalls[2].tokensOut))
    }

    @Test("a journal with a compaction checkpoint and no call after it restores the tokensAfter of the checkpoint")
    func checkpointWithNoCallAfterItRestoresTokensAfter() throws {
        let ids = JournalIds()
        let submission = Self.toolLoopSubmission(firstSeq: 0, ids: ids)
        let checkpoint = try Self.checkpointEvent(seq: submission.count, ids: ids)

        let state = TranscriptTree.restoredUsageState(in: submission + [checkpoint])

        #expect(state == .measured(input: Self.snapshotTokens, output: 0))
    }

    @Test("an old journal with no generationCall event restores the response stamp as before")
    func oldJournalRestoresTheResponseStamp() {
        let ids = JournalIds()
        let journal = [
            Self.entryEvent(.prompt, seq: 0, ids: ids),
            Self.entryEvent(.response, seq: 1, ids: ids, tokensIn: 10, tokensOut: 5),
        ]

        #expect(TranscriptTree.restoredUsageState(in: journal) == .measured(input: 10, output: 5))
    }

    @Test("a call of a later submission that recorded no response does not move the restored counter, as it does not move the live one")
    func callOfASubmissionWithNoResponseIsNotRead() {
        let ids = JournalIds()
        let submission = Self.toolLoopSubmission(firstSeq: 0, ids: ids)
        // A later submission asked for a tool, and then the process stopped
        // before the submission recorded its entries. The live counter never
        // read this call.
        let unfinishedEvent = Self.unfinishedCallEvent(seq: submission.count, ids: ids)

        let state = TranscriptTree.restoredUsageState(in: submission + [unfinishedEvent])

        #expect(state == .measured(input: Self.threeCalls[2].tokensIn, output: Self.threeCalls[2].tokensOut))
    }

    @Test("a call after the checkpoint of a submission that recorded no response leaves the tokensAfter of the checkpoint")
    func callAfterCheckpointWithNoResponseLeavesTokensAfter() throws {
        let ids = JournalIds()
        let submission = Self.toolLoopSubmission(firstSeq: 0, ids: ids)
        let checkpoint = try Self.checkpointEvent(seq: submission.count, ids: ids)
        let unfinishedEvent = Self.unfinishedCallEvent(seq: submission.count + 1, ids: ids)

        let state = TranscriptTree.restoredUsageState(in: submission + [checkpoint, unfinishedEvent])

        #expect(state == .measured(input: Self.snapshotTokens, output: 0))
    }

    // MARK: - The live journal

    @Test("the journal a live tool-loop answer records restores the counter the live session reports")
    func liveJournalRestoresTheLiveCounter() async throws {
        let fixture = try await MeteredToolLoopSessionFixture.make(
            calls: Self.threeCalls, context: Self.contextTokens, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.session.respond(to: Self.prompt)

        let journal = await fixture.recorder.events
        let restored = TranscriptTree.restoredUsageState(in: journal)
        #expect(restored.measuredTokens == Self.lastCallContext)
        #expect(restored.fill(contextTokens: Self.contextTokens) == (await fixture.session.contextFill))
    }

    // MARK: - Restore from disk

    @Test("a restored root and its restored fork each report the live counter, and a later call of the root is not read")
    @MainActor
    func restoredRootAndForkReportTheLiveCounter() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
        let recorder = JSONLRecorder(directory: recordingsDir)
        let loader = StubModelLoader(
            container: LiveBackendContainer(model: MeteredToolLoopLanguageModel(calls: Self.threeCalls)),
            dimension: RouterTestFixtures.stubDimension)
        let router1 = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder, loader: loader)
        let profile1 = try await router1.resolve(
            profile: RouterTestFixtures.profile(context: Self.contextTokens), reporting: ResolutionProgress())

        let root = profile1.standard.makeSession(tools: [MarkerEmittingTool()])
        _ = try await root.respond(to: Self.prompt)
        let fork = try await root.fork(workingDirectory: nil)
        let liveFill = await root.contextFill
        #expect(liveFill == Double(Self.lastCallContext) / Double(Self.contextTokens))

        let routerDirectory = RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        try Self.appendUnfinishedCall(toSession: root.id, routerId: router1.id, under: routerDirectory)

        let router2 = RouterTestFixtures.makeRouter(
            id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder, loader: loader)
        let profile2 = try await router2.resolve(
            profile: RouterTestFixtures.profile(context: Self.contextTokens), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)

        #expect(await restored.root.contextFill == liveFill)
        let restoredFork = try #require(restored.session(fork.id))
        #expect(await restoredFork.contextFill == liveFill)
    }

    /// Appends to the recorded transcript of `sessionId` one call of a later
    /// submission that asked for a tool and then stopped before it recorded
    /// its entries, as a process that stops in a tool loop leaves it.
    ///
    /// - Parameters:
    ///   - sessionId: The session whose transcript gets the call.
    ///   - routerId: The router that owns the recording.
    ///   - routerDirectory: The recording root of the router.
    /// - Throws: Whatever reading or writing the transcript throws.
    private static func appendUnfinishedCall(toSession sessionId: ULID, routerId: ULID, under routerDirectory: URL)
        throws
    {
        let recorded = try TranscriptTree.load(under: routerDirectory).events(forSession: sessionId)
        let nextSeq = (recorded.map(\.seq).max() ?? 0) + 1
        let unfinishedEvent = unfinishedCallEvent(seq: nextSeq, ids: JournalIds(sessionId: sessionId, routerId: routerId))
        let transcriptURL = routerDirectory
            .appendingPathComponent(sessionId.description, isDirectory: true)
            .appendingPathComponent("transcript.jsonl", isDirectory: false)
        let existing = try String(contentsOf: transcriptURL, encoding: .utf8)
        let line = try #require(String(data: try JSONEncoder().encode(unfinishedEvent), encoding: .utf8))
        try (existing + line + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
    }
}
