import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^810gdjj: restore fidelity for rich content, repeated
/// compactions, and driven forks — always-run, no GPU, no gated suites.
///
/// Three gaps close here, each against a real `Router` recording through a
/// `JSONLRecorder` into a temp directory:
///
/// 1. **Rich content through the full disk path.** A scripted tool answer —
///    one multi-call round, a `.structure` tool-output segment, and a
///    `.reasoning` entry — runs through the production
///    ``MLXFoundationModelsSessionBackend``, is reconstructed from disk, and
///    must equal the live transcript's record-time canonical form entry for
///    entry (see ``canonicalized(_:)`` for the one live-only facet no
///    persisted form can keep). The transcript carries all six entry kinds.
/// 2. **Multi-compaction restore.** A live session compacts twice, each time
///    in one summarizer call (the stub backend is the scripted summarizer),
///    and the restored transcript must equal the live
///    post-second-compaction transcript — both through ``TranscriptTree`` and
///    through a fresh-process `restoreSessionTree(root:)`.
/// 3. **Driven restored forks.** A restored fork answers a new message with
///    content that exists only in an entry it inherited from its parent, so
///    semantic continuity is proven without the integration gate.
///
/// The warm-up answers and the compaction-budget floor come from the shared
/// compaction fixtures in `Helpers/CompactionFixtures.swift` —
/// ``driveAnswers(_:on:)`` and ``summarizingCompactionBudget(for:)`` — and the
/// recording root comes from
/// ``RouterTestFixtures/routerDirectory(routerId:recordingsDir:)``, so the
/// path rule and the compaction math live in exactly one place each.
@Suite("Restore fidelity: rich content, multi-compaction, driven forks (task ^810gdjj)")
struct RestoreFidelityTests {
    // MARK: - Fixtures

    /// The temp-directory prefix, so a leaked directory is attributable.
    private static let tempDirPrefix = "RestoreFidelityTests"

    /// A long-ish canned response, repeated across every stub answer, so six
    /// answers' worth of transcript carries a real byte-size estimate for the
    /// compaction-budget derivation — the same shape
    /// `ForkAfterCompactionRestorationTests` uses.
    private static let cannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// How many warm-up answers each compaction follows, so the live context
    /// holds many copies of ``cannedText`` for the summary to replace.
    private static let compactionWarmupAnswerCount = 6

    /// The step name the structured tool call in the rich-content answer
    /// names, distinct from ``ScriptedToolFixture/firstStepName`` so the
    /// two calls in the round stay distinguishable by content.
    private static let structuredStepName = "TWO"

    /// A ``LoadedLLMContainer`` vending ``StubSessionBackend``s that record
    /// themselves — and every clone a compaction creates — into one shared
    /// ``StubBackendRegistry``, so a test can reach the live post-compaction
    /// backend a compaction's `replacingTranscript(_:)` swap installs.
    private struct RegisteringStubContainer: LoadedLLMContainer {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

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

    /// `entries` with each `.toolCalls` entry — and only those — mapped to
    /// its on-disk payload and rebuilt, in memory: exactly what recording
    /// keeps of a live tool-call entry, with no disk in the loop.
    ///
    /// One facet of a LIVE entry is not representable on disk, so a
    /// reconstruction cannot equal the raw live transcript whenever a tool
    /// call ran: a live tool call's `arguments` carry a `GenerationID`, and
    /// `GenerationID` has no value-preserving public constructor, so no
    /// persisted form can rebuild it (permanent — see the mapper's
    /// documented degradations). Task ^ja94kb6 closed the other two facets
    /// this helper used to absorb (structure property order, a synthesized
    /// `metadata["assetIDs"]` key), so every non-`.toolCalls` entry is
    /// returned RAW and the comparison holds the reconstruction to full live
    /// equality for it.
    ///
    /// Comparing a disk reconstruction against this form holds every entry,
    /// every segment, and every persisted field to full equality, and any
    /// loss on the disk path itself — encode, JSONL, decode, checkpoint
    /// stitching — fails the comparison, because this form never touches
    /// disk.
    ///
    /// - Parameter entries: The live transcript entries to canonicalize.
    /// - Returns: The entries, with `.toolCalls` in the mapper's round-trip
    ///   form and every other entry untouched, in order.
    /// - Throws: Whatever the mapper's rebuild throws.
    private static func canonicalized(_ entries: [Transcript.Entry]) throws -> [Transcript.Entry] {
        try entries.map { entry in
            guard case .toolCalls = entry else { return entry }
            let (kind, payload, _) = TranscriptEntryMapper.event(from: entry)
            return try TranscriptEntryMapper.entry(from: payload, kind: kind)
        }
    }

