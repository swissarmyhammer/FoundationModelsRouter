import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

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
/// The value itself is not load-bearing at all. That is this card's whole
/// point: the trigger is a fraction the test states, so no fixture is sized
/// against this window.
private let autoCompactionTriggerContext = 4096

/// The decoding this suite loads ``autoCompactionTriggerModel`` with.
///
/// Pinned to argmax, for the reason ``CompactionSmokeIntegrationTests`` pins
/// it: the provider default samples from MLX's process-global PRNG, which seeds
/// itself from the clock, so the scripted replies — and therefore the fold
/// arithmetic this suite asserts on — would differ on every run of identical
/// code. Argmax decoding consumes no randomness, which is what lets a red run
/// here be attributed to the change under test.
private let autoCompactionTriggerSamplingMode: GenerationOptions.SamplingMode = .greedy

/// The wall-clock bound this suite runs under, in minutes.
///
/// Stated as a constant so the number carries its measurement. See the suite's
/// own doc comment for the measured run behind it.
private let autoCompactionTriggerTimeLimitMinutes = 1

// MARK: - Suite

/// The fast answer to one question: does a session fold its own transcript,
/// inside a turn, because its budget's trigger was reached?
///
/// ## What this suite proves
///
/// Four facts about the AUTOMATIC path, and the four the card `^d02ryqj` names:
///
/// 1. Measured context usage crossed the trigger before the turn under test
///    ran.
/// 2. A fold happened inside that turn, and no caller asked for it. The suite
///    never calls ``RoutedSession/compact(prompt:budget:)``. The fold arrives
///    as a ``SessionEvent/compaction(_:)`` on the turn's own stream, which is
///    the only way a caller learns of one.
/// 3. The turn still answered.
/// 4. The transcript the fold produced is smaller than the transcript it
///    folded, and the session's own ``RoutedSession/contextFill`` fell across
///    the turn.
///
/// ## What this suite does NOT prove
///
/// **It does not prove the real trigger is well chosen.** The threshold here is
/// a synthetic one — ``syntheticTriggerShareOfContext``, far under
/// ``TokenBudget/trigger``'s own default of 0.80. A synthetic threshold proves
/// the WIRING fires: usage is measured, it is compared against the budget, and
/// the fold runs and is applied without a caller. Whether 0.80 of a real
/// window is the right moment to fold is a different question, and nothing
/// here measures it.
///
/// It does not prove the summary is any good either. A fold that carries the
/// facts a resumed session needs is what `FoundationModelsRouterEvals`
/// measures, over a hand-written dataset, against the 30B model. That tier
/// stays where it is.
///
/// It does not prove a fold works at every fixture size. This suite folds one
/// small transcript with one model.
///
/// ## Why a synthetic threshold, rather than a bigger fixture
///
/// Auto-compaction had no fast test at all before this one. The automatic path
/// was measured only by ``CompactionRoundTripIntegrationTests``, at 425
/// seconds against the 30B model, and that suite had to grow its scripted
/// turns twice to keep crossing the 0.80 trigger of its own window — once
/// because the fixture reached 41% of the trigger, and once because it stopped
/// 5 tokens short. ``ScriptedTurnSizingTests`` exists to hold that arithmetic.
///
/// The trigger is a number. When a test sets it low, a short transcript
/// crosses it, and the whole fixture-sizing arithmetic disappears.
///
/// ## The trigger is injectable through the PUBLIC surface
///
/// No production code changed to make this suite possible, and none needed to.
/// ``TokenBudget`` is public, its initializer takes `limit` and `trigger` as
/// ordinary parameters, and
/// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
/// takes the budget. The recency window rides on the same call, as
/// ``Summarization/keepRecentTurns``. Every knob this suite sets is one a
/// caller outside the package can set.
///
/// ## The measurement behind ``autoCompactionTriggerTimeLimitMinutes``
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
/// The run makes four generations: one for each of the three scripted turns,
/// and one for the fold's summarizer call. All three runs reported identical
/// fold numbers, which is ``autoCompactionTriggerSamplingMode`` doing its job:
///
/// | what the run measured | value |
/// |---|---|
/// | the synthetic trigger, in tokens | 82 |
/// | the fold target, in tokens | 4 |
/// | context fill before the turn | 0.167 |
/// | context fill after the turn | 0.107 |
/// | folds inside the turn | 1 |
/// | stages the fold applied | elision, truncation, summarization |
/// | the fold's transcript, before and after | 733 -> 369 |
///
/// The limit is one minute, roughly twelve times the measured run and the
/// smallest `.timeLimit` Swift Testing accepts.
/// One of the three compaction smoke suites, with
/// ``CompactionSmokeIntegrationTests`` and
/// ``RecordedTranscriptCompactionIntegrationTests``. The three answer one
/// question — does compaction work at all against a real model — in seconds.
///
@Suite(
    "Real-model smoke test: a synthetic trigger folds a short transcript inside its own turn (task ^d02ryqj)",
    .timeLimit(.minutes(autoCompactionTriggerTimeLimitMinutes)),
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
    /// scripted turn alone measures several times 82, so the trigger is
    /// crossed by construction rather than by arithmetic over the fixture.
    private static let syntheticTriggerShareOfContext = 0.02

    /// Where this suite puts the fold target, as a share of
    /// ``autoCompactionTriggerContext``.
    ///
    /// Low enough to be unreachable, on purpose. ``Compactor`` runs
    /// ``ToolOutputElision`` and ``TurnTruncation`` first and stops as soon as
    /// one of them lands the transcript under target. Neither can reach 4
    /// tokens, so the pipeline always falls through to ``Summarization`` and
    /// the fold this suite asserts on is always the model-assisted one.
    ///
    /// A target the deterministic stages COULD reach would make which stage
    /// folded depend on how long the model's own replies happened to run,
    /// which is the defect `f80n046` records against
    /// ``CompactionRoundTripIntegrationTests``.
    private static let foldTargetShareOfContext = 0.001

    /// The auto-compaction opt-in this suite vends its session with — the one
    /// value that makes the fold below automatic.
    ///
    /// ``TokenBudget/limit`` is ``autoCompactionTriggerContext`` and not a
    /// number of its own, so a measured `contextFill` and
    /// ``TokenBudget/trigger`` are on one scale. See that constant.
    private static var syntheticBudget: TokenBudget {
        TokenBudget(
            limit: autoCompactionTriggerContext,
            trigger: syntheticTriggerShareOfContext,
            target: foldTargetShareOfContext
        )
    }

    // MARK: - Fold tuning

    /// How many of the newest turns every fold on this session leaves
    /// untouched, and deliberately not ``Summarization``'s own default of 4.
    ///
    /// This is what lets a THREE-turn conversation fold. ``Summarization``
    /// answers `nil` when every turn is still inside the recency window, and
    /// ``Compactor`` then returns the original transcript with no stage
    /// applied. At the default of 4 the session would have to reach five turns
    /// before a fold could do anything, and each turn is a real generation.
    ///
    /// One is the smallest window that is still a window: the fold replaces
    /// every turn before the newest, and the newest turn stays verbatim.
    ///
    /// ``Compactor/stages`` is a fixed `static let` at the default of 4, so
    /// ``TurnTruncation`` still keeps four turns and removes nothing here. That
    /// costs the run nothing — it removes no entry and makes no model call —
    /// and ``foldTargetShareOfContext`` means the pipeline never stops there
    /// anyway.
    private static let foldKeepRecentTurns = 1

    /// The tokens every summarizer call of this suite is given on top of its
    /// summary allowance, and deliberately not ``Summarization``'s own default
    /// of 4096.
    ///
    /// The same value ``CompactionSmokeIntegrationTests`` uses, for the same
    /// measured reason: that default is sized for a model that always writes a
    /// `<think>` block before its answer, and ``autoCompactionTriggerModel``
    /// writes no such block. Cutting it bounds the one unbounded cost in the
    /// run, which is the summarizer generation.
    private static let reasoningTokenHeadroom = 128

    /// The model-assisted stage this suite vends its session with.
    ///
    /// A session is where this choice belongs, because an automatic fold has no
    /// caller to pass one to. That is exactly why
    /// ``RoutedSessionActor/summarization`` exists, and it is what makes the
    /// recency window a test input here.
    private static var foldSummarization: Summarization {
        Summarization(
            keepRecentTurns: foldKeepRecentTurns,
            reasoningTokenHeadroom: reasoningTokenHeadroom
        )
    }

    // MARK: - The fixture

    /// The system instructions the session is created with. No compaction stage
    /// may touch the header the instructions sit in.
    private static let instructions = "You are a terse, literal assistant. Keep every reply to one sentence."

    /// The reply ceiling every scripted turn is submitted with.
    ///
    /// Small, and load-bearing in one direction only. The two priming turns
    /// below carry the transcript the fold reads, and a reply is part of its
    /// turn — so a large ceiling would let the model, rather than this file,
    /// decide how big the recency window is. No assertion reads a reply's
    /// content, so a reply this ceiling truncates costs the suite nothing.
    private static let replyTokenCeiling = 48

    /// The first scripted turn, and the whole of the span the fold replaces.
    ///
    /// Its length is deliberate and it is the one fixture dimension that
    /// matters. ``Summarization`` gives a call a summary allowance of
    /// ``Summarization/summaryTokenRatio`` (0.25) of the content it condenses,
    /// never under ``Summarization/minimumSummaryTokens`` (128). That floor
    /// binds for any span under 512 estimated tokens, and while it binds the
    /// allowance stops falling with the span — so a SMALL span can buy a
    /// summary as large as itself, and ``Compactor`` then discards the fold for
    /// failing to shrink the transcript. That is the exit which discarded 7 of
    /// 7 gated folds in `^fm5ddk9`.
    ///
    /// So this turn is written past the floor rather than up to it. It
    /// estimates 639 tokens, measured with ``Compactor/estimatedTokenCount(of:)``'s
    /// own arithmetic over its 2556 bytes, against the 512 where the floor
    /// stops binding. It stays well under ``Summarization/maxChunkTokens``
    /// (2000), so the span is ONE chunk and the fold costs ONE generation.
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

    /// The second scripted turn.
    ///
    /// Short, and its only job is to exist. It is the recency window at the
    /// moment the fold runs, so the fold leaves it verbatim, and a short window
    /// is what makes the folded transcript small.
    private static let followUpPrompt = "Name the first tie-breaker the tool applies."

    /// The third scripted turn — the turn under test.
    ///
    /// Short, for the same reason as ``followUpPrompt``, and it asks for
    /// something the model can answer from the recency window alone. The
    /// assertion reads only whether the turn answered at all.
    private static let triggeringPrompt = "State how far ahead the rota is published, in one sentence."

    // MARK: - One driven turn

    /// What one scripted turn produced.
    private struct TurnOutcome {
        /// The reply text, assembled from the turn's own text increments.
        let reply: String

        /// Every fold the turn took on its own, in the order the turn reported
        /// them.
        ///
        /// A fold reaches a caller only as a ``SessionEvent/compaction(_:)``,
        /// so this list IS the proof that compaction ran without the caller
        /// asking. The suite calls ``RoutedSession/compact(prompt:budget:)``
        /// nowhere.
        let folds: [CompactionResult]

        /// The folds this turn APPLIED — the ones that changed the transcript.
        ///
        /// ``Compactor`` reports its shortfall exits with an empty
        /// ``CompactionResult/stagesApplied`` and the original transcript, and
        /// a session still emits the event for one. A fold with no stage is a
        /// fold that did nothing.
        var appliedFolds: [CompactionResult] { folds.filter { !$0.stagesApplied.isEmpty } }
    }

    /// Drives one turn through `session` and reports what it produced.
    ///
    /// Written as a static function rather than a closure over the test body's
    /// own locals: a closure that both hops across the session actor and
    /// mutates the enclosing scope's `var`s trips Swift 6's concurrency
    /// checking, even though every call here is sequential. The evals runner
    /// `CompactionContinuityEvalRealSubjectRunner` records the same constraint.
    ///
    /// - Parameters:
    ///   - session: The session to drive the turn on.
    ///   - prompt: The turn's prompt text.
    /// - Returns: The turn's reply and every fold it took.
    /// - Throws: Whatever the turn throws.
    private static func drive(_ session: RoutedSession, prompt: String) async throws -> TurnOutcome {
        var reply = ""
        var folds: [CompactionResult] = []
        let stream = await session.streamEvents(to: prompt, maxTokens: replyTokenCeiling)
        for try await event in stream {
            switch event {
            case .textDelta(let fragment):
                reply += fragment
            case .compaction(let result):
                folds.append(result)
            default:
                break
            }
        }
        return TurnOutcome(reply: reply, folds: folds)
    }

    // MARK: - The test

    @Test(
        "a session vended with a synthetic trigger folds inside its own turn: the trigger is crossed, no caller asked, the turn still answers, and the transcript shrinks"
    )
    func aSyntheticTriggerFoldsInsideTheTurn() async throws {
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
        let container = try await RealModelContainer.load(
            ref: autoCompactionTriggerModel,
            context: autoCompactionTriggerContext,
            samplingMode: autoCompactionTriggerSamplingMode
        )
        modelLoadSeconds = Date().timeIntervalSince(loadStartedAt)

        let profile = RealModelHarness.make(
            model: autoCompactionTriggerModel,
            context: autoCompactionTriggerContext,
            container: container,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        let budget = Self.syntheticBudget
        let session = profile.standard.makeSession(
            instructions: Self.instructions,
            budget: budget,
            summarization: Self.foldSummarization
        )

        // Two priming turns, and neither is the turn under test. A fresh
        // session measures 0 tokens: `ContextUsageState.none` gives a
        // `measuredTokens` of 0, not `nil`. Only `.unknown` gives `nil` and
        // stops the comparison. So the pre-turn check DOES run on the FIRST
        // turn, and it compares 0 against `budget.triggerTokens`. 0 is below
        // any POSITIVE trigger, and `syntheticTriggerShareOfContext` sets a
        // positive one — a trigger of 0.0 resolves to 0 tokens, and the check
        // would fire on turn one. The fold also needs a turn outside the
        // recency window to summarize. Two turns is the smallest transcript
        // the automatic path can fold at `foldKeepRecentTurns`.
        _ = try await Self.drive(session, prompt: Self.openingBrief)
        _ = try await Self.drive(session, prompt: Self.followUpPrompt)

        let contextFillBeforeTheTurn = await session.contextFill
        let turn = try await Self.drive(session, prompt: Self.triggeringPrompt)
        let contextFillAfterTheTurn = await session.contextFill

        await container.model.evict()

        // The run's own numbers, on the record before any assertion reads them
        // — so a red run states what it went red on rather than only which
        // assertion failed.
        print(
            "[autoCompactionTrigger] triggerTokens=\(budget.triggerTokens) targetTokens=\(budget.targetTokens) "
                + "contextFillBefore=\(contextFillBeforeTheTurn) contextFillAfter=\(contextFillAfterTheTurn)"
        )
        print(
            "[autoCompactionTrigger] foldsInTheTurn=\(turn.folds.count) "
                + "stages=\(turn.folds.map(\.stagesApplied)) "
                + "tokensBefore=\(turn.folds.map(\.tokensBefore)) tokensAfter=\(turn.folds.map(\.tokensAfter)) "
                + "replyCharacters=\(turn.reply.count)"
        )

        // 1. The trigger was crossed before the turn ran. Read as a fill
        //    against `budget.trigger` rather than in tokens, which the two are
        //    only interchangeable for because `budget.limit` IS the session's
        //    window — see `autoCompactionTriggerContext`.
        #expect(
            contextFillBeforeTheTurn >= budget.trigger,
            "context fill \(contextFillBeforeTheTurn) did not reach the synthetic trigger \(budget.trigger)"
        )

        // 2. A fold ran inside the turn, and it was APPLIED. Nothing in this
        //    suite calls `compact(prompt:budget:)`, so the only thing that
        //    could have folded is the session's own trigger check.
        let fold = try #require(
            turn.appliedFolds.last,
            "the turn applied no fold — it reported \(turn.folds.count) fold(s), stages \(turn.folds.map(\.stagesApplied))"
        )

        // The stage that folded, named. `foldTargetShareOfContext` puts the
        // deterministic stages out of reach, so the model-assisted stage is
        // what applied this fold, and a run where it did not is a run that
        // measured something else.
        #expect(
            fold.stagesApplied.last == Summarization.stageName,
            "expected the model-assisted stage to apply the fold, got stages \(fold.stagesApplied)"
        )

        // 3. The turn still answered.
        #expect(
            !turn.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the turn folded its own transcript and then returned no text"
        )

        // 4. The transcript the fold produced is smaller than the one it
        //    folded, and the session reports the saving as its own fill.
        #expect(
            fold.tokensAfter < fold.tokensBefore,
            "tokensAfter \(fold.tokensAfter) did not fall under tokensBefore \(fold.tokensBefore)"
        )
        #expect(
            contextFillAfterTheTurn < contextFillBeforeTheTurn,
            "context fill \(contextFillAfterTheTurn) did not fall under the pre-fold \(contextFillBeforeTheTurn)"
        )
    }
}
