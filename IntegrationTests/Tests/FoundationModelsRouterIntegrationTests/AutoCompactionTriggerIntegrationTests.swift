import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

// MARK: - Model

/// The real `mlx-community` model this suite drives, and deliberately NOT
/// ``RealModels/standard``.
///
/// The same model ``CompactionSmokeIntegrationTests`` names, for the same
/// reasons. It is 680 MB on disk against 18 GB for ``RealModels/standard``, it
/// is a real instruct model that follows the compaction prompt's own section
/// structure, and it writes no `<think>` block. See that suite's own constant
/// for the measurement behind each of those three.
private let autoCompactionTriggerModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The working context this suite loads ``autoCompactionTriggerModel`` at.
///
/// This number is load-bearing twice. It is the window every session of this
/// suite reports its ``RoutedSession/contextFill`` against, and it is the
/// ``TokenBudget/limit`` the synthetic trigger below is a fraction of. The two
/// must be the same number: ``TokenBudget/triggerTokens`` states that a budget
/// whose limit differs from the session's window has its trigger silently
/// scaled by the ratio between the two, and this suite compares a measured
/// `contextFill` against ``syntheticTriggerShareOfContext`` directly.
///
/// It is also the window of the session's own model, so the compaction's one
/// summarizer call runs in it when the own model writes the summary.
///
/// The value itself is not load-bearing at all. That is this card's whole
/// point: the trigger is a fraction the test states, so no fixture is sized
/// against this window.
private let autoCompactionTriggerContext = 4096

/// The decoding this suite loads ``autoCompactionTriggerModel`` with.
///
/// Pinned to argmax, for the reason ``CompactionSmokeIntegrationTests`` pins
/// it: the provider default samples from MLX's process-global PRNG, which seeds
/// itself from the clock, so the scripted replies — and therefore the compaction
/// arithmetic this suite asserts on — would differ on every run of identical
/// code. Argmax decoding consumes no randomness, which is what lets a red run
/// here be attributed to the change under test.
private let autoCompactionTriggerSamplingMode: GenerationOptions.SamplingMode = .greedy

/// The calendar date this suite pins into ``autoCompactionTriggerModel``'s
/// prompt.
///
/// The decoding above pins the SAMPLING. It does not pin the PROMPT. The
/// Llama 3.2 chat template writes `Today Date: <today>` into the system header
/// of every call, and it reads that date off the clock. So every scripted
/// reply, and the compaction that reads them, was a new sample on every calendar
/// day. Task ^xfj1am4 measured that here, from one binary with only `TZ`
/// changed: the reply of the answer ran to 143 characters on 01 Sep 2026 and to
/// 136 on 02 Sep 2026.
///
/// A reply is part of its answer, and the answer is part of the transcript the
/// compaction reads. So a reply that moves with the clock moves the fourth fact
/// this suite asserts, which is that the fill FELL across the answer.
///
/// The value comes from ``RealModelContainer/chatTemplateFallbackDate``, which
/// is the template's own fallback and which states why.
private let autoCompactionTriggerChatTemplateDate =
    RealModelContainer.chatTemplateFallbackDate

// MARK: - Suite