    // MARK: - 1. Rich content through the full disk path

    @Test("a scripted tool answer (multi-call, .structure output, .reasoning) restores from disk equal to the live transcript's canonical form, across all six entry kinds")
    @MainActor
    func richToolAnswerRestoresFromDiskEqualToLiveTranscript() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // One round asking for two calls at once: a text-output marker tool
        // and a structured-output marker tool, then a `.reasoning` entry
        // before the final answer.
        let script = ScriptedAnswerScript(
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
            model: ScriptedToolCallingModel(script: script, log: ScriptedAnswerLog()))
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
        // Raw live equality is unreachable for a tool answer: see
        // ``canonicalized(_:)`` for the one live-only facet no persisted
        // form can keep — a live tool call's arguments GenerationID.
        let tree = try TranscriptTree.load(
            under: RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir))
        let reconstructed = try tree.effectiveTranscript(forSession: session.id)
        #expect(Array(reconstructed) == (try Self.canonicalized(live)))
    }

    // MARK: - 2. Compact a live session twice, then restore

    @Test("a session compacted twice through the scripted summarizer restores equal to the live post-second-compaction transcript")
    @MainActor
    func doubleCompactedSessionRestoresEqualToLiveTranscript() async throws {
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

        // First compaction: warm up, then compact under a target below the
        // live context, so the one summarizer call runs — the stub backend's
        // canned response is the scripted summary.
        let root = profile1.standard.makeSession()
        try await driveAnswers(Self.compactionWarmupAnswerCount, on: root)
        let firstCompactionBackend = try #require(registry.created.last)
        let firstResult = try await root.compact(
            budget: summarizingCompactionBudget(for: firstCompactionBackend.transcriptEntries()))
        #expect(firstResult.stagesApplied.contains("Summarization"))

        // Second compaction: more answers on the already-compacted session,
        // then compact again — the fixed checkpoint semantics (^h1008kb,
        // ^6z1msg1) must hold across repeated live compactions, not just one.
        try await driveAnswers(Self.compactionWarmupAnswerCount, on: root)
        let secondCompactionBackend = try #require(registry.created.last)
        let secondResult = try await root.compact(
            budget: summarizingCompactionBudget(for: secondCompactionBackend.transcriptEntries()))
        #expect(secondResult.stagesApplied.contains("Summarization"))

        // One post-compaction answer, so the restore must stitch the second
        // checkpoint's live window together with entries recorded after it.
        _ = try await root.respond(to: "message after the second compaction")

        // The live post-second-compaction transcript: the swap clone the second
        // compaction installed is the last backend the registry saw, and the
        // post-compaction answer appended into it in place.
        let liveBackend = try #require(registry.created.last)
        let live = liveBackend.transcriptEntries()
        #expect(liveBackend !== firstCompactionBackend)

        // Restore path 1: the reconstructed transcript equals the live one,
        // entry for entry.
        let routerDirectory = RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
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

    @Test("a restored fork's new answer holds content that exists only in an entry inherited from its parent")
    @MainActor
    func restoredForkAnswersFromInheritedParentEntries() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // The parent's answer calls the marker tool once; the fixture's
        // scripted model composes every answer from the tool outputs the
        // transcript carries, never from a canned string.
        let script = ScriptedAnswerScript(
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
            model: ScriptedToolCallingModel(script: script, log: ScriptedAnswerLog()))
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
        let routerDirectory = RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)
        let forkOwnEvents = try TranscriptTree.load(under: routerDirectory)
            .events(forSession: fork.id)
        #expect(!forkOwnEvents.contains { $0.kind == .toolOutput })

        // A fresh process restores the tree. The restored fork's transcript
        // already carries the parent's one tool-calling round, so the
        // scripted model's very next generation pass is the answering pass —
        // composed from whatever `.toolOutput` entries the restored session
        // was actually seeded with.
        let log2 = ScriptedAnswerLog()
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
