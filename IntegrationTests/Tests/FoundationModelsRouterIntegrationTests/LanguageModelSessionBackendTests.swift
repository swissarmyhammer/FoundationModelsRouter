import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The same real `mlx-community` generation model the rest of this target's
/// gated suites use for the `.standard` slot.
private let sessionBackendTinyModel: ModelRef = RealModels.standard

// MARK: - Suite

/// Gated real-model coverage for ``MLXFoundationModelsSessionBackend`` (the live
/// ``LanguageModelSessionBackend`` conformance in `LiveModelLoader.swift`).
///
/// This backend's whole reason to hold one `LanguageModelSession` per instance —
/// instead of rebuilding a fresh one per call, as it did before — is to
/// accumulate conversation state (the transcript) across turns, and to let
/// ``MLXFoundationModelsSessionBackend/makeFork()`` seed a child from that
/// accumulated transcript via `LanguageModelSession.init(model:tools:transcript:)`.
/// Both are only observable against a real, generating model — there is nothing
/// to assert GPU-free here (the GPU-free coverage in
/// `Tests/FoundationModelsRouterTests/LanguageModelSessionBackendTests.swift`
/// covers the schema-conversion seam instead). This suite loads the tiny model
/// directly through ``LiveModelLoader``, bypassing ``Router``/``RoutedSession``,
/// so the backend itself — not the one-backend-per-call path
/// ``RoutedSessionActor`` still drives today (see plan.md) — is what's under
/// test. `internal var session` on the backend exists specifically so this
/// `@testable import` can read `transcript.count` directly.
///
/// This suite holds 11 tests, and each of them loads the model once. The three
/// runs of 2026-08-20 measured them at 48.7, 45.7, 40.3, 28.8, 23.3, 19.5,
/// 19.2, 19.1, 19.0, 16.6 and 16.0 seconds, then at 62.3, 48.3, 40.4, 30.0,
/// 27.9, 21.0, 20.4, 20.0, 17.2, 16.6 and 15.0 seconds, then at 58.6, 46.5,
/// 41.8, 39.7, 23.0, 21.7, 21.6, 20.3, 19.3, 17.9 and 17.5 seconds.
///
/// Which test is the dearest changes from run to run, so this comment names
/// none of them. `makeFork() seeds the child's transcript from the parent's at
/// fork time` was the dearest test of run 2 at 62.3 seconds and stands fourth
/// in run 3 at 39.7 seconds, while `a second respond() call on the same backend
/// sees the first turn` is the dearest test of run 3 at 58.6 seconds. The
/// spread comes from the provider-default sampling
/// ``SessionTreeRestorationIntegrationTests`` states. The limit is
/// ``integrationTestBudgetMinutes``, which replaces the 15 minutes this suite
/// stated before; see it for the whole run table.
@Suite(
    "Gated real-model coverage: MLXFoundationModelsSessionBackend (milestone 7)",
    .serialized,
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct LanguageModelSessionBackendIntegrationTests {
    @Test("a second respond() call on the same backend sees the first turn's content in context")
    func secondRespondSeesPriorTurn() async throws {
        let container = try await RealModelContainer.load(ref: sessionBackendTinyModel)
        let backend = try #require(
            container.makeSession(instructions: "You are a terse, literal assistant.")
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await backend.respond(
            to: "My favorite color is teal. Reply with just \"OK\".", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let entriesAfterFirstTurn = backend.session.transcript.count
        #expect(entriesAfterFirstTurn > 0)

        // The proof this backend is conversation-preserving (not rebuilding a
        // fresh, context-free session per call, as it did before this change):
        // the second turn's answer must reflect the first turn's content.
        let secondReply = try await backend.respond(
            to: "What is my favorite color? Answer with just the color, lowercase.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(secondReply.lowercased().contains("teal"))

        // And the same session accumulated a second turn on top of the first,
        // rather than starting over.
        #expect(backend.session.transcript.count > entriesAfterFirstTurn)

        await container.model.evict()
    }

    @Test("makeFork() seeds the child's transcript from the parent's at fork time")
    func makeForkSeedsFromParentTranscript() async throws {
        let container = try await RealModelContainer.load(ref: sessionBackendTinyModel)
        let parent = try #require(
            container.makeSession(instructions: "You are a terse, literal assistant.")
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await parent.respond(to: "Remember the number 42.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let parentEntryCountAtForkTime = parent.session.transcript.count

        let child = try #require(parent.makeFork() as? MLXFoundationModelsSessionBackend)

        // The child's session begins holding exactly the parent's entries as of
        // fork time — `LanguageModelSession.init(model:tools:transcript:)` seeded
        // it, not an empty/fresh transcript.
        #expect(child.session.transcript.count == parentEntryCountAtForkTime)

        // The transcript-count check above only proves the entry count matches;
        // it does not prove the fork can actually *see* the parent's prior-turn
        // content. Drive the fork with a real turn and assert its answer
        // reflects the number the parent was told to remember before the fork —
        // the same content-awareness proof ``secondRespondSeesPriorTurn`` above
        // uses for same-backend continuity, applied here across the fork
        // boundary.
        let childReply = try await child.respond(
            to: "What number should I remember? Answer with just the number.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(childReply.contains("42"))
        let childEntryCountAfterOwnTurn = child.session.transcript.count

        // The two then diverge independently: a further parent turn does not
        // retroactively change the child's already-seeded (and now
        // independently-grown) transcript.
        _ = try await parent.respond(to: "Remember the number 7 too.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        #expect(child.session.transcript.count == childEntryCountAfterOwnTurn)

        await container.model.evict()
    }

    // MARK: - Transcript-seeded factory (task bkhj6ya)

    @Test(
        "makeSession(transcript:) seeds a fresh backend that recalls content from a prior session's transcript"
    )
    func makeSessionFromTranscriptRecallsPriorContent() async throws {
        let container = try await RealModelContainer.load(ref: sessionBackendTinyModel)
        let prior = try #require(
            container.makeSession(instructions: "You are a terse, literal assistant.")
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await prior.respond(to: "Remember the number 42.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        // Unlike `makeFork()`, which is called on an existing *backend* and
        // copies its live session's transcript, `makeSession(transcript:)` is
        // called on the *container* — the seam a restored session tree needs
        // to rebuild a root session from a persisted transcript, with no live
        // parent backend/session involved at all.
        let restored = try #require(
            container.makeSession(transcript: prior.session.transcript)
                as? MLXFoundationModelsSessionBackend
        )

        let reply = try await restored.respond(
            to: "What number should I remember? Answer with just the number.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        #expect(reply.contains("42"))

        await container.model.evict()
    }

    // MARK: - Transcript growth and fork seeding (per-turn entry kinds)

    /// The entry kinds a turn is permitted to leave in the transcript.
    ///
    /// A turn owes exactly one `.prompt` and one `.response`. A reasoning
    /// model leaves a third kind: the gated model writes a `<think>` block,
    /// which lands as a `.reasoning` entry (see ``GatedRealModelBudget``).
    /// It does not write one on every turn — a measured pair of turns left 5
    /// entries where the same pair once left 4 — so a total entry count is
    /// not a function of the turn count, and the checks below hold the
    /// per-kind counts instead. Naming the permitted kinds here keeps an
    /// unexpected extra kind from going unnoticed.
    private static let permittedTurnEntryKinds: Set<TranscriptEvent.Kind> = [
        .prompt, .response, .reasoning,
    ]

    /// Checks that `backend`'s live transcript holds what `turns` turns owe:
    /// one `.prompt` and one `.response` for each turn, and no kind outside
    /// ``permittedTurnEntryKinds``.
    ///
    /// - Parameters:
    ///   - backend: The live backend whose session transcript is read.
    ///   - turns: How many turns the transcript is expected to hold.
    private static func expectTranscriptHolds(
        _ backend: MLXFoundationModelsSessionBackend,
        turns: Int
    ) {
        let kinds = backend.session.transcript.map { TranscriptEntryMapper.event(from: $0).kind }
        #expect(kinds.filter { $0 == .prompt }.count == turns, "prompt entries in \(kinds)")
        #expect(kinds.filter { $0 == .response }.count == turns, "response entries in \(kinds)")
        #expect(
            kinds.allSatisfy { permittedTurnEntryKinds.contains($0) },
            "an entry kind outside the permitted set in \(kinds)"
        )
    }

    @Test(
        "each respond() call leaves exactly one prompt entry and one response entry across two turns"
    )
    func eachTurnLeavesOnePromptAndOneResponse() async throws {
        let container = try await RealModelContainer.load(ref: sessionBackendTinyModel)
        // No instructions: an instructions-carrying session's transcript opens
        // with an extra `.instructions` entry, which no turn owes. Omitting
        // instructions leaves only turn-driven entries to check.
        let backend = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend
        )

        _ = try await backend.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        _ = try await backend.respond(to: "Say 'hi' again, briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        let drivenTurns = 2
        Self.expectTranscriptHolds(backend, turns: drivenTurns)

        await container.model.evict()
    }

    @Test("a fork taken after one turn begins holding exactly that turn's entries")
    func forkAfterOneTurnHoldsThatTurnsEntries() async throws {
        let container = try await RealModelContainer.load(ref: sessionBackendTinyModel)
        let parent = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend
        )

        _ = try await parent.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        let child = try #require(parent.makeFork() as? MLXFoundationModelsSessionBackend)

        let drivenTurns = 1
        Self.expectTranscriptHolds(child, turns: drivenTurns)

        await container.model.evict()
    }

    // MARK: - transcriptEntries() matches the test-only transcript accessor

    @Test("transcriptEntries().count equals session.transcript.count and grows across turns")
    func transcriptEntriesMatchesSessionTranscriptAndGrows() async throws {
        let container = try await RealModelContainer.load(ref: sessionBackendTinyModel)
        let backend = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend
        )

        // Before any turn, the public seam and the test-only accessor agree.
        #expect(backend.transcriptEntries().count == backend.session.transcript.count)

        _ = try await backend.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let countAfterFirstTurn = backend.transcriptEntries().count
        #expect(countAfterFirstTurn == backend.session.transcript.count)
        #expect(countAfterFirstTurn > 0)

        _ = try await backend.respond(to: "Say 'hi' again, briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let countAfterSecondTurn = backend.transcriptEntries().count
        #expect(countAfterSecondTurn == backend.session.transcript.count)
        #expect(countAfterSecondTurn > countAfterFirstTurn)

        await container.model.evict()
    }

    // MARK: - Chokepoint fidelity: recorded entry kinds match the real transcript

    /// The pieces ``recordedEntryKindsMatchSessionTranscriptKinds()`` and its
    /// streaming counterpart both need: a real ``RoutedSessionActor`` wired
    /// directly to the already-loaded tiny model's backend (bypassing
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

    /// Builds a ``ChokepointHarness`` over a freshly loaded tiny model.
    ///
    /// The profile comes from ``RealModelHarness/make(model:context:container:cacheDir:recordingsDir:routerId:)``,
    /// which this harness's own hand-built copy was folded onto (task
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
        let container = try await RealModelContainer.load(ref: sessionBackendTinyModel)
        let backend = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend
        )

        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LanguageModelSessionBackendTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LanguageModelSessionBackendTests-cache-\(UUID().uuidString)", isDirectory: true)

        let profile = RealModelHarness.make(
            model: sessionBackendTinyModel,
            // The window the hand-built copy resolved at: it stated no
            // `contextTokens` at all, so every slot took `SlotResolution`'s own
            // default. Stated explicitly here, because the harness has no
            // default of its own to inherit.
            context: ProfileDefinition.defaultContext,
            container: container,
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
            model: sessionBackendTinyModel,
            recorder: standard.recorder,
            instructions: nil,
            grammar: nil,
            generationGate: standard.generationGate,
            forkAdmissionGate: standard.forkAdmissionGate,
            holdsAdmissionPermit: false,
            persistedEntryCount: 0,
            historyOrdinal: 0,
            // A new root under the vending handle's durable recording, exactly
            // as `makeSession` names it: this session writes its own sidecar,
            // and so does any fork taken from it.
            sidecarOrigin: .new(under: standard.durableRecording)
        )

        return ChokepointHarness(
            session: session,
            backend: backend,
            container: container,
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
    /// after one live turn, what ``RoutedSessionActor``'s snapshot-diff
    /// persisted matches — kind for kind, in order — what the live
    /// `LanguageModelSession`'s own `transcript` actually accumulated.
    @Test(
        "recorded entry kinds match the real session.transcript kinds one-for-one after a live turn")
    func recordedEntryKindsMatchSessionTranscriptKinds() async throws {
        let harness = try await makeChokepointHarness()
        defer {
            try? FileManager.default.removeItem(at: harness.recordingsDir)
            try? FileManager.default.removeItem(at: harness.cacheDir)
        }

        _ = try await harness.session.respond(to: "Say 'hi' briefly.", maxTokens: GatedRealModelBudget.responseTokenCeiling)

        let recorded = try recordedEvents(from: harness)

        // The `.session` meta line is router-only and never enters Apple's own
        // transcript; every other recorded kind must match, in order, the kind
        // of the corresponding real `Transcript.Entry` the live session
        // actually accumulated — the whole point of snapshot-diff persistence.
        let recordedEntryKinds = recorded.filter { $0.kind != .session }.map(\.kind)
        let liveEntryKinds = harness.backend.session.transcript.map {
            TranscriptEntryMapper.event(from: $0).kind
        }
        #expect(recordedEntryKinds == liveEntryKinds)
        #expect(!recordedEntryKinds.isEmpty)

        await harness.container.model.evict()
    }

    /// Mirrors ``recordedEntryKindsMatchSessionTranscriptKinds()`` but drives
    /// the live turn through ``RoutedSessionActor/streamResponse(to:maxTokens:)``
    /// instead of `respond(to:maxTokens:)`: both generation entry points funnel
    /// through the same snapshot-diff chokepoint, so the fidelity invariant
    /// must hold identically for the streaming path against a real model too.
    @Test(
        "recorded entry kinds match the real session.transcript kinds one-for-one after a live streaming turn"
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

        let recordedEntryKinds = recorded.filter { $0.kind != .session }.map(\.kind)
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
    /// 2026-08-21 at fork pin `41e9f41` it printed `tokensIn=62 tokensOut=149`,
    /// the measurement ``MLXFoundationModelsSessionBackend/usageTokenCounts()``'s
    /// doc comment records.
    @Test("recorded tokensIn/tokensOut on the turn's response event exactly match the live backend's own usageTokenCounts() delta")
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

    // MARK: - KV cache reuse across turns (the hard proof)

    @Test(
        "turn 2's usage.input.cachedTokenCount is positive, covers turn 1's whole prompt, and does not exceed everything turn 1 processed — the KV cache is reused, not recomputed"
    )
    func secondTurnReusesFirstTurnsKVCache() async throws {
        let container = try await RealModelContainer.load(ref: sessionBackendTinyModel)
        let backend = try #require(
            container.makeSession(instructions: "You are a terse, literal assistant.")
                as? MLXFoundationModelsSessionBackend
        )

        _ = try await backend.respond(
            to: "My favorite color is teal. Reply with just \"OK\".", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let turn1Usage = backend.session.usage

        // Nothing could have been cached before the very first turn ever ran.
        #expect(turn1Usage.input.cachedTokenCount == 0)
        #expect(turn1Usage.input.totalTokenCount > 0)
        #expect(turn1Usage.output.totalTokenCount > 0)

        // The two bounds of what turn 2 can reuse. Turn 1's prompt (the
        // instructions entry included) is the prefix of the transcript turn 2
        // sends, so it is the least turn 2 can serve from cache. Turn 1's
        // prompt plus its own generated response is everything turn 1
        // processed, so it is the most turn 2 can serve from cache.
        let turn1PromptTokenCount = turn1Usage.input.totalTokenCount
        let turn1ProcessedTokenCount =
            turn1PromptTokenCount + turn1Usage.output.totalTokenCount

        _ = try await backend.respond(
            to: "What is my favorite color? Answer with just the color, lowercase.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        let turn2Usage = backend.session.usage

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
            turn2Usage.input.cachedTokenCount > 0,
            "turn 2 must reuse turn 1's KV cache; cachedTokenCount == 0 means no cache reuse happened"
        )

        // Printed, not asserted: the split of turn 1 between prompt and
        // response, beside what turn 2 reused, for a human to read when a
        // bound below fails.
        print(
            "[secondTurnReusesFirstTurnsKVCache] turn1In=\(turn1PromptTokenCount) "
                + "turn1Out=\(turn1Usage.output.totalTokenCount) "
                + "turn2Cached=\(turn2Usage.input.cachedTokenCount)"
        )

        // Bounds, not an approximate equality against prompt plus response.
        // Turn 2 reuses turn 1's prompt, but it does not always reuse turn 1's
        // response. The fork's cache ledger holds turn 1's render plus every
        // token turn 1 generated, and `TranscriptConverter` drops prior-turn
        // `.reasoning` entries from the chat history on purpose. A reasoning
        // model such as Muse Glimmer reasons in a `to=self` channel directly
        // after the generation prompt, so turn 2's render diverges from the
        // ledger at the first generated token, and the fork rewinds the cache
        // to the end of turn 1's prompt. Measured 2026-08-21 at fork pin
        // 41e9f41: turn1In=49 turn1Out=84 turn2Cached=50. An equality against
        // prompt plus response thus rests on a premise that is false for a
        // reasoning model. The two bounds still fail on a zero, on a partial
        // reuse of the prompt, and on an over-report. Decision: card ^dmxsxb0.
        #expect(
            turn2Usage.input.cachedTokenCount >= turn1PromptTokenCount,
            """
            cachedTokenCount (\(turn2Usage.input.cachedTokenCount)) must cover turn 1's whole prompt \
            (\(turn1PromptTokenCount)); less means turn 2 recomputed part of the prefix
            """
        )
        #expect(
            turn2Usage.input.cachedTokenCount <= turn1ProcessedTokenCount,
            """
            cachedTokenCount (\(turn2Usage.input.cachedTokenCount)) must not exceed everything turn 1 \
            processed (\(turn1ProcessedTokenCount)); more is an over-report
            """
        )

        await container.model.evict()
    }

    // MARK: - Timing signal (best-effort, non-fatal)

    @Test(
        "turn 2 tends to be faster than turn 1 on a session with a long system instruction (heuristic timing signal, never fails CI)"
    )
    func secondTurnTendsToBeFasterThanFirst() async throws {
        let container = try await RealModelContainer.load(ref: sessionBackendTinyModel)
        // A long instruction makes the fixed, cacheable prefix turn 2 should
        // reuse a much larger share of the input than a short one would, so a
        // real speed-up (if the cache is working) is more likely to be
        // visible above run-to-run noise on a tiny model.
        let longInstructions = String(
            repeating:
                "You are a careful, terse assistant who always answers in as few words as possible. ",
            count: 40
        )
        let backend = try #require(
            container.makeSession(instructions: longInstructions) as? MLXFoundationModelsSessionBackend
        )

        let turn1Start = Date()
        _ = try await backend.respond(to: "Say just 'OK'.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let turn1Duration = Date().timeIntervalSince(turn1Start)

        let turn2Start = Date()
        _ = try await backend.respond(to: "Say just 'OK' again.", maxTokens: GatedRealModelBudget.responseTokenCeiling)
        let turn2Duration = Date().timeIntervalSince(turn2Start)

        // Heuristic/warning only: logged for a human to read, never asserted.
        // A ratio near (or above) 1.0 would be a signal worth investigating —
        // that the cache is not meaningfully speeding up turn 2 even if
        // `cachedTokenCount` reports reuse — but flaky wall-clock timing on
        // shared CI hardware must never fail this suite.
        let ratio = turn1Duration > 0 ? turn2Duration / turn1Duration : .nan
        print(
            "[secondTurnTendsToBeFasterThanFirst] turn1=\(turn1Duration)s turn2=\(turn2Duration)s ratio=\(ratio)"
        )

        await container.model.evict()
    }
}