/// The fast answer to one question: does a session compact its own transcript,
/// inside an answer, because its budget's trigger was reached?
///
/// ## What this suite proves
///
/// Four facts about the AUTOMATIC path, and the four the card `^d02ryqj` names:
///
/// 1. Measured context usage crossed the trigger before the answer under test
///    ran.
/// 2. A compaction happened inside that answer, and no caller asked for it. The
///    suite never calls ``RoutedSession/compact(prompt:budget:)``. The compaction
///    arrives as a ``SessionEvent/compaction(_:)`` on the answer's own stream,
///    which is the only way a caller learns of one.
/// 3. The answer still came.
/// 4. The transcript the compaction produced is smaller than the transcript it
///    compacted, and the session's own ``RoutedSession/contextFill`` fell across
///    the answer.
///
/// ## What this suite does NOT prove
///
/// **It does not prove the real trigger is well chosen.** The threshold here is
/// a synthetic one — ``syntheticTriggerShareOfContext``, far under
/// ``TokenBudget/trigger``'s own default of 0.80. A synthetic threshold proves
/// the WIRING fires: usage is measured, it is compared against the budget, and
/// the compaction runs and is applied without a caller. Whether 0.80 of a real
/// window is the right moment to compact is a different question, and nothing
/// here measures it.
///
/// It does not prove the summary is any good either. A compaction that carries the
/// facts a resumed session needs is what
/// `FoundationModelsRouterEvalIntegrationTests` measures, over a hand-written
/// dataset.
///
/// It does not prove a compaction works at every fixture size. This suite compacts one
/// small transcript with one model.
///
/// ## Why a synthetic threshold, rather than a bigger fixture
///
/// Auto-compaction had no fast test at all before this one. The automatic path
/// was measured only by ``CompactionRoundTripIntegrationTests``, at 425
/// seconds against the 30B model, and that suite had to grow its scripted
/// answers twice to keep crossing the 0.80 trigger of its own window — once
/// because the fixture reached 41% of the trigger, and once because it stopped
/// 5 tokens short. ``ScriptedAnswerSizingTests`` exists to hold that arithmetic.
///
/// The trigger is a number. When a test sets it low, a short transcript
/// crosses it, and the whole fixture-sizing arithmetic disappears.
///
/// ## The trigger is injectable through the PUBLIC surface
///
/// No production code changed to make this suite possible, and none needed to.
/// ``TokenBudget`` is public, its initializer takes `limit`, `trigger` and
/// `target` as ordinary parameters, and
/// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:toolOutputProtection:repetitionDetection:)``
/// takes the budget. Every knob this suite sets is one a caller outside the
/// package can set.
///
/// ## What this suite measured before task ^pke18c2
///
/// Every number in this section predates task ^pke18c2, which made the
/// compaction one summarizer call over the whole live context. The suite then
/// drove three answers and set a target of 4 tokens. Under one call, a target
/// that small leaves no room for a summary after the instructions, so the
/// suite now states ``compactionTargetShareOfContext`` and drives two answers.
/// Nobody has measured this suite again since that change.
///
/// Measured on 2026-08-18, on an Apple silicon box with the model already in
/// the Hugging Face cache. Three consecutive runs, each printing its own
/// numbers through the test body:
///
/// | run | wall clock | of which model load |
/// |---|---|---|
/// | 1 | 4.7 s | 1.9 s |
/// | 2 | 5.0 s | 2.0 s |
/// | 3 | 5.0 s | 2.0 s |
///
/// The run made four generations: one for each of the three scripted answers,
/// and one for the compaction's summarizer call. All three runs reported
/// identical compaction numbers, which is ``autoCompactionTriggerSamplingMode``
/// doing its job. Measured on 2026-09-01, with
/// ``autoCompactionTriggerChatTemplateDate`` in place:
///
/// | what the run measured | value |
/// |---|---|
/// | the synthetic trigger, in tokens | 82 |
/// | context fill before the answer | 0.167236328125 |
/// | context fill after the answer | 0.1142578125 |
/// | compacts inside the answer | 1 |
/// | the compaction's transcript, before and after | 733 -> 426 |
/// | the answer's own reply | 147 characters |
/// | the test's wall clock | 7.2 s, of which 1.8 s the model load |
///
/// The suite reported exactly that row under `TZ=Pacific/Midway`
/// (01 Sep 2026) and under `TZ=Pacific/Kiritimati` (02 Sep 2026), from one
/// binary with nothing else changed. The clock no longer reaches this compaction.
///
/// These numbers WILL move again, because the prompt moves whenever the
/// compaction prompt or the fixture changes. That is expected, and it is not a
/// regression. The suite has no time limit. A run ends when it ends, or when
/// the caller stops it.
///
/// One of the three compaction smoke suites, with
/// ``CompactionSmokeIntegrationTests`` and
/// ``RecordedTranscriptCompactionIntegrationTests``. The three answer one
/// question — does compaction work at all against a real model — in seconds.
@Suite(
    "Real-model smoke test: a synthetic trigger compacts a short transcript inside its own answer (task ^d02ryqj)",
    .exclusiveRealModel
)
struct AutoCompactionTriggerIntegrationTests {
    // MARK: - The synthetic threshold

    /// Where this suite puts the compaction trigger, as a share of
    /// ``autoCompactionTriggerContext``.
    ///
    /// This is the card's whole device, and the number is chosen to be far
    /// under anything a fixture could be sized against. It resolves to 82
    /// tokens of the 4096-token window, against the 3277 tokens
    /// ``TokenBudget/trigger``'s own default of 0.80 resolves to. The first
    /// scripted answer alone measures several times 82, so the trigger is
    /// crossed by construction rather than by arithmetic over the fixture.
    private static let syntheticTriggerShareOfContext = 0.02

