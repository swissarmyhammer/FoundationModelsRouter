import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^810gdjj: restore fidelity for rich content, repeated
/// folds, and driven forks — always-run, no GPU, no gated suites.
///
/// Three gaps close here, each against a real `Router` recording through a
/// `JSONLRecorder` into a temp directory:
///
/// 1. **Rich content through the full disk path.** A scripted tool turn —
///    one multi-call round, a `.structure` tool-output segment, and a
///    `.reasoning` entry — runs through the production
///    ``MLXFoundationModelsSessionBackend``, is reconstructed from disk, and
///    must equal the live transcript's record-time canonical form entry for
///    entry (see ``canonicalized(_:)`` for the three live-only facets no
///    persisted form can keep). The transcript carries all six entry kinds.
/// 2. **Multi-fold restore.** A live session folds twice through the
///    model-assisted `Summarization` stage (the stub backend is the scripted
///    summarizer), and the restored transcript must equal the live
///    post-second-fold transcript — both through ``TranscriptTree`` and
///    through a fresh-process `restoreSessionTree(root:)`.
/// 3. **Driven restored forks.** A restored fork answers a new turn with
///    content that exists only in an entry it inherited from its parent, so
///    semantic continuity is proven without the integration gate.
@Suite("Restore fidelity: rich content, multi-fold, driven forks (task ^810gdjj)")
struct RestoreFidelityTests {
    // MARK: - Fixtures

    /// The temp-directory prefix, so a leaked directory is attributable.
    private static let tempDirPrefix = "RestoreFidelityTests"

    /// A long-ish canned response, repeated across every stub turn, so six
    /// turns' worth of transcript carries a real byte-size estimate for the
    /// fold-budget derivation — the same shape
    /// `ForkAfterCompactionRestorationTests` uses.
    private static let cannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// How many warm-up turns each fold needs: more than
    /// ``defaultKeepRecentTurns``, so turns older than the untouchable
    /// recency window exist for the fold to work on.
    private static let foldWarmupTurnCount = 6

    /// The factor a summarization-forcing budget's `limit` scales the
    /// recency-window-only estimate by, mirroring
    /// `RoutedSessionCompactTests`' budget shape.
    private static let summarizationBudgetLimitFactor = 2

    /// The summarization-forcing budget's `target` fraction: applied to a
    /// limit of `recencyOnly * 2` it lands the target at half the
    /// recency-window floor, which no deterministic stage can reach — so
    /// the model-assisted `Summarization` stage must run.
    private static let summarizationBudgetTarget = 0.25

    /// The step name the structured tool call in the rich-content turn
    /// names, distinct from ``ScriptedToolFixture/firstStepName`` so the
    /// two calls in the round stay distinguishable by content.
    private static let structuredStepName = "TWO"

    /// A budget that forces the model-assisted `Summarization` stage:
    /// its target sits strictly under `entries`' recency-window-only floor,
    /// which no deterministic stage can fold below.
    ///
    /// - Parameter entries: The live transcript entries about to be folded.
    /// - Returns: The budget to pass to `compact(budget:)`.
    private static func summarizationForcingBudget(for entries: [Transcript.Entry]) -> TokenBudget {
        TokenBudget(
            limit: recencyWindowOnlyEstimate(entries) * summarizationBudgetLimitFactor,
            target: summarizationBudgetTarget
        )
    }

    /// A ``LoadedLLMContainer`` vending ``StubSessionBackend``s that record
    /// themselves — and every clone a fold creates — into one shared
    /// ``StubBackendRegistry``, so a test can reach the live post-fold
    /// backend a fold's `replacingTranscript(_:)` swap installs.
    private struct RegisteringStubContainer: LoadedLLMContainer {
        /// The canned text every backend this container vends responds with.
        let responseText: String

