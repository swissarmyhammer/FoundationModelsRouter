import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The same real `mlx-community` generation model the rest of this target's
/// gated suites use for the `.standard` slot.
///
/// The 30B. This constant was named `sessionBackendTinyModel` until task
/// ^g1s1efb, and no model it ever held was tiny: it has read
/// ``RealModels/standard`` throughout. The name is corrected rather than kept,
/// because a reader who believed it went looking for the cost of this suite in
/// the wrong place.
private let sessionBackendModel: ModelRef = RealModels.standard

// MARK: - Suite

/// Gated real-model coverage for ``MLXFoundationModelsSessionBackend`` (the live
/// ``LanguageModelSessionBackend`` conformance in `LiveModelLoader.swift`).
///
/// This backend's whole reason to hold one `LanguageModelSession` per instance —
/// instead of rebuilding a fresh one per call, as it did before — is to
/// accumulate conversation state (the transcript) across answers, and to let
/// ``MLXFoundationModelsSessionBackend/makeFork()`` seed a child from that
/// accumulated transcript via `LanguageModelSession.init(model:tools:transcript:)`.
/// Both are only observable against a real, generating model — there is nothing
/// to assert GPU-free here (the GPU-free coverage in
/// `Tests/FoundationModelsRouterTests/LanguageModelSessionBackendTests.swift`
/// covers the schema-conversion seam instead). This suite loads the model
/// directly through ``LiveModelLoader``, bypassing ``Router``/``RoutedSession``,
/// so the backend itself — not the one-backend-per-call path
/// ``RoutedSessionActor`` still drives today (see plan.md) — is what's under
/// test. `internal var session` on the backend exists specifically so this
/// `@testable import` can read `transcript.count` directly.
///
/// This suite holds 11 tests, and each of them loads the model once. The suite
/// has no time limit. A run ends when it ends, or when the caller stops it.
///
/// ## What it NO LONGER proves (task ^g1s1efb)
///
/// Until that task every container this suite loaded took the provider's own
/// sampling, and each answer stated a reply ceiling alone. Eleven whole runs of
/// this target measured `makeFork() seeds the child's transcript from the
/// parent's` at 28.8 to 76.3 seconds. The 76.3 was 64 percent of the two-minute
/// budget of that time, and the very next run of the same code on the same
/// box measured 28.9 — a factor of 2.6 with no change to the suite between
/// them.
///
/// The per-phase clock ``makeForkSeedsFromParentTranscript()`` now prints named
/// the cost before the pin was made. Measured in isolation on 2026-08-22, on a
/// box at load average 2.3, under the provider default: the load took 3.4
/// seconds, the parent's first answer 23.5, the fork's own answer 9.4, the
/// parent's second answer 2.3 and the eviction 0.1, for 38.6 seconds in total.
/// A second run of the same code measured 3.1, 24.6, 13.4, 2.2 and 0.1, for
/// 43.4. So the load is 8 percent of the test and a repair aimed at it buys
/// nothing; the three answers are the test, and the fork's own answer moved by
/// 43 percent between two runs of identical code on a quiet box.
///
/// ``samplingMode`` pins argmax decoding on every container this suite loads,
/// which takes the spread out rather than the work. Measured in isolation on
/// the same box directly after: 45.6 seconds, then 44.7. The two splits agree
/// phase by phase — the fork's own answer measured 13.157 and then 13.126
/// seconds — so what is left of the spread is the box, not the decode.
///
/// What is no longer proven is:
///
/// - **The sampled path.** Every answer of this suite decodes with argmax now, so
///   a red run is attributable to the change under test, and the behavior under
///   the provider's default sampling is not measured here. This never disables
///   thinking: the model still writes a `<think>` block ahead of each answer,
///   and ``permittedAnswerEntryKinds`` still admits the `.reasoning` entry that
///   block leaves.
/// - **That each recalled fact survives a sampled decode.** The three recall
///   checks — teal in ``secondRespondSeesPriorAnswer()``, and 42 across the fork
///   and across a seeding transcript — each read one deterministic reply now
///   rather than a fresh draw on every run. A subject that recalls the fact at
///   argmax and loses it at temperature `0.6` would pass here.
///   ``SessionTreeRestorationIntegrationTests`` records the same trade for its
///   own recall step.
///
/// Everything else is untouched: the model, the eleven tests, each answer's reply
/// ceiling, the transcript-count checks, the per-kind entry checks, the
/// chokepoint fidelity pair, the usage delta, the KV-cache bounds and the
/// timing print are exactly what they were.
///
/// A test that a time limit cancels is worse than a plain red result. The
/// cancellation lands mid-generation, and a cancellation on GPU work aborts
/// the whole process on a Metal assertion (fork card ^3axg80k), which takes
/// every other suite's results with it.
@Suite(
    "Gated real-model coverage: MLXFoundationModelsSessionBackend (milestone 7)",
    .serialized,
    .exclusiveRealModel
)
struct LanguageModelSessionBackendIntegrationTests {
    /// The tag the per-phase wall-clock line of
    /// ``makeForkSeedsFromParentTranscript()`` opens with.
    ///
    /// Its own tag, and not the target's `gatedTest` one, so a grep that
    /// collects the per-test measurements of a run never picks up a phase
    /// line.
    private static let phaseLabel = "sessionBackendPhase"