    /// Where this suite puts the compaction target, as a share of
    /// ``autoCompactionTriggerContext``: the trigger's own share.
    ///
    /// The compaction brings the live context back to the size at which the
    /// trigger fires, so this suite states no second number. The compaction
    /// states the target less the instructions as the summary's size. The
    /// instructions are ``instructions``, one sentence, and the trigger's 82
    /// tokens leave room for a summary after them. A target that left no room
    /// stops the compaction with ``CompactionShortfall/targetLeavesNoRoomForSummary(allowedSummaryTokens:)``,
    /// and the assertion below names that shortfall.
    ///
    /// The target is far under the live context the first answer builds, so the
    /// compaction always makes its one summarizer call. It does not depend on
    /// how long the model's own replies happen to run, which is the defect
    /// `f80n046` records against ``CompactionRoundTripIntegrationTests``.
    private static let compactionTargetShareOfContext = syntheticTriggerShareOfContext

    /// The auto-compaction opt-in this suite vends its session with — the one
    /// value that makes the compaction below automatic.
    ///
    /// ``TokenBudget/limit`` is ``autoCompactionTriggerContext`` and not a
    /// number of its own, so a measured `contextFill` and
    /// ``TokenBudget/trigger`` are on one scale. See that constant.
    private static var syntheticBudget: TokenBudget {
        TokenBudget(
            limit: autoCompactionTriggerContext,
            trigger: syntheticTriggerShareOfContext,
            target: compactionTargetShareOfContext
        )
    }

    // MARK: - The fixture

    /// The system instructions the session is created with. The compaction
    /// keeps them in the new snapshot.
    private static let instructions = "You are a terse, literal assistant. Keep every reply to one sentence."

    /// The reply ceiling every scripted answer is submitted with.
    ///
    /// Small, and load-bearing in one direction only. The priming answer below
    /// carries the transcript the compaction reads, and a reply is part of its
    /// answer — so a large ceiling would let the model, rather than this file,
    /// decide how big that transcript is. No assertion reads a reply's
    /// content, so a reply this ceiling stops short costs the suite nothing.
    private static let replyTokenCeiling = 48

    /// The first scripted answer, and the bulk of the live context the
    /// compaction summarizes.
    ///
    /// Its length is deliberate and it is the one fixture dimension that
    /// matters. The compaction states the target less the instructions as the
    /// summary's size, and this answer is many times that size, so a summary
    /// that keeps to the stated size makes the context smaller, and the fill
    /// assertion below measures the wiring rather than the model's own
    /// brevity. A summary the model writes past its stated size and past the
    /// size of this answer fails ``Compactor``'s did-not-shrink check, which is
    /// the shape that discarded 7 of 7 gated compactions in `^fm5ddk9`.
    ///
    /// It holds 2556 bytes of prose, which a character count of the time read
    /// as 639 tokens; both numbers are historical measurements of this fixture.
    ///
    /// This is a bound on the FIXTURE, and it is not the trigger arithmetic
    /// this card removes. Nothing here is sized against a window or a
    /// threshold. The size is what lets a summary be smaller than the text it
    /// replaces.
    private static let openingBrief = """
        Design brief. The rota tool assigns shifts for a hospital ward, and we are rebuilding the part of it that
        decides who is on call. The present rule set is one ordered list that the tool walks from the top for every
        open shift, and the first person it finds who is free takes the shift. That reads well and behaves badly: a
        nurse who is free early in the week collects every awkward slot, because the walk always starts at the same
        place, and nothing in the list records that a person already took two nights running. The replacement scores
        each candidate for each shift and takes the highest score, so a rule that used to be a position in a list
        becomes a term in a sum, and a term can be weighed against the others rather than only ordered before them.
        The terms we have agreed so far are the hours already worked in the window, the count of nights in the last
        fourteen days, the gap since the last weekend off, and a standing preference each person states once and can
        change at any time. Nothing in the score is secret: the tool prints the terms for the shift it just filled, so
        a person who asks why they were chosen gets the arithmetic rather than an assurance. Ties are broken by the
        longest time since the person last took that same shift, and a tie that survives that is broken at random with
        the seed written into the record, so a rota can be rebuilt exactly. The tool never assigns a shift that breaks
        a hard rule. The rest period between shifts, the ceiling on hours in a week, and the qualifications a shift
        requires all stay outside the score, because a hard rule that a large enough preference can outweigh is not a
        hard rule. Shifts nobody can take are reported as unfilled rather than forced onto the least bad candidate,
        and the ward manager fills those by hand. The rota is published a fortnight ahead and is frozen a week ahead,
        so a change inside the last week is a swap between two named people rather than a fresh run of the tool. The
        weights are held in one file the ward manager edits, rather than in the code, and every edit to that file is
        stamped with the date and with the person who made it. A second copy of the tool runs against last quarter's
        records every night and reports each shift the new weights would have filled differently, so a change to a
        weight is measured against real history before it reaches a live rota. Those reports are kept rather than
        merely read, because a difference that appears once and then goes away is the kind we most want to study
        later, and a report that is thrown away leaves nothing to study.
        """