        /// The registry every vended backend and clone records into.
        let registry: StubBackendRegistry

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(
                responseText: responseText, instructions: instructions, registry: registry)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(
                responseText: responseText, entries: Array(transcript), registry: registry)
        }
    }

    /// A router's recording root under `recordingsDir`.
    ///
    /// - Parameters:
    ///   - router: The router whose root to name.
    ///   - recordingsDir: The durable transcripts root.
    /// - Returns: The directory ``TranscriptTree/load(under:)`` reads.
    private static func routerDirectory(router: Router, recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(router.id.description, isDirectory: true)
    }

    /// `entries` in record-time canonical form: each mapped to its on-disk
    /// payload and rebuilt, in memory — exactly what recording keeps of a
    /// live entry, with no disk in the loop.
    ///
    /// Three facets of a LIVE entry are not representable on disk today, so
    /// a reconstruction cannot equal the raw live transcript whenever a tool
    /// call ran (task ^ja94kb6 tracks the two fixable ones):
    /// - a live tool call's `arguments` carry a `GenerationID`, and
    ///   `GenerationID` has no value-preserving public constructor, so no
    ///   persisted form can rebuild it (permanent);
    /// - a live structured segment's `GeneratedContent` carries its property
    ///   order, which the mapper's `GeneratedContent(json:)` rebuild drops
    ///   (fixable);
    /// - a rebuilt `.response` synthesizes a `metadata["assetIDs"]` key a
    ///   live generated response never carries (fixable).
    ///
    /// Comparing a disk reconstruction against this form still holds every
    /// entry, every segment, and every persisted field to full equality, and
    /// any loss on the disk path itself — encode, JSONL, decode, checkpoint
    /// stitching — fails the comparison, because this form never touches
    /// disk.
    ///
    /// - Parameter entries: The live transcript entries to canonicalize.
    /// - Returns: The entries the mapper's round trip keeps, in order.
    /// - Throws: Whatever the mapper's rebuild throws.
    private static func canonicalized(_ entries: [Transcript.Entry]) throws -> [Transcript.Entry] {
        try entries.map { entry in
            let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
            return try TranscriptEntryMapper.entry(from: payload, kind: kind)
        }
    }

    // MARK: - 1. Rich content through the full disk path

    @Test("a scripted tool turn (multi-call, .structure output, .reasoning) restores from disk equal to the live transcript's canonical form, across all six entry kinds")
    @MainActor
    func richToolTurnRestoresFromDiskEqualToLiveTranscript() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // One round asking for two calls at once: a text-output marker tool
        // and a structured-output marker tool, then a `.reasoning` entry
        // before the final answer.
        let script = ScriptedTurnScript(
            rounds: [
                [
                    ScriptedToolCall(
                        id: "call-text",
                        toolName: MarkerEmittingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName)
                    ),
                    ScriptedToolCall(
                        id: "call-structured",
                        toolName: StructuredMarkerTool.toolName,
                        argument: .literal(Self.structuredStepName)
                    ),
                ]
            ],
            reasoning: "scripted reasoning before the final answer"
        )
        let container = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: script, log: ScriptedTurnLog()))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        let session = profile.standard.makeSession(
            instructions: "You are a restore-fidelity test assistant.",
            tools: [MarkerEmittingTool(), StructuredMarkerTool()]
        )
        _ = try await session.respond(to: ScriptedToolFixture.prompt)

        let liveBackend = try #require(container.vendedBackends.latest)
        let live = liveBackend.transcriptEntries()

        // Shape sanity before the equality claim: the live transcript
        // carries all six entry kinds...
        let kinds = live.map { TranscriptEntryMapper.event(from: $0).kind }
        #expect(
            Set(kinds).isSuperset(of: [
                .instructions, .prompt, .toolCalls, .toolOutput, .reasoning, .response,
            ]))
        // ...one `.toolCalls` entry holding both calls of the round...
        let multiCallEntry = live.compactMap { entry -> Transcript.ToolCalls? in
            guard case .toolCalls(let calls) = entry else { return nil }
            return calls
        }.first
        #expect(multiCallEntry?.count == 2)
        // ...and a `.toolOutput` entry whose segment is `.structure`.
        let hasStructuredToolOutput = live.contains { entry in
            guard case .toolOutput(let output) = entry else { return false }
            return output.segments.contains { segment in
                if case .structure = segment { return true }
                return false
            }
        }
        #expect(hasStructuredToolOutput)

        // The payoff: the transcript reconstructed from disk equals the
        // live transcript's record-time canonical form, entry for entry —
        // the text tests' entry-array equality check, now over rich content.
        // Raw live equality is unreachable for a tool turn: see
        // ``canonicalized(_:)`` for the three live-only facets no persisted
        // form can keep, and task ^ja94kb6 for the two fixable ones.
        let tree = try TranscriptTree.load(
            under: Self.routerDirectory(router: router, recordingsDir: recordingsDir))
        let reconstructed = try tree.effectiveTranscript(forSession: session.id)
        #expect(Array(reconstructed) == (try Self.canonicalized(live)))
    }

    // MARK: - 2. Fold a live session twice, then restore

    @Test("a session folded twice through the scripted summarizer restores equal to the live post-second-fold transcript")
    @MainActor
    func doubleFoldedSessionRestoresEqualToLiveTranscript() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recorder = JSONLRecorder(directory: recordingsDir)
        let registry = StubBackendRegistry()
        let container = RegisteringStubContainer(responseText: Self.cannedText, registry: registry)
        let router1 = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile1 = try await router1.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        // First fold: warm up past the recency window, then force the
        // model-assisted Summarization stage — the stub backend's canned
        // response is the scripted summary.
        let root = profile1.standard.makeSession()
        try await driveTurns(Self.foldWarmupTurnCount, on: root)
        let firstFoldBackend = try #require(registry.created.last)
        let firstResult = try await root.compact(
            budget: Self.summarizationForcingBudget(for: firstFoldBackend.transcriptEntries()))
        #expect(firstResult.stagesApplied.contains("Summarization"))

        // Second fold: more turns on the already-folded session, then fold
        // again — the fixed checkpoint semantics (^h1008kb, ^6z1msg1) must
        // hold across repeated live folds, not just one.
        try await driveTurns(Self.foldWarmupTurnCount, on: root)
        let secondFoldBackend = try #require(registry.created.last)
        let secondResult = try await root.compact(
            budget: Self.summarizationForcingBudget(for: secondFoldBackend.transcriptEntries()))
        #expect(secondResult.stagesApplied.contains("Summarization"))

        // One post-fold turn, so the restore must stitch the second
        // checkpoint's live window together with entries recorded after it.
        _ = try await root.respond(to: "turn after the second fold")

        // The live post-second-fold transcript: the swap clone the second
        // fold installed is the last backend the registry saw, and the
        // post-fold turn appended into it in place.
        let liveBackend = try #require(registry.created.last)
        let live = liveBackend.transcriptEntries()
        #expect(liveBackend !== firstFoldBackend)

        // Restore path 1: the reconstructed transcript equals the live one,
        // entry for entry.
        let routerDirectory = Self.routerDirectory(router: router1, recordingsDir: recordingsDir)
        let tree = try TranscriptTree.load(under: routerDirectory)
        #expect(Array(try tree.effectiveTranscript(forSession: root.id)) == live)

        // Restore path 2: a fresh process restores the session as a live
        // one, and the backend it is seeded with carries the same entries.
        let registry2 = StubBackendRegistry()
        let container2 = RegisteringStubContainer(responseText: Self.cannedText, registry: registry2)
        let router2 = RouterTestFixtures.makeRouter(
            id: router1.id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            loader: StubModelLoader(container: container2, dimension: RouterTestFixtures.stubDimension)
        )
        let profile2 = try await router2.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: root.id)
        #expect(restored.root.id == root.id)
        let restoredBackend = try #require(registry2.created.last)
        #expect(restoredBackend.transcriptEntries() == live)
    }

    // MARK: - 3. Drive a restored fork whose reply depends on inherited entries

    @Test("a restored fork's new turn answers with content that exists only in an entry inherited from its parent")
    @MainActor
    func restoredForkAnswersFromInheritedParentEntries() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // The parent's turn calls the marker tool once; the fixture's
        // scripted model composes every answer from the tool outputs the
        // transcript carries, never from a canned string.
        let script = ScriptedTurnScript(
            rounds: [
                [
                    ScriptedToolCall(
                        id: "call-one",
                        toolName: MarkerEmittingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName)
                    )
                ]
            ]
        )
        let inheritedAnswer = ScriptedToolFixture.answer(
            fromToolOutputs: [ScriptedToolFixture.marker(for: ScriptedToolFixture.firstStepName)])

        let recorder = JSONLRecorder(directory: recordingsDir)
        let container1 = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: script, log: ScriptedTurnLog()))
        let router1 = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            loader: StubModelLoader(container: container1, dimension: RouterTestFixtures.stubDimension)
        )
        let profile1 = try await router1.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        let parent = profile1.standard.makeSession(tools: [MarkerEmittingTool()])
        let parentReply = try await parent.respond(to: ScriptedToolFixture.prompt)
        #expect(parentReply == inheritedAnswer)

        let fork = try await parent.fork(workingDirectory: nil)

        // The marker lives only in the parent's recorded span: the fork's
        // own file records no tool output at all, so a reply carrying the
        // marker can only come from inherited entries.
        let routerDirectory = Self.routerDirectory(router: router1, recordingsDir: recordingsDir)
        let forkOwnEvents = try TranscriptTree.load(under: routerDirectory)
            .events(forSession: fork.id)
        #expect(!forkOwnEvents.contains { $0.kind == .toolOutput })

        // A fresh process restores the tree. The restored fork's transcript
        // already carries the parent's one tool-calling round, so the
        // scripted model's very next turn is the answering turn — composed
        // from whatever `.toolOutput` entries the restored session was
        // actually seeded with.
        let log2 = ScriptedTurnLog()
        let container2 = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: script, log: log2))
        let router2 = RouterTestFixtures.makeRouter(
            id: router1.id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            loader: StubModelLoader(container: container2, dimension: RouterTestFixtures.stubDimension)
        )
        let profile2 = try await router2.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: parent.id)
        let restoredFork = try #require(restored.session(fork.id))

        let reply = try await restoredFork.respond(to: "tell me what the tool told you earlier")
        #expect(reply == inheritedAnswer)

        // And the answering generation really read the inherited output out
        // of the transcript it was handed — semantic continuity, not a
        // coincidence of canned text.
        #expect(
            log2.deliveredToolOutputs == [
                ScriptedToolFixture.marker(for: ScriptedToolFixture.firstStepName)
            ])
    }
}