    /// The decoding every container this suite loads is pinned to.
    ///
    /// Argmax. The provider default samples at temperature `0.6` from MLX's
    /// process-global PRNG, which seeds itself from the clock, so the length of
    /// the `<think>` block the 30B writes before each answer, and the wall
    /// clock with it, differed on every run of identical code. Argmax decoding
    /// consumes no randomness at all, which is what lets a red run here be
    /// attributed to the change under test, and what lets the wall clock of
    /// one run be compared with the wall clock of the next.
    ///
    /// The pin is stated one time, at load, on ``RealModelContainer/samplingMode``,
    /// and read back into each `makeSession(...samplingMode:)` call rather than
    /// stated on each answer's `GenerationOptions`, because every test here drives
    /// ``MLXFoundationModelsSessionBackend``, and that backend is the one type
    /// that reads the decoding the call that made it named. The container
    /// stores no mode (`model-pool.md` §2.5). A suite that drives a raw
    /// `LanguageModelSession` needs the other pin; this one does not.
    private static let samplingMode: GenerationOptions.SamplingMode = .greedy

    /// Loads ``sessionBackendModel`` into the concrete container each test of
    /// this suite drives, pinned to ``samplingMode``.
    ///
    /// Each test loads its own container and evicts it as it ends, exactly as
    /// each did before. One loader rather than eight spelled-out calls, so the
    /// decoding cannot drift between them.
    ///
    /// - Returns: The loaded container and the pinned mode.
    /// - Throws: Whatever ``RealModelContainer/load(ref:context:samplingMode:chatTemplateDate:)``
    ///   throws.
    private static func makeContainer() async throws -> RealModelContainer {
        try await RealModelContainer.load(ref: sessionBackendModel, samplingMode: samplingMode)
    }