    /// The second scripted answer — the answer under test.
    ///
    /// Short, so the prompt and its reply add little to the snapshot the
    /// compaction leaves, and the fill after the answer stays under the fill
    /// before it. The assertion reads only whether the answer came at all.
    private static let triggeringPrompt = "State how far ahead the rota is published, in one sentence."

    // MARK: - One driven answer

    /// What one scripted answer produced.
    private struct DriveResult {
        /// The reply text, assembled from the answer's own text increments.
        let reply: String

        /// Every compaction the answer took on its own, in the order the answer
        /// reported them.
        ///
        /// A compaction reaches a caller only as a ``SessionEvent/compaction(_:)``,
        /// so this list IS the proof that compaction ran without the caller
        /// asking. The suite calls ``RoutedSession/compact(prompt:budget:)``
        /// nowhere.
        let compactions: [CompactionResult]

        /// The compactions this answer APPLIED — the ones that changed the
        /// transcript.
        ///
        /// ``Compactor`` reports its shortfall exits with an empty
        /// ``CompactionResult/stagesApplied`` and the original transcript, and
        /// a session still emits the event for one. A compaction with no stage is a
        /// compaction that did nothing.
        var appliedCompactions: [CompactionResult] { compactions.filter { !$0.stagesApplied.isEmpty } }
    }

    /// Drives one answer through `session` and reports what it produced.
    ///
    /// Written as a static function rather than a closure over the test body's
    /// own locals: a closure that both hops across the session actor and
    /// mutates the enclosing scope's `var`s trips Swift 6's concurrency
    /// checking, even though every call here is sequential. The evals runner
    /// `CompactionContinuityEvalRealSubjectRunner` records the same constraint.
    ///
    /// - Parameters:
    ///   - session: The session to drive the answer on.
    ///   - prompt: The prompt text of the answer.
    /// - Returns: The answer's reply and every compaction it took.
    /// - Throws: Whatever the answer throws.
    private static func drive(_ session: RoutedSession, prompt: String) async throws -> DriveResult {
        var reply = ""
        var compactions: [CompactionResult] = []
        let stream = await session.streamEvents(to: prompt, maxTokens: replyTokenCeiling)
        for try await event in stream {
            switch event {
            case .textDelta(let fragment):
                reply += fragment
            case .compaction(let result):
                compactions.append(result)
            default:
                break
            }
        }
        return DriveResult(reply: reply, compactions: compactions)
    }

    // MARK: - The test