    @Test("a second respond() call on the same backend sees the first answer's content in context")
    func secondRespondSeesPriorAnswer() async throws {
        let loaded = try await Self.makeContainer()
        let backend = try #require(
            loaded.container.makeSession(
                instructions: "You are a terse, literal assistant.", samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await backend.respond(
            to: "My favorite color is teal. Reply with just \"OK\".", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let entriesAfterFirstAnswer = backend.session.transcript.count
        #expect(entriesAfterFirstAnswer > 0)

        // The proof this backend is conversation-preserving (not rebuilding a
        // fresh, context-free session per call, as it did before this change):
        // the second answer must reflect the content of the first answer.
        let secondReply = try await backend.respond(
            to: "What is my favorite color? Answer with just the color, lowercase.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(secondReply.lowercased().contains("teal"))

        // And the same session accumulated a second answer on top of the first,
        // rather than starting over.
        #expect(backend.session.transcript.count > entriesAfterFirstAnswer)

        await loaded.container.model.evict()
    }

    @Test("makeFork() seeds the child's transcript from the parent's at fork time")
    func makeForkSeedsFromParentTranscript() async throws {
        // Each phase's own wall clock, printed however the test ends, so the
        // cost can be read against the phase that carries it rather than
        // against the total alone. `PropagationProbeIntegrationTests` and
        // `IntegrationTests` print the same split for the same reason. This
        // test drives three answers on one load, so a total alone cannot say
        // which of the four costs the run.
        var loadDuration: Duration = .zero
        var parentAnswerDuration: Duration = .zero
        var childAnswerDuration: Duration = .zero
        var parentSecondAnswerDuration: Duration = .zero
        var evictDuration: Duration = .zero
        defer {
            print(
                "[\(Self.phaseLabel)] load=\(loadDuration) parentAnswer=\(parentAnswerDuration) "
                    + "childAnswer=\(childAnswerDuration) "
                    + "parentSecondAnswer=\(parentSecondAnswerDuration) evict=\(evictDuration)"
            )
        }

        let loadStarted = ContinuousClock.now
        let loaded = try await Self.makeContainer()
        loadDuration = ContinuousClock.now - loadStarted
        let parent = try #require(
            loaded.container.makeSession(
                instructions: "You are a terse, literal assistant.", samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        let parentStartInstant = ContinuousClock.now
        _ = try await parent.respond(to: "Remember the number 42.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        parentAnswerDuration = ContinuousClock.now - parentStartInstant
        let parentEntryCountAtForkTime = parent.session.transcript.count

        let child = try #require(parent.makeFork() as? MLXFoundationModelsSessionBackend)

        // The child's session begins holding exactly the parent's entries as of
        // fork time — `LanguageModelSession.init(model:tools:transcript:)` seeded
        // it, not an empty/fresh transcript.
        #expect(child.session.transcript.count == parentEntryCountAtForkTime)

        // The transcript-count check above only proves the entry count matches;
        // it does not prove the fork can actually *see* the content of the
        // parent's earlier answer. Drive the fork with a real answer and assert
        // it reflects the number the parent was told to remember before the fork —
        // the same content-awareness proof ``secondRespondSeesPriorAnswer`` above
        // uses for same-backend continuity, applied here across the fork
        // boundary.
        let childStartInstant = ContinuousClock.now
        let childReply = try await child.respond(
            to: "What number should I remember? Answer with just the number.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        childAnswerDuration = ContinuousClock.now - childStartInstant
        #expect(childReply.contains("42"))
        let childEntryCountAfterOwnAnswer = child.session.transcript.count

        // The two then diverge independently: a further parent answer does not
        // retroactively change the child's already-seeded (and now
        // independently-grown) transcript.
        let parentSecondStartInstant = ContinuousClock.now
        _ = try await parent.respond(to: "Remember the number 7 too.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        parentSecondAnswerDuration = ContinuousClock.now - parentSecondStartInstant
        #expect(child.session.transcript.count == childEntryCountAfterOwnAnswer)

        let evictStarted = ContinuousClock.now
        await loaded.container.model.evict()
        evictDuration = ContinuousClock.now - evictStarted
    }

    // MARK: - Transcript-seeded factory (task bkhj6ya)

    @Test(
        "makeSession(transcript:) seeds a fresh backend that recalls content from a prior session's transcript"
    )
    func makeSessionFromTranscriptRecallsPriorContent() async throws {
        let loaded = try await Self.makeContainer()
        let prior = try #require(
            loaded.container.makeSession(
                instructions: "You are a terse, literal assistant.", samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await prior.respond(to: "Remember the number 42.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        // Unlike `makeFork()`, which is called on an existing *backend* and
        // copies its live session's transcript, `makeSession(transcript:)` is
        // called on the *container* — the seam a restored session tree needs
        // to rebuild a root session from a persisted transcript, with no live
        // parent backend/session involved at all.
        let restored = try #require(
            loaded.container.makeSession(transcript: prior.session.transcript, samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        let reply = try await restored.respond(
            to: "What number should I remember? Answer with just the number.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(reply.contains("42"))

        await loaded.container.model.evict()
    }

    // MARK: - Transcript growth and fork seeding (per-answer entry kinds)

    /// The entry kinds an answer is permitted to leave in the transcript.
    ///
    /// An answer owes exactly one `.prompt` and one `.response`. A reasoning
    /// model leaves a third kind: the gated model writes a `<think>` block,
    /// which lands as a `.reasoning` entry (see ``GatedRealModelBudget``).
    /// It does not write one on every answer — a measured pair of answers left 5
    /// entries where the same pair once left 4 — so a total entry count is
    /// not a function of the answer count, and the checks below hold the
    /// per-kind counts instead. Naming the permitted kinds here keeps an
    /// unexpected extra kind from going unnoticed.
    private static let permittedAnswerEntryKinds: Set<TranscriptEvent.Kind> = [
        .prompt, .response, .reasoning,
    ]

    /// Checks that `backend`'s live transcript holds what `answers` answers owe:
    /// one `.prompt` and one `.response` for each answer, and no kind outside
    /// ``permittedAnswerEntryKinds``.
    ///
    /// - Parameters:
    ///   - backend: The live backend whose session transcript is read.
    ///   - answers: How many answers the transcript is expected to hold.
    private static func expectTranscriptHolds(
        _ backend: MLXFoundationModelsSessionBackend,
        answers: Int
    ) {
        let kinds = backend.session.transcript.map { TranscriptEntryMapper.event(from: $0).kind }
        #expect(kinds.filter { $0 == .prompt }.count == answers, "prompt entries in \(kinds)")
        #expect(kinds.filter { $0 == .response }.count == answers, "response entries in \(kinds)")
        #expect(
            kinds.allSatisfy { permittedAnswerEntryKinds.contains($0) },
            "an entry kind outside the permitted set in \(kinds)"
        )
    }

    @Test(
        "each respond() call leaves exactly one prompt entry and one response entry across two answers"
    )
    func eachAnswerLeavesOnePromptAndOneResponse() async throws {
        let loaded = try await Self.makeContainer()
        // No instructions: an instructions-carrying session's transcript opens
        // with an extra `.instructions` entry, which no answer owes. Omitting
        // instructions leaves only the entries that the answers made.
        let backend = try #require(
            loaded.container.makeSession(instructions: nil, samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await backend.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        _ = try await backend.respond(to: "Say 'hi' again, briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        let drivenAnswers = 2
        Self.expectTranscriptHolds(backend, answers: drivenAnswers)

        await loaded.container.model.evict()
    }

    @Test("a fork taken after one answer begins holding exactly that answer's entries")
    func forkAfterOneAnswerHoldsThatAnswersEntries() async throws {
        let loaded = try await Self.makeContainer()
        let parent = try #require(
            loaded.container.makeSession(instructions: nil, samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await parent.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        let child = try #require(parent.makeFork() as? MLXFoundationModelsSessionBackend)

        let drivenAnswers = 1
        Self.expectTranscriptHolds(child, answers: drivenAnswers)

        await loaded.container.model.evict()
    }

    // MARK: - transcriptEntries() matches the test-only transcript accessor

    @Test("transcriptEntries().count equals session.transcript.count and grows across answers")
    func transcriptEntriesMatchesSessionTranscriptAndGrows() async throws {
        let loaded = try await Self.makeContainer()
        let backend = try #require(
            loaded.container.makeSession(instructions: nil, samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        // Before any answer, the public seam and the test-only accessor agree.
        #expect(backend.transcriptEntries().count == backend.session.transcript.count)

        _ = try await backend.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let countAfterFirstAnswer = backend.transcriptEntries().count
        #expect(countAfterFirstAnswer == backend.session.transcript.count)
        #expect(countAfterFirstAnswer > 0)

        _ = try await backend.respond(to: "Say 'hi' again, briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let countAfterSecondAnswer = backend.transcriptEntries().count
        #expect(countAfterSecondAnswer == backend.session.transcript.count)
        #expect(countAfterSecondAnswer > countAfterFirstAnswer)

        await loaded.container.model.evict()
    }

    // MARK: - Chokepoint fidelity: recorded entry kinds match the real transcript

    /// The pieces ``recordedEntryKindsMatchSessionTranscriptKinds()`` and its
    /// streaming counterpart both need: a real ``RoutedSessionActor`` wired
    /// directly to the already-loaded model's backend (bypassing
    /// ``Router/resolve(profile:reporting:)``, which would need a real
    /// `.flash`/`.embedding` download too), plus the on-disk locations its
    /// transcript is recorded under, via the same `internal` initializers
    /// production code uses — the same technique this file's other tests use
    /// to reach ``MLXFoundationModelsSessionBackend`` directly, extended one
    /// level up to the chokepoint itself.
    private struct ChokepointHarness {
        let session: RoutedSessionActor
        let backend: MLXFoundationModelsSessionBackend
        let container: MLXFoundationModelsContainer
        let recordingDirectory: URL
        let recordingsDir: URL
        let cacheDir: URL
    }

    /// Builds a ``ChokepointHarness`` over a freshly loaded model.
    ///
    /// The profile comes from ``RealModelHarness/make(model:context:container:samplingMode:cacheDir:recordingsDir:routerId:)``,
    /// which this harness's own hand-built copy was merged onto (task
    /// ^zz6kam0). One `JSONLRecorder` still reaches the router and every handle
    /// alike — `Router.recorder` is actor-isolated, and one sink keeps every
    /// append off that hop — and each handle still carries the root-plus-writer
    /// ``DurableRecording`` pair `Router.makeDurableRecording` builds, so this
    /// harness records a tree a reader could load rather than transcripts with
    /// no sidecars beside them.
    ///
    /// One fact changed with the move. The copy built its `Router` with NO
    /// `recordingsDir`, so `router.recordingsDir` read `nil` while every handle
    /// recorded into a real directory; the harness always hands the router that
    /// directory. Nothing in this suite reads the field, so the move corrects
    /// an inconsistency and changes no assertion.
    private func makeChokepointHarness() async throws -> ChokepointHarness {
        let loaded = try await Self.makeContainer()
        let backend = try #require(
            loaded.container.makeSession(instructions: nil, samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LanguageModelSessionBackendTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LanguageModelSessionBackendTests-cache-\(UUID().uuidString)", isDirectory: true)

        let profile = RealModelHarness.make(
            model: sessionBackendModel,
            // The small, known window the tests state. The harness has no
            // default of its own, and the library has no default context.
            context: ScriptedSessionContext.tokens,
            container: loaded.container,
            samplingMode: loaded.samplingMode,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let standard = profile.standard

        let sessionId = ULID.generate()
        let recordingDirectory = recordingsDir
            .appendingPathComponent(standard.routerId.description, isDirectory: true)
            .appendingPathComponent(sessionId.description, isDirectory: true)

        // This root is assembled by hand rather than vended from
        // `standard.makeSession()` — the tests need the backend itself — and it
        // still lands its own sidecar, because that is the session's own job
        // rather than its builder's (see `SessionSidecarOrigin`).
        let session = RoutedSessionActor(
            profile: profile,
            routerId: standard.routerId,
            id: sessionId,
            parentId: nil,
            recordingDirectory: recordingDirectory,
            workingDirectory: recordingDirectory,
            backend: backend,
            slot: .standard,
            model: sessionBackendModel,
            recorder: standard.recorder,
            instructions: nil,
            grammar: nil,
            persistedEntryCount: 0,
            historyOrdinal: 0,
            // A new root under the vending handle's durable recording, exactly
            // as `makeSession` names it: this session writes its own sidecar,
            // and so does any fork taken from it.
            sidecarOrigin: .new(under: standard.durableRecording),
            // The handle's own resolved window, exactly as `makeSession`
            // hands it on.
            contextTokens: standard.contextTokens,
            // The container's own counter, exactly as `makeSession` hands it
            // on: every count the session makes before a call comes from the
            // tokenizer of its model.
            tokenCounter: standard.container.tokenCounter,
            // The handle's own tracer, exactly as `makeSession` hands it on: a
            // session reports to the same backend as the handle it came off.
            tracer: standard.tracer
        )

        return ChokepointHarness(
            session: session,
            backend: backend,
            container: loaded.container,
            recordingDirectory: recordingDirectory,
            recordingsDir: recordingsDir,
            cacheDir: cacheDir
        )
    }

    /// Decodes every event from `harness`'s session directory's `transcript.jsonl`.
    private func recordedEvents(from harness: ChokepointHarness) throws -> [TranscriptEvent] {
        let fileURL = harness.recordingDirectory.appendingPathComponent(
            "transcript.jsonl", isDirectory: false)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map {
            try decoder.decode(TranscriptEvent.self, from: Data($0.utf8))
        }
    }

    /// Task qb9p7gs's core acceptance criterion, proved against a real model:
    /// after one live answer, what ``RoutedSessionActor``'s snapshot-diff
    /// persisted matches — kind for kind, in order — what the live
    /// `LanguageModelSession`'s own `transcript` actually accumulated.
    @Test(
        "recorded entry kinds match the real session.transcript kinds one-for-one after a live answer")
    func recordedEntryKindsMatchSessionTranscriptKinds() async throws {
        let harness = try await makeChokepointHarness()
        defer {
            try? FileManager.default.removeItem(at: harness.recordingsDir)
            try? FileManager.default.removeItem(at: harness.cacheDir)
        }

        _ = try await harness.session.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        let recorded = try recordedEvents(from: harness)

        // The router-only kinds (the `.session` meta line and the
        // `.generationCall` journal line) never enter Apple's own transcript,
        // and `isEntryKind` is false for them. Every transcript entry kind that
        // was recorded must match, in order, the kind of the corresponding real
        // `Transcript.Entry` the live session actually accumulated — the whole
        // point of snapshot-diff persistence.
        let recordedEntryKinds = recorded.map(\.kind).filter(\.isEntryKind)
        let liveEntryKinds = harness.backend.session.transcript.map {
            TranscriptEntryMapper.event(from: $0).kind
        }
        #expect(recordedEntryKinds == liveEntryKinds)
        #expect(!recordedEntryKinds.isEmpty)

        await harness.container.model.evict()
    }

    /// Mirrors ``recordedEntryKindsMatchSessionTranscriptKinds()`` but drives
    /// the live answer through ``RoutedSessionActor/streamResponse(to:maxTokens:)``
    /// instead of `respond(to:maxTokens:)`: both generation entry points funnel
    /// through the same snapshot-diff chokepoint, so the fidelity invariant
    /// must hold identically for the streaming path against a real model too.
    @Test(
        "recorded entry kinds match the real session.transcript kinds one-for-one after a live streaming answer"
    )
    func recordedEntryKindsMatchSessionTranscriptKindsStreaming() async throws {
        let harness = try await makeChokepointHarness()
        defer {
            try? FileManager.default.removeItem(at: harness.recordingsDir)
            try? FileManager.default.removeItem(at: harness.cacheDir)
        }

        var collected = ""
        for try await chunk in await harness.session.streamResponse(
            to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        {
            collected += chunk
        }
        #expect(!collected.isEmpty)

        let recorded = try recordedEvents(from: harness)

        // Transcript entry kinds only, as in the non-streaming test above.
        let recordedEntryKinds = recorded.map(\.kind).filter(\.isEntryKind)
        let liveEntryKinds = harness.backend.session.transcript.map {
            TranscriptEntryMapper.event(from: $0).kind
        }
        #expect(recordedEntryKinds == liveEntryKinds)
        #expect(!recordedEntryKinds.isEmpty)

        await harness.container.model.evict()
    }

    // MARK: - Token usage metering (task v22nv1g)

    /// Proves the chokepoint's usage delta stays faithful to the live
    /// backend's own ``LanguageModelSessionBackend/usageTokenCounts()``
    /// snapshots, whatever those snapshots turn out to be. Written to pass
    /// either way per this task's instructions: it proves only that the
    /// router's recorded delta exactly matches whatever the backend reports,
    /// and it prints the observed counts for a human to read. Whether
    /// `MLXLanguageModel`'s `Executor` populates real, positive
    /// `usage.input`/`usage.output` totals is answered by the print: measured
    /// 2026-08-22 at fork pin `41e9f41`, under the argmax decoding
    /// ``samplingMode`` pins, it printed `tokensIn=62 tokensOut=128` in each of
    /// two whole runs of the target. The sampled measurement
    /// ``MLXFoundationModelsSessionBackend/usageTokenCounts()``'s doc comment
    /// records is `tokensIn=62 tokensOut=149`, from one run of 2026-08-21. The
    /// input count is the same because the prompt is; only the generated count
    /// moved.
    @Test("recorded tokensIn/tokensOut on the submission's response event exactly match the live backend's own usageTokenCounts() delta")
    func recordedTokenUsageMatchesLiveBackendDelta() async throws {
        let harness = try await makeChokepointHarness()
        defer {
            try? FileManager.default.removeItem(at: harness.recordingsDir)
            try? FileManager.default.removeItem(at: harness.cacheDir)
        }

        let usageBefore = harness.backend.usageTokenCounts()
        _ = try await harness.session.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let usageAfter = harness.backend.usageTokenCounts()

        let recorded = try recordedEvents(from: harness)
        let responseEvent = try #require(recorded.first { $0.kind == .response })

        guard let usageBefore, let usageAfter else {
            // The backend reported no usage at all — MLXFoundationModelsSessionBackend
            // never actually takes this branch today (it always returns a real
            // tuple), but the router's own nil-propagation contract still must
            // hold if a future backend ever does.
            #expect(responseEvent.tokensIn == nil)
            #expect(responseEvent.tokensOut == nil)
            return
        }

        let expectedTokensIn = usageAfter.input - usageBefore.input
        let expectedTokensOut = usageAfter.output - usageBefore.output
        #expect(responseEvent.tokensIn == expectedTokensIn)
        #expect(responseEvent.tokensOut == expectedTokensOut)

        // Not asserted either way — this is exactly the populated-vs-zero
        // question this suite can finally give a real answer to, on real
        // hardware, without this test needing to hardcode an assumption.
        print(
            "[recordedTokenUsageMatchesLiveBackendDelta] tokensIn=\(expectedTokensIn) tokensOut=\(expectedTokensOut)"
        )

        await harness.container.model.evict()
    }

    // MARK: - KV cache reuse across answers (the hard proof)

    @Test(
        "answer 2's usage.input.cachedTokenCount is positive, covers answer 1's whole prompt, and does not exceed everything answer 1 processed — the KV cache is reused, not recomputed"
    )
    func secondAnswerReusesFirstAnswersKVCache() async throws {
        let loaded = try await Self.makeContainer()
        let backend = try #require(
            loaded.container.makeSession(
                instructions: "You are a terse, literal assistant.", samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await backend.respond(
            to: "My favorite color is teal. Reply with just \"OK\".", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let answer1Usage = backend.session.usage

        // Nothing could have been cached before the very first answer ever ran.
        #expect(answer1Usage.input.cachedTokenCount == 0)
        #expect(answer1Usage.input.totalTokenCount > 0)
        #expect(answer1Usage.output.totalTokenCount > 0)

        // The two bounds of what answer 2 can reuse. Answer 1's prompt (the
        // instructions entry included) is the prefix of the transcript answer 2
        // sends, so it is the least answer 2 can serve from cache. Answer 1's
        // prompt plus its own generated response is everything answer 1
        // processed, so it is the most answer 2 can serve from cache.
        let answer1PromptTokenCount = answer1Usage.input.totalTokenCount
        let answer1ProcessedTokenCount =
            answer1PromptTokenCount + answer1Usage.output.totalTokenCount

        _ = try await backend.respond(
            to: "What is my favorite color? Answer with just the color, lowercase.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        let answer2Usage = backend.session.usage

        // THE required proof. The fork's executor keeps a live cache for each
        // session (ExecutorPromptCache.swift) and stamps
        // `cachedTokenCount: promptCache.reusedTokenCount`. Fork revision
        // 239b41e made ExecutorPromptCachePlan.make accept the rank-2,
        // all-ones-masked text-only input that MuseGlimmerProcessor renders,
        // thus this count is positive for the standard model. The two packages
        // of this repository resolve the fork branch independently, and
        // Package.resolved is gitignored, so read the revision this package
        // resolved before you trust any claim about the fork. This assertion is
        // deliberately never weakened or made non-fatal.
        #expect(
            answer2Usage.input.cachedTokenCount > 0,
            "answer 2 must reuse answer 1's KV cache; cachedTokenCount == 0 means no cache reuse happened"
        )

        // Printed, not asserted: the split of answer 1 between prompt and
        // response, beside what answer 2 reused, for a human to read when a
        // bound below fails.
        print(
            "[secondAnswerReusesFirstAnswersKVCache] answer1In=\(answer1PromptTokenCount) "
                + "answer1Out=\(answer1Usage.output.totalTokenCount) "
                + "answer2Cached=\(answer2Usage.input.cachedTokenCount)"
        )

        // Bounds, not an approximate equality against prompt plus response.
        // Answer 2 reuses answer 1's prompt, but it does not always reuse
        // answer 1's response. The fork's cache ledger holds answer 1's render
        // plus every token answer 1 generated, and `TranscriptConverter` drops
        // the `.reasoning` entries of earlier answers from the chat history on
        // purpose. A reasoning model such as Muse Glimmer reasons in a
        // `to=self` channel directly after the generation prompt, so answer 2's
        // render diverges from the ledger at the first generated token, and the
        // fork rewinds the cache to the end of answer 1's prompt. Measured
        // 2026-08-22 at fork pin 41e9f41, under the argmax decoding
        // `samplingMode` pins: answer1In=49 answer1Out=76 answer2Cached=50. Two
        // whole runs of the target printed those same three numbers, because a
        // pinned decode repeats. The sampled measurement this comment held before
        // printed answer1Out=84 on one run and 93 on another. An equality against
        // prompt plus response thus rests on a premise that is false for a
        // reasoning model. The two bounds still fail on a zero, on a partial
        // reuse of the prompt, and on an over-report. Decision: card ^dmxsxb0.
        #expect(
            answer2Usage.input.cachedTokenCount >= answer1PromptTokenCount,
            """
            cachedTokenCount (\(answer2Usage.input.cachedTokenCount)) must cover answer 1's whole prompt \
            (\(answer1PromptTokenCount)); less means answer 2 recomputed part of the prefix
            """
        )
        #expect(
            answer2Usage.input.cachedTokenCount <= answer1ProcessedTokenCount,
            """
            cachedTokenCount (\(answer2Usage.input.cachedTokenCount)) must not exceed everything answer 1 \
            processed (\(answer1ProcessedTokenCount)); more is an over-report
            """
        )

        await loaded.container.model.evict()
    }

    // MARK: - Timing signal (best-effort, non-fatal)

    @Test(
        "answer 2 tends to be faster than answer 1 on a session with a long system instruction (heuristic timing signal, never fails CI)"
    )
    func secondAnswerTendsToBeFasterThanFirst() async throws {
        let loaded = try await Self.makeContainer()
        // A long instruction makes the fixed, cacheable prefix answer 2 should
        // reuse a much larger share of the input than a short one would, so a
        // real speed-up (if the cache is working) is more likely to be
        // visible above run-to-run noise.
        let longInstructions = String(
            repeating:
                "You are a careful, terse assistant who always answers in as few words as possible. ",
            count: 40
        )
        let backend = try #require(
            loaded.container.makeSession(instructions: longInstructions, samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        let answer1Start = Date()
        _ = try await backend.respond(to: "Say just 'OK'.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let answer1Duration = Date().timeIntervalSince(answer1Start)

        let answer2Start = Date()
        _ = try await backend.respond(to: "Say just 'OK' again.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let answer2Duration = Date().timeIntervalSince(answer2Start)

        // Heuristic/warning only: logged for a human to read, never asserted.
        // A ratio near (or above) 1.0 would be a signal worth investigating —
        // that the cache is not meaningfully speeding up answer 2 even if
        // `cachedTokenCount` reports reuse — but flaky wall-clock timing on
        // shared CI hardware must never fail this suite.
        let ratio = answer1Duration > 0 ? answer2Duration / answer1Duration : .nan
        print(
            "[secondAnswerTendsToBeFasterThanFirst] answer1=\(answer1Duration)s answer2=\(answer2Duration)s ratio=\(ratio)"
        )

        await loaded.container.model.evict()
    }
}