    @Test(
        "a session vended with a synthetic trigger compacts inside its own answer: the trigger is crossed, no caller asked, the answer still comes, and the transcript shrinks"
    )
    func aSyntheticTriggerCompactsInsideTheAnswer() async throws {
        let startedAt = Date()
        var modelLoadSeconds = 0.0
        defer {
            print(
                "[autoCompactionTrigger] wallClockSeconds=\(String(format: "%.1f", Date().timeIntervalSince(startedAt))) "
                    + "modelLoadSeconds=\(String(format: "%.1f", modelLoadSeconds))"
            )
        }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AutoCompactionTriggerIntegrationTests-cache-\(UUID().uuidString)", isDirectory: true)
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AutoCompactionTriggerIntegrationTests-recordings-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let loadStartedAt = Date()
        let loaded = try await RealModelContainer.load(
            ref: autoCompactionTriggerModel,
            context: autoCompactionTriggerContext,
            samplingMode: autoCompactionTriggerSamplingMode,
            chatTemplateDate: autoCompactionTriggerChatTemplateDate
        )
        modelLoadSeconds = Date().timeIntervalSince(loadStartedAt)

        let profile = RealModelHarness.make(
            model: autoCompactionTriggerModel,
            context: autoCompactionTriggerContext,
            container: loaded.container,
            samplingMode: loaded.samplingMode,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        let budget = Self.syntheticBudget
        let session = profile.standard.makeSession(
            instructions: Self.instructions,
            budget: budget
        )

        // One priming answer, and it is not the answer under test. A fresh
        // session measures 0 tokens: `ContextUsageState.none` gives a
        // `measuredTokens` of 0, not `nil`. Only `.unknown` gives `nil` and
        // stops the comparison. So the check before the first submission DOES
        // run for the FIRST answer, and it compares 0 against
        // `budget.triggerTokens`. 0 is below any POSITIVE trigger, and
        // `syntheticTriggerShareOfContext` sets a positive one — a trigger of
        // 0.0 resolves to 0 tokens, and the check would fire on the first
        // answer. After this answer the measured usage is past the trigger, so
        // the check of the NEXT answer compacts. A second priming answer would
        // take that compaction itself, and the answer under test would then
        // start from a context already compacted.
        _ = try await Self.drive(session, prompt: Self.openingBrief)

        let contextFillBeforeTheAnswer = await session.contextFill
        let answer = try await Self.drive(session, prompt: Self.triggeringPrompt)
        let contextFillAfterTheAnswer = await session.contextFill

        await loaded.container.model.evict()

        // The run's own numbers, on the record before any assertion reads them
        // — so a red run states what it went red on rather than only which
        // assertion failed.
        print(
            "[autoCompactionTrigger] triggerTokens=\(budget.triggerTokens) targetTokens=\(budget.targetTokens) "
                + "contextFillBefore=\(contextFillBeforeTheAnswer) contextFillAfter=\(contextFillAfterTheAnswer)"
        )
        print(
            "[autoCompactionTrigger] compactionsInTheAnswer=\(answer.compactions.count) "
                + "stages=\(answer.compactions.map(\.stagesApplied)) "
                + "shortfalls=\(answer.compactions.map { String(describing: $0.shortfall) }) "
                + "tiers=\(answer.compactions.map { String(describing: $0.summarizerTier) }) "
                + "tokensBefore=\(answer.compactions.map(\.tokensBefore)) tokensAfter=\(answer.compactions.map(\.tokensAfter)) "
                + "replyCharacters=\(answer.reply.count)"
        )

        // 1. The trigger was crossed before the answer ran. Read as a fill
        //    against `budget.trigger` rather than in tokens, which the two are
        //    only interchangeable for because `budget.limit` IS the session's
        //    window — see `autoCompactionTriggerContext`.
        #expect(
            contextFillBeforeTheAnswer >= budget.trigger,
            "context fill \(contextFillBeforeTheAnswer) did not reach the synthetic trigger \(budget.trigger)"
        )

        // 2. A compaction ran inside the answer, and it was APPLIED. Nothing in
        //    this suite calls `compact(prompt:budget:)`, so the only thing that
        //    could have compacted is the session's own trigger check.
        let compaction = try #require(
            answer.appliedCompactions.last,
            "the answer applied no compaction — it reported \(answer.compactions.count) compaction(s), stages \(answer.compactions.map(\.stagesApplied)), shortfalls \(answer.compactions.map { String(describing: $0.shortfall) })"
        )

        // The stage that compacted, named. A compaction is one summarizer call,
        // and an applied one names that stage alone.
        #expect(
            compaction.stagesApplied == [Summarization.stageName],
            "expected the summary to apply the compaction, got stages \(compaction.stagesApplied)"
        )

        // 3. The answer still came.
        #expect(
            !answer.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the answer compacted its own transcript and then returned no text"
        )

        // 4. The transcript the compaction produced is smaller than the one it
        //    compacted, and the session reports the saving as its own fill.
        #expect(
            compaction.tokensAfter < compaction.tokensBefore,
            "tokensAfter \(compaction.tokensAfter) did not fall under tokensBefore \(compaction.tokensBefore)"
        )
        #expect(
            contextFillAfterTheAnswer < contextFillBeforeTheAnswer,
            "context fill \(contextFillAfterTheAnswer) did not fall under the pre-compaction \(contextFillBeforeTheAnswer)"
        )
    }
}
