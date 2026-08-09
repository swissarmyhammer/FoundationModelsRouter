---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzgwp590yf3tte6jegt0jatt
  text: |-
    ### Research — root cause found, with numbers

    **Answer to "which side is wrong": the hermetic sizing estimate.** And a *second*, independent accounting bug in the trigger comparison. The live `contextFill` denominator is the only one of the three that is correct.

    #### Bug 1 — `Compactor.estimatedTokenCount(of:)` measures the JSON envelope, not the text

    `Compactor.payloadByteCount(of:)` does `JSONEncoder().encode(TranscriptEntryMapper.event(from: entry).payload)` and `estimatedTokenCount(bytes:)` then divides that by `charsPerTokenEstimate = 4.0` — a ratio whose own doc comment says it is "the commonly cited average for **English text** under BPE-style tokenizers". The bytes being divided are not English text. They are the on-disk `TranscriptEntryPayload` envelope: `entryId`, `contentRemoved`, every segment's `id` and `"type":"text"` discriminator, braces, quotes, commas, and `\n` → `\\n` escaping. None of that is ever sent to the model, so none of it is ever tokenized.

    Measured (throwaway diagnostic over a 5-entry transcript built from `CompactionRoundTripIntegrationTests.scriptedTurns`' first two turns):

    ```
    entries=5 contentChars=843 contentEstimate=210 payloadEstimate=369
    per-entry payload bytes: 154 (instructions, 27 content chars)
                             523 (prompt, ~400 content chars)
                             139 (response, 13 content chars)
    ```

    - **1.76x inflation** overall — the card's "roughly 2x".
    - A **fixed ~125 bytes (~31 phantom tokens) of envelope per entry**, independent of content. The fixtures use short ids (`prompt-1`, `prompt-1-text`); the SDK's real transcripts use UUIDs, making it ~180 bytes / ~45 phantom tokens per entry.

    The codebase already knows about this asymmetry: `Summarization.estimatedTokens(of text:)`'s doc says it applies the ratio "directly to a plain string's UTF-8 byte count **rather than a JSON-encoded payload**".

    This is why the two "sizing" tests pass while live fill says 0.41 — they are denominated in inflated envelope-tokens, and live `contextFill` is denominated in real tokenizer tokens.

    #### The 0.413 / 0.4277 numbers decode exactly

    - `fillBeforeCompaction = 0.4130859375` × 2048 = **846** — real tokenizer tokens from `LanguageModelSession.usage`, via `usageDelta`. Honest: the 8 scripted turns really are only ~846 tokens.
    - `fillAfterCompaction = 0.427734375` × 2048 = **876** — and 876 is `CompactionResult.tokensAfter`, written into `contextFill`'s numerator by `RoutedSession.fold`: `usageState = .measured(input: result.tokensAfter, output: 0)`.

    So the card's reading "`compact()` folded nothing" is **wrong**: the fold *did* run (assertions at :300/:301 are not in the failure list, so `stagesApplied` was non-empty and `tokensAfter < tokensBefore`). Fill grew because one writer of `contextFill`'s numerator uses real tokenizer counts and the other writes the inflated envelope estimate. Two units, one number.

    #### Bug 2 — the trigger compares two different denominators

    `RoutedSession.runTurn`: `if let budget = autoCompactionBudget, contextFill >= budget.trigger`.

    `contextFill` is `usageState.fill(contextTokens: contextTokens)` — a fraction of the *session's resolved working context*. `budget.trigger` is documented as a fraction of `budget.limit`. The comparison is only valid when `limit == contextTokens`.

    `CompactionContinuityEvaluation` deliberately passes `TokenBudget(limit: 2048, ...)` while its sessions resolve `CompactionEvalRealModel.context = 8192`. Intended trigger: 2048 × 0.80 = **1638** tokens. Actual trigger: 8192 × 0.80 = **6554** tokens — 4x too high. The tasks top out around ~1100 real tokens, so no fold can ever fire → `foldOccurred` mean exactly `0.0`. Same defect on the `hardCeiling` check.

    #### Third failure is downstream of bug 1

    `CompactionEvaluation` calls `Compactor.compact` directly (no trigger) with `TokenBudget(limit: 4000, target: 0.05)` → targetTokens 200 envelope-tokens ≈ **~110 real tokens**. The fold is forced ~1.8x harder than the design intends, which is the accounting reason the fold over-destroys content. (Any residual recall weakness after the accounting is fixed stays on `^pw807cp`; this card does not absorb it.)

    #### Fixtures really are undersized once the estimate is honest

    `compactionContinuityTaskSpecs` filler/setup steps are ~50-70 characters each; 14 steps ≈ 770 chars ≈ 190 real prompt tokens, plus ≤64 reply tokens each ≈ ~1100 real tokens total, against an intended 1638-token trigger. The hermetic sizing test asserts only `spec.fillerStepCount >= 8` — a step **count**, with no token accounting at all, while its name claims "sized so its filler steps alone exceed the default budget's trigger threshold". That assertion is untrue as written and must be replaced with a real token-size assertion.

    Plan: (1) make `estimatedTokenCount` count content-bearing text, not the JSON envelope; (2) express the trigger/hardCeiling checks in tokens against `budget.limit`; (3) replace the step-count sizing proxy with a real token-size assertion and size fixtures to satisfy it — in that order, so no fixture is resized to brute-force a trigger.
  timestamp: 2026-08-08T14:33:30.656754+00:00
- actor: claude-code
  id: 01kzgy0tpsfmfvypr46q9yq7jz
  text: |-
    ### Implementation landed; ungated green. Gated runs next.

    Ungated: `swift test` → **796 tests, 0 failures** (762 + 22 + 12 across the three targets). The only `warning:` line is SwiftPM's pre-existing `missing creator for mutated node ('…/mlx-swift_Cmlx.bundle/Contents/MacOS')`, a vendored-dependency resource-bundle build-graph warning, not a compiler diagnostic from this change.

    #### Production fixes

    1. **`Compactor.estimatedTokenCount(of: Transcript)` now measures content, not the JSON envelope.** `payloadByteCount(of:)` (JSON-encoded `TranscriptEntryPayload` size) is replaced by `contentByteCount(of:)` over a new `TranscriptEntryPayload.contentByteCount`, which sums only the fields that carry authored or model-visible content — segment content (all four `SegmentPayload` cases), tool definitions, tool calls, a `.toolOutput`'s tool name, asset ids, a reasoning signature's bytes, a response format's schema. `entryId`, segment/tool-call ids, `"type"` discriminators, `contentRemoved`, JSON punctuation and string escaping are all out; `options`/`responseFormatName` are out for the reason `strippingContent()` already documents.

    2. **The trigger and hard ceiling are compared in tokens against `budget.limit`.** New `TokenBudget.triggerTokens` / `targetTokens` / `ceilingTokens` / `fill(measuredTokens:)` (one shared rounding rule) and `ContextUsageState.measuredTokens`. `RoutedSession.runTurn` is now `measuredTokens >= budget.triggerTokens`, and the pre-flight ceiling check `measuredTokens >= budget.ceilingTokens`, instead of `contextFill >= budget.trigger` / `>= hardCeiling`. `contextFill` itself is unchanged — still a fraction of the session's resolved `contextTokens`, which `AutoCompactionTests` asserts deliberately. `Compactor` now reads `budget.targetTokens` rather than recomputing the same product. An unmeasured session (`measuredTokens == nil`) is left alone, matching the old `NaN >= trigger` behavior.

    #### A third bug fell out, and it blocked the fix

    `RoutedSession.loweredRetryTarget(from:)` was `max(target / 2, 0.1)` while its own doc comment says the result is "**strictly lower** than the budget's own configured target". It is not: for any target under `0.2` it returns something `>=` target, and under `0.1` it returns something strictly *greater*. A budget configured to fold to 5% of its limit had its reactive overflow-recovery retry fold to 10% — softer than the target that had already overflowed — so the retry was a guaranteed no-op and the overflow surfaced to the caller. Now `target / 2`, with no absolute floor: a floor stated as a fraction cannot be right when what counts as "meaningfully hard" depends on `limit`.

    This is not incidental. It is what made `AutoCompactionTests.hardCeilingFailsFastThenRecoversWithLivePerAttemptFill` fail once its budget's limit was corrected to match its session's context, and it is the same defect family as the card's: a threshold whose units and denominator do not line up with what it is compared against. Behavior is identical for every pre-existing in-repo target (all `0.25`/`0.35`/`0.9`).

    #### Test-side corrections

    - `AutoCompactionTests.fixedBudget` and `GuidedGenerationTests.autoCompactionFixedBudget` both set `limit: recencyOnly * 2` while their sessions resolved `context: 100_000`. That only "worked" because the trigger was compared against `contextFill`. Both now use `limit: <the session's own context>` with `target` expressed as the fraction landing on half the recency floor, so the trigger fires exactly where each suite's own `contextFill == 0.9` readings say it does, and `Summarization` is still forced. `hardCeilingBudget` is now built by overriding `fixedBudget` rather than restating its numbers.
    - `compactionEvalDefaultBudget` is a named constant, read by both `CompactionEvaluation.init` and the hermetic test that guards it (the test used to restate the literal, so the two could drift). `limit: 4000, target: 0.05` resolved to 200 tokens, **more than half of which was envelope padding**; with the padding gone every seed was already under target and `stagesApplied` came back `[]` for all 24 — the fold stopped happening entirely. Now `limit: 400, target: 0.10` → 40 tokens, below the smallest seed's recency-window floor of 63, so `Summarization` is forced again. That hermetic test earned its keep: it caught this immediately.

    #### Fixture sizing — the numbers, now that the accounting is honest

    Measured with the corrected estimator:

    | fixture set | was | trigger needs | now |
    |---|---|---|---|
    | `compactionContinuityFillerSteps` × 10-12 | 139-156 tokens | 1638 | 2475-2928 |
    | `CompactionRoundTripIntegrationTests.scriptedTurns` × 8 | 718 tokens | 1638 | 1834 |

    Both were ~11x and ~2.3x short. `compactionContinuityFillerSteps` is now six substantial paragraphs (still each closing with a one-word/one-sentence request, so replies stay short and the padding is all prompt-side, and none of them mentions any fixture's planted key phrases). The eight scripted turns are now ~900 characters each on the same weather-archive narrative, with `CRIMSON-77` still in the first.

    #### New ungated coverage (all watched failing first)

    - `CompactionTokenAccountingTests` — contentless entries estimate 0 (was 3 tokens/entry of envelope); the estimate ignores id length (UUID ids vs one-character ids); a text-only transcript agrees *exactly* with the single-string overload (was **139 vs 48**); and it still counts tool-call arguments, tool output, and asset ids, so the envelope fix did not narrow it to `.text` segments.
    - `CompactionContinuityEvaluationTests.everyTaskIsSizedToForceAFold` rewritten: it asserted `spec.fillerStepCount >= 8` — a step **count**, which says nothing about tokens, and which is how a dataset 11x too small shipped green under a test whose name claims "filler steps alone exceed the default budget's trigger threshold". It now measures the filler steps' estimated tokens against `compactionContinuityDefaultBudget.triggerTokens`. Watched failing at 139-156 vs 1638 on all ten fixtures.
    - `ScriptedTurnSizingTests` — a new **ungated** suite in the gated round-trip file (`context`/`scriptedTurns` moved `private` → `fileprivate` so it can read them). Two assertions: the turns carry more prompt tokens than the trigger needs, and the prefix that first crosses the trigger still fits the 2048-token window (so the crossing turn is never submitted with an unfittable prompt). Both watched failing when the turn list was temporarily cut to two entries: "estimate 489 prompt tokens, which does not exceed the trigger's 1638" and "no prefix of the scripted turns crosses the trigger at all".

    Next: the gated runs, one suite per shell command.
  timestamp: 2026-08-08T14:56:48.857065+00:00
- actor: claude-code
  id: 01kzh0e5heycf50nytpv9yyeqv
  text: |-
    ### Gated results — three runs, one suite per command

    #### 1. `CompactionRoundTripIntegrationTests` — GREEN, 61.8s

    ```
    ✔ Test "contextFill climbs, compact() folds at the 0.80 trigger preserving identity,
       a post-compact turn recalls the folded fact, restore yields the checkpointed
       window, and a further turn succeeds" passed after 61.795 seconds
    ✔ Test run with 3 tests in 2 suites passed
    ```

    All four assertions the card listed pass **unmodified**: `fillBeforeCompaction >= 0.80`, `fillAfterCompaction < fillBeforeCompaction`, `recall.contains("CRIMSON-77")`, `checkpointedWindow.count < fullHistory.count`. The third test in the run is the new ungated `ScriptedTurnSizingTests`.

    #### 2. `CompactionContinuityEvaluationIntegrationTests` — `foldOccurred` GREEN

    `mean(foldOccurred) == 1.0` **passes** in both gated runs. The instrumented run shows why, per sample:

    ```
    foldCount=1 before=2149 after=1380     foldCount=1 before=2104 after=1593
    foldCount=1 before=2138 after=1484     foldCount=1 before=2049 after=1531
    foldCount=2 before=2436 after=1965     foldCount=2 before=2293 after=2034
    foldCount=2 before=2426 after=1934     foldCount=1 before=2140 after=1522
    foldCount=1 before=2130 after=1609     foldCount=1 before=2138 after=1593
    ```

    Every one of the ten tasks folded, one or twice, at 2049-2436 tokens against the 1638-token trigger. That is the card's headline symptom — "Not one fold occurred in any sample" — closed.

    `answersCorrect >= 0.8` came back `0.5` on the first run and would have been `0.8` on the second (8 of 10 answers fully correct). It is flaky, not a fixed regression, and the two wrong answers name their own cause — see below. Note this assertion was **not** in the card's list of failures: with no fold ever happening, the model answered from an intact transcript, so it never had to survive a summary.

    #### 3. `CompactionEvaluationIntegrationTests` — `factRetention` still `0.0833`, and it is not an accounting failure

    Unchanged from the card's measurement. The instrumented run settles the cause: **every summary contains the planted fact verbatim.**

    ```
    summary=1. Intent — Inform the assistant of the internal codename for a new feature.
            2. Constraints & decisions — The internal codename for the new feature is "Project Longbow". …
    question=What is the internal codename for the new feature?
    answer=Noted.

    summary=… 2. Constraints & decisions — Staging database port is 6543. …
    question=What port does the staging database listen on?
    answer=Noted.

    summary=… The production deployment region is eu-west-2, selected for data-residency reasons. …
    question=Which region is the production deployment in, and why was it chosen?
    answer=Noted.
    ```

    The fold works. The summary carries the fact. The *answer* is `"Noted."` — the reply that belongs to acknowledging a fact statement in some earlier sample's conversation, not to this question. And where it is not `"Noted."` it is the summarizer's own output format:

    ```
    answer=1. Intent — The user is asking for specific information (return flight number)
           that was provided in the conversation.
    ```

    The two failing continuity samples show the identical signature, and both are `foldCount=2` samples — the ones that made an extra summarizer call:

    ```
    answer=1. Intent — The user asked for two specific pieces of information from the
           conversation history: the escalation time for a tier-1 ticket and the on-call
           escalation contact for the current week.
    answer=1. Intent — The user asked for the exact file paths to the migration script and
           its corresponding rollback script, without re-reading prior context.
    ```

    The other eight answered exactly right, folded facts included: `"The project's vault code is CRIMSON-77, and it is located at outpost Delta-9."`, `"The staging database listens on port 6543 and runs in the eu-west-2 region."`, `"Releases are cut from the \`release/stable\` branch, and they need sign-off from Priya before shipping."`

    This is the `^pw807cp` class, not this card's: a blank-slate summarizer session and the answering session share one resident container, so the summarizer's KV chunks bleed into the turn that follows it. It matches `^pw807cp`'s documented signatures ("narrating a call it never made", "the rebuilt session did not recall a fact its own transcript carried") and its run-to-run variability. Per this card's own scope note I have not absorbed that work; the evidence is filed on `^pw807cp`, whose AC asks for exactly this attribution.

    #### Acceptance criteria status

    - **Root cause identified and stated, with numbers** — done. The hermetic sizing estimate was wrong (JSON envelope counted as tokenizable text, 1.76x inflation, ~31-45 phantom tokens per entry); the live `contextFill` denominator was correct all along; and the trigger comparison was *also* wrong (a fraction of `contextTokens` compared against a fraction of `budget.limit`, 4x off for the continuity eval).
    - **The disagreement is closed** — the hermetic tests and the live measurement now count the same thing, and the sizing test that asserted an untrue claim (`fillerStepCount >= 8`) now measures tokens.
    - **A real fold is reached** — `fillBeforeCompaction >= 0.80` green; `foldOccurred` mean `1.0` green; `factRetention` remains `0.0833`, **attributed by direct evidence to `^pw807cp`** rather than to fill/trigger accounting. This is the one criterion this card cannot close inside its stated scope, and the card's own instruction is what keeps it out.
    - **The four round-trip assertions pass unmodified** — done, none changed.
    - **Ungated `swift test` stays green** — 796 tests, 0 failures.
  timestamp: 2026-08-08T15:39:03.086529+00:00
- actor: claude-code
  id: 01kzh0f9456zd5s5tn2cgem7ah
  text: |-
    ### implement — changed
    - evidence: 18 files. Sources: `Compaction/Compactor.swift`, `Compaction/TokenBudget.swift`, `Recording/TranscriptEntryPayload.swift`, `RoutedLLM.swift`, `Session/RoutedSession.swift`. Tests: `FoundationModelsRouterTests/CompactionTokenAccountingTests.swift` (new), `AutoCompactionTests.swift`, `GuidedGenerationTests.swift`; `FoundationModelsRouterEvals/CompactionContinuityDataset.swift`, `CompactionContinuityEvaluation.swift`, `CompactionContinuityEvaluationTests.swift`, `CompactionEvaluation.swift`, `CompactionEvaluationTests.swift`; `FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift`. Ungated `swift test`: 796 tests, 0 failures. Gated: `CompactionRoundTripIntegrationTests` green (all four listed assertions unmodified); `mean(foldOccurred) == 1.0` green; `mean(factRetention)` still `0.0833`, attributed by direct evidence to `^pw807cp`.
    - next: `/review`. One acceptance criterion (`factRetention` mean >= 0.9) is not closed and cannot be inside this card's stated scope — the summaries provably carry the planted fact verbatim and the *answers* are contaminated; evidence filed on `^pw807cp`.
  timestamp: 2026-08-08T15:39:39.525118+00:00
- actor: claude-code
  id: 01kzh16ggscyzwv2kx0yg5d3rp
  text: |
    ### review — findings

    - evidence: `review sha HEAD~1..HEAD` (commit `bda41be`). Engine counts: 3 findings, 3 confirmed, 0 refuted, 18 attempted, 0 failed, 1 file skipped. 2 of the 3 dropped under the skill's written test-refactor exception (pre-existing lines in `Tests/FoundationModelsRouterEvals/CompactionContinuityEvaluation.swift:194` and `CompactionEvaluation.swift:197`, both deduplications of `TokenBudget.targetTokens` against code blamed to `10955bea` / `598fc24c`, predating this delta). Recorded open: `Sources/FoundationModelsRouter/Session/RoutedSession.swift:1` (341682 rendered bytes over the 262144-byte cap; 9 validators could not review it — and part of this delta's trigger-comparison fix lives in that unreviewed file), plus the unmet acceptance criterion `mean(factRetention) >= 0.9` = `0.0833`.
    - next: split `RoutedSession.swift` so it fits the review prompt cap, then re-review the delta so the 9 skipped validators actually run against the trigger-comparison change. The `factRetention` criterion needs a human decision — the `^pw807cp` attribution is well-evidenced (summaries carry the fact verbatim; the answers are contaminated), but the criterion as written on this card is unmet, so the card cannot advance to done. Task stays in `review`.
  timestamp: 2026-08-08T15:52:20.761581+00:00
- actor: claude-code
  id: 01kzh18p48drcce1zc576ysm07
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 18 files, 3 token-accounting bugs (envelope-vs-content estimate, trigger denominator mismatch, loweredRetryTarget contract violation)
    - test: green — swift test, 796 passed (762+22+12), 0 failures, 0 warnings on changed files
    - commit: bda41be
    - review: findings — Sources/FoundationModelsRouter/Session/RoutedSession.swift:1 (341682 rendered bytes over the 262144 cap; 9 validators skipped, and this delta's trigger-comparison + loweredRetryTarget fixes live in that unreviewed file); unmet AC mean(factRetention) >= 0.9 = 0.0833
    - next: iteration 2 splits RoutedSession.swift to fit the cap so the 9 skipped validators run against the trigger fix. The factRetention criterion is escalated to a human — not checked, card not advanced.
  timestamp: 2026-08-08T15:53:32.040929+00:00
- actor: claude-code
  id: 01kzh1t15k9jzmh0nm5dhpaphj
  text: |-
    ### Iteration 2 research — the split plan for `RoutedSession.swift`

    Card pulled back to `doing`. Working only the first open finding (the 341682-byte review-cap overflow). The `factRetention` criterion stays unchecked and untouched per the escalation.

    **Measured:** `RoutedSession.swift` is 191794 bytes / 3485 lines on disk, rendering to 341682 bytes for the review engine — a 1.78x factor. To be comfortably under the 262144-byte cap after rendering, each resulting file wants to stay well under ~100k on disk; the plan lands every file at 45k or less.

    **Structure found** (`code_context list symbols` on this file overflows the tool's own token cap, so the map came from declaration greps):

    - 1-4 imports; 6-30 three file-private loggers; 32-50 `public enum TurnCancellationResult`; 52-793 `public protocol RoutedSession` + its default-implementation extension; 795-870 `makeRoutedSessionActor`; 880-965 two private `CompactionSummarizer` conformers; 967-3485 `actor RoutedSessionActor` (2519 lines, the bulk).

    **Split (9 sibling files under Session/, extensions of the one actor — no type renamed, no public API touched):**

    1. `RoutedSession.swift` — `TurnCancellationResult`, the protocol, its defaults (~40k)
    2. `RoutedSessionActor.swift` — `makeRoutedSessionActor` + the actor declaration, stored properties, `init`, `deinit` (~31k; stored properties, `init`, and `deinit` cannot live in an extension, so this file is the actor's main declaration)
    3. `RoutedSessionActorCompaction.swift` — both summarizers + `contextFill`, `compact`, `performAutoCompaction`, `FoldSummarizerTier`, `abandonFoldIfCancelled`, `noteAbandonedFold`, `fold` (~22k)
    4. `RoutedSessionActorGeneration.swift` — `respond`/`streamResponse`/`streamEvents`/`streamSessionEvents` + subscription bookkeeping (~14k)
    5. `RoutedSessionActorTurnGating.swift` — `awaitingUser`, `cancelCurrentTurn`, `beginTurn`/`endTurn`, generation permit, human wait (~7.5k)
    6. `RoutedSessionActorForking.swift` — `fork`, `close` (~12k)
    7. `RoutedSessionActorTurnExecution.swift` — `respondBody`, `generate`, `runTurn`, `primeDiscoveryIfConfigured`, `runTurnAttempt`, `recordFailedTurn`, `ModelCallCancellationProbe`, `runCancellableModelCall`, `isTurnCancelled`, `isRecoverableContextOverflow`, **`loweredRetryTarget`** (~35k)
    8. `RoutedSessionActorPromptQueue.swift` — `dispatchNextPrompt` + prompt composition (~11k)
    9. `RoutedSessionActorRecording.swift` — `finishTurn`, `usageDelta`, `recordTranscriptDelta`, `emitSessionEvents`, `recordSessionMetaIfNeeded`, partials (~18k)

    Both of this task's fixes that were unreviewed land in reviewable files: the trigger comparison `measuredTokens >= budget.triggerTokens` / `measuredTokens >= budget.ceilingTokens` in `runTurn` → file 7, and `loweredRetryTarget(from:)` → file 7.

    **Three consequences worth recording before the edit:**

    - **Each logger has exactly one call site**, so all three move with their consumer and stay `private`: `sessionCompactionLogger` → file 3, `sessionPrimingLogger` → file 7, `sessionRecordingLogger` → file 9. Two doc comments elsewhere name `Session/RoutedSession.swift` as the file those live in and must be re-pointed: `Recording/RecordingLanguageModel.swift:8` and `Compaction/Summarization.swift:309`.
    - **`runCancellableModelCall` must widen `fileprivate` → internal.** It is `fileprivate` today only because `CancellableCompactionSummarizer` is a sibling type in the same file. The summarizers belong with compaction (file 3) and the method with turn execution (file 7), so they are no longer file siblings. Widening the one method is the smaller change than making both summarizer types internal.
    - **A pre-existing documentation defect the split forces a decision on:** lines 872-878 document `RoutedSessionActor` ("The concrete ``RoutedSession``, backed by a ``LanguageModelSessionBackend``. It is `internal` with an `internal` initializer so the only way to obtain one is ``RoutedModel/makeSession(instructions:workingDirectory:)``…") but sit fused onto the front of `BackendCompactionSummarizer`'s doc comment, and `actor RoutedSessionActor` itself carries no doc comment at all. Those paragraphs move to the actor declaration in file 2; the summarizer's own doc keeps everything from "Adapts a ``LanguageModelSessionBackend`` to ``CompactionSummarizer``" onward. Verbatim text, correct owner.

    Every moved member is extracted byte-for-byte via `tail`/`head` rather than retyped, and verified against `git show HEAD:` afterwards, so no transcription can alter the token-accounting logic this card just landed.
  timestamp: 2026-08-08T16:03:00.403059+00:00
- actor: claude-code
  id: 01kzh2nedyxken3n17x3b8hqzb
  text: |-
    ### Iteration 2 implementation landed — the file split, with the mechanics and every consequence

    `RoutedSession.swift` is now 8 files, all comfortably under the review engine's cap:

    | file | bytes | ~rendered (1.78x) |
    |---|---|---|
    | `RoutedSessionActorTurnGating.swift` | 7039 | 12529 |
    | `RoutedSessionActorForking.swift` | 13117 | 23348 |
    | `RoutedSessionActorGeneration.swift` | 13980 | 24884 |
    | `RoutedSessionActorCompaction.swift` | 23961 | 42651 |
    | `RoutedSessionActor.swift` | 24604 | 43795 |
    | `RoutedSessionActorRecording.swift` | 25648 | 45653 |
    | `RoutedSessionActorTurnExecution.swift` | 41681 | 74192 |
    | `RoutedSession.swift` | 43470 | 77377 |

    Largest is 6x under the 262144-byte cap, so no file is anywhere near the edge again.

    #### How the move was made safe

    No moved line was retyped. Every member was extracted with `tail`/`head` byte ranges and then `cmp`-verified against `git show HEAD:` — 15 range comparisons, all identical. Then a whole-file conservation check: sort every non-blank line of the old file and of the 8 new files and `comm` them. The only lines that differ are the 46 I intended (34 access-modifier prefixes, 6 reworded doc lines, the dropped `///` doc separator, the extra import lines) and the 42 I authored (6 extension declarations, their doc comments, 6 closing braces). Nothing was dropped and nothing was silently altered — the token-accounting logic this card landed is byte-identical to what the gated runs proved.

    #### One grouping decision reversed mid-work, and why

    The first cut had a ninth file, `RoutedSessionActorPromptQueue.swift`, holding everything between `dispatchNextPrompt` and the prompt-composition statics purely because that is the order the original file happened to use. It was a weak grouping — most of its contents were turn-finishing helpers — and it forced six extra members to widen. Re-cut: `finishTurnAndRequeueIfUnattached`, `requeueUnattachedPendingEvents`, and `appendingOperationEventSegments` went to the file that owns `finishTurn`/`recordTranscriptDelta` (Recording), and `dispatchNextPrompt` plus `composedPrompt`/`flattenedPromptText` went to the file that owns the chokepoint (TurnExecution). That left `finishTurn`, `requeueUnattachedPendingEvents`, `appendingOperationEventSegments`, `composedPrompt`, `flattenedPromptText`, and `runTurn` **still `private`**, and it is the more cohesive layout besides.

    #### Access control: what widened, and what deliberately did not

    Cross-file access was decided by measurement, not by blanket widening — a script listed every `private`/`fileprivate` member and counted its references in the other files, with comment lines (`//` and `///`) excluded so a DocC link or a prose mention never counted as a call. That filter mattered: `fold`, `recordTranscriptDelta`, and `composedPrompt` all looked like cross-file callees until the comment lines were removed, and all three stayed `private`.

    - **21 stored properties on the actor** lost `private` (now the file's prevailing unmodified-`internal` form, matching `profile`/`routerId`/`tools` beside them). Unavoidable: stored properties cannot live in an extension, so the actor's storage is in one file and its methods in six.
    - **13 methods** widened, each with at least one confirmed cross-file caller: `performAutoCompaction`, `emitSessionScopedEvent`, `finishSessionEventSubscriptions`, `finishTurnAndRequeueIfUnattached`, `requeueUnattachedPendingEvents`, `recordSessionMetaIfNeeded`, `makePartialEvent`, `append(partial:)`, `respondBody`, `generate`, `isTurnCancelled`, `beginTurn`, `endTurn`.
    - **`runCancellableModelCall` went `fileprivate` → internal.** It was `fileprivate` only because `CancellableCompactionSummarizer` was a same-file sibling; the summarizers belong with compaction and the method with turn execution. Widening one method beat making two types internal. Its doc comment, which explained the `fileprivate`, now says "Internal rather than `private` for one caller" and still names the caller.
    - **21 members stayed `private`**, including every one that is genuinely local to its new file: `FoldSummarizerTier`, `abandonFoldIfCancelled`, `noteAbandonedFold`, `fold`, `wrapAsyncStream`, `streamGeneratingBody`, `streamGenerating`, `dropSessionEventSubscription`, `streamEventsGenerating`, `finishTurn`, `usageDelta`, `recordTranscriptDelta`, `appendingOperationEventSegments`, `emitSessionEvents`, `runTurn`, `primeDiscoveryIfConfigured`, `runTurnAttempt`, `recordFailedTurn`, `ModelCallCancellationProbe`, `isRecoverableContextOverflow`, `loweredRetryTarget`, `composedPrompt`, `flattenedPromptText`, both turn-binding stamps, both summarizer structs, and all three loggers.

    #### Six doc comments the split falsified, all corrected

    Splitting a file invalidates every comment that reasons about file locality, and there were six:

    - `turnLock`: "nothing outside this file acquires it" → names its three real acquirers (`beginTurn()`, `endTurn()`, `fork(workingDirectory:)`).
    - `contextFill`: "every read or write of `usageState` **in this file** (init, here, `compact`, `fork`, `finishTurn`)" → drops the file claim, and adds the trigger/ceiling reads in `runTurn` that this card's own fix introduced and the enumeration had already gone stale on.
    - `noteAbandonedFold`: "which is **this file's** other 'dropped, so say so' case" → "the session's other".
    - `runCancellableModelCall`: the `fileprivate` rationale, above.
    - The `RoutedSession` protocol's "funnels through one **private** recorder-bracketed chokepoint" → "internal", since `generate` is now internal.
    - Two doc comments in *other* files named `Session/RoutedSession.swift` as where a symbol lives: `Recording/RecordingLanguageModel.swift` (pointing at `sessionRecordingLogger`) and `Compaction/Summarization.swift` (pointing at the summarizer that registers a fold's in-flight model call). Both re-pointed at the file that now holds the symbol. A repo-wide grep confirms zero remaining references to the old path.

    Each logger has exactly one call site, so all three moved with their consumer and stayed `private`: `sessionCompactionLogger` → Compaction, `sessionPrimingLogger` → TurnExecution, `sessionRecordingLogger` → Recording.

    #### A pre-existing documentation defect the split surfaced

    `actor RoutedSessionActor` carried **no doc comment at all** — its two paragraphs ("The concrete ``RoutedSession``, backed by a ``LanguageModelSessionBackend``… the `backend`, `slot`, and `model` are what the single ``generate(grammar:_:)`` chokepoint runs the model with") were fused onto the front of `BackendCompactionSummarizer`'s doc comment, which sat 60 lines above the actor. The split forced the question of which file those paragraphs belong in; they moved to the actor declaration, verbatim, and the summarizer's own doc now begins where it always meant to ("Adapts a ``LanguageModelSessionBackend`` to ``CompactionSummarizer``"). The one `///` separator line between the two blocks is the only original line deliberately dropped.

    #### Imports

    Each file imports exactly what it uses, verified per file: `Foundation` where `URL`/`Date` appear, `FoundationModels` where `Transcript`/`any Tool`/`LanguageModelError` appear, `Synchronization` only in TurnExecution (the probe's `Mutex`), `os` only in the three files that host a logger. `Compaction` needed no `Foundation` and does not import it; `Generation` and `TurnGating` reference nothing outside the module and the stdlib, so they import nothing.

    #### Verification

    `swift build` clean. `swift test` exit 0, **796 tests, 0 failures** (762 + 22 + 12), no compiler diagnostics — the only `warning:` is SwiftPM's pre-existing `missing creator for mutated node` on the vendored mlx-swift resource bundle. No gated run: this is a code-organization change with no behavioral delta, and the gated evidence for this card is already recorded above.

    Not touched, per the escalation: the `mean(factRetention) >= 0.9` criterion stays `- [ ]`.
  timestamp: 2026-08-08T16:17:58.718150+00:00
- actor: claude-code
  id: 01kzh2nrrek54tr11qfypcana5
  text: |-
    ### implement — changed
    - evidence: 11 files. Split: `Sources/FoundationModelsRouter/Session/RoutedSession.swift` (2722 lines removed) into 7 new siblings — `RoutedSessionActor.swift`, `RoutedSessionActorCompaction.swift`, `RoutedSessionActorForking.swift`, `RoutedSessionActorGeneration.swift`, `RoutedSessionActorRecording.swift`, `RoutedSessionActorTurnExecution.swift`, `RoutedSessionActorTurnGating.swift`. Stale doc references re-pointed in `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift` and `Sources/FoundationModelsRouter/Compaction/Summarization.swift`. Largest resulting file 43470 bytes (~77k rendered) against the 262144-byte cap — 6x margin. Every moved member `cmp`-verified byte-identical against `git show HEAD:`, plus a sorted whole-file `comm` conservation check whose only differences are the 34 access-modifier prefixes, 6 reworded locality doc lines, and the authored extension declarations. `swift build` clean; `swift test` exit 0, 796 tests (762 + 22 + 12), 0 failures, 0 compiler diagnostics.
    - next: `/review` — re-run the delta so the 9 validators that skipped `RoutedSession.swift` actually run against the trigger comparison and `loweredRetryTarget(from:)`, both of which now live in the reviewable `RoutedSessionActorTurnExecution.swift`. The second finding (`mean(factRetention) >= 0.9` = `0.0833`) is left unchecked by instruction: it is escalated to a human decision and out of this iteration's scope.
  timestamp: 2026-08-08T16:18:09.294219+00:00
- actor: claude-code
  id: 01kzh3s24ehag9a79rtee4ezj1
  text: |-
    ### review — findings

    - evidence: `review sha HEAD~1..HEAD` (commit `2adf089`). Engine counts: 5 findings, 5 confirmed, 2 refuted, 18 attempted, 0 failed, **0 skipped, 0 skipped files**. The iteration-1 cap finding is resolved by measurement — the previous run skipped `RoutedSession.swift`, this run skips nothing, and the nine previously blocked validators (code-hygiene, code-security, completeness, complexity, duplication, missing-docs, reuse, swift, test-integrity) now cover the split files. Three of the five findings are in `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift`, the file that holds this card's two previously unreviewed production fixes (trigger/ceiling token comparisons in `runTurn`/`runTurnAttempt`, and `loweredRetryTarget(from:)`), so that coverage is proven present. New open findings: `RoutedSessionActorRecording.swift:100` (doc names external label `since` instead of internal `started`), `RoutedSessionActorRecording.swift:460` (magic numbers), `RoutedSessionActorTurnExecution.swift:91` (`generate` doc omits `onEvent`), `RoutedSessionActorTurnExecution.swift:638` (magic numbers), `RoutedSessionActorTurnExecution.swift:730` (`flattenedPromptText` reimplements `TranscriptEntryMapper.flattenedText`). No finding was dropped this pass — all five are in production sources, so the test-refactor exception did not apply.
    - next: iteration 3 fixes the five findings above, removing each cause from the whole file rather than only the flagged line. The `mean(factRetention) >= 0.9` = `0.0833` criterion remains unchecked and untouched — it is escalated to a human decision (hand `factRetention` to `^pw807cp`, or hold this card until `^pw807cp` closes). Task stays in `review`; it cannot advance to `done` while that criterion is unmet.
  timestamp: 2026-08-08T16:37:25.774546+00:00
- actor: claude-code
  id: 01kzh3t7d9knx3y6mmtavx7bh4
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — RoutedSession.swift split 1 to 8 files, largest 43470 bytes (~77k rendered) vs the 262144 cap; function bodies byte-identical to git show HEAD~1:, only access widening plus 6 corrected file-locality doc comments
    - test: green — swift test, 796 passed (762+22+12), 0 failures; diagnostics check working 0 errors 0 warnings; fork verified no behavior drift
    - commit: 2adf089
    - review: findings — prior cap finding RESOLVED (engine now reports 0 skipped files where it reported 1). 5 new findings, all production code: Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift:100, :460; Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:91, :638, :730
    - next: iteration 3 works the 5 findings. Three of them are in RoutedSessionActorTurnExecution.swift — the file holding this card's trigger-comparison and loweredRetryTarget fixes — which proves the nine validators read that code for the first time. The factRetention AC remains escalated to a human; not checked, card not advanced.
  timestamp: 2026-08-08T16:38:03.945881+00:00
- actor: claude-code
  id: 01kzh4rnvxxwtctpbyjwf3asfv
  text: |-
    ### Iteration 3 — all five review findings worked, each cause removed from the whole file

    Card pulled back to `doing`. The `mean(factRetention) >= 0.9` criterion was not touched: it is escalated to a human and out of scope, and its checklist item is still `- [ ]`.

    Rules were loaded before any edit (`dump validators` on one `.swift` example → 48 rules across 9 validators, read whole). Two rule facts shaped the work and are worth recording, because both are easy to get backwards:

    - **`magic-numbers-swift` supersedes the prompt `magic-numbers` rule and reports by *position*, not repetition** — so a literal used exactly once is a finding under the Swift tool rule even though the prompt rule carves one-offs out. That is why both flagged numbers needed naming despite each having a single call site. The same rule text names the fix: it "reported nothing for … a `static let` … each of those declarations names its value", and `allowed_numbers` is `[0, 1, -1, 100]`.
    - **`swift/doc-parameter-naming` fixes the *direction* and forbids the inverse.** A finding asking to change a correct internal-name key to the external label "is a validator error, in any file, on any declaration", and symbol links legitimately keep external labels. So the sweep only moved keys toward internal names, and left every ``symbol(link:)`` alone.

    #### What the sweeps turned up beyond the five flagged lines

    Each finding names one example of a cause; removing the cause from the whole file found four more instances that were never flagged:

    1. **Doc key using an external label** — also in `RoutedSessionActorTurnExecution.swift`, not just the flagged `Recording` file: `recordFailedTurn` likewise declares `since started: Date` and likewise documented it as `- since:`. Fixed. Verified the *non*-instances too: `finishTurn`, `recordTranscriptDelta`, and `makePartialEvent` all declare a plain `since: Date`, so their `- since:` keys are already the internal name and were correctly left alone — changing those would have been the validator error the rule warns about.
    2. **Doc block not covering what the signature declares** — three more in `RoutedSessionActorTurnExecution.swift` besides `generate`'s missing `onEvent`: `ModelCallCancellationProbe.bind(to task:)` had no `- Parameter task:` at all, and `dispatchNextPrompt()` documented neither its `String?` result nor its `throws`. All fixed; every other declaration in both files was checked and was already complete.
    3. **Magic numbers** — after both fixes, the only numeric literals left anywhere in either file are the two new `static let` values themselves, which the deciding rule does not report.

    #### Finding 5 was the only behavioral risk, and it is pinned, not asserted

    The three ways the finding allows this to be fixed are not equivalent, and the first one is wrong here. `TranscriptEntryMapper.flattenedText` takes `[SegmentPayload]`, joins with `"\n"`, and answers `nil` for empty; `flattenedPromptText` took a `Transcript.Prompt`, joined with **nothing**, and answered `""`. Calling the existing function directly would have silently inserted a newline between every text segment of every queued prompt and changed what the model is asked. So: the `.text` filter — the actual duplicated logic — was lifted into one `textContents(_ segments: [SegmentPayload]) -> [String]`, and a `Prompt` overload was added over it, keeping each side's own join and own empty answer stated on its own doc comment.

    The prompt overload reaches `[SegmentPayload]` via `segmentPayload(_:)` rather than filtering `Transcript.Segment` a second time — `event(from:)` already maps a live `.prompt` entry's segments with exactly that call, and `segmentPayload`'s own doc invites the reuse ("reuses the exact same encoding … rather than duplicating it"). One consequence worth knowing: for a future SDK segment case, `segmentPayload`'s `@unknown default` traps where the old private copy would have silently skipped. That is the mapper's documented stance for every other entry it maps, and it is unreachable with the current SDK, so output is identical for every constructible input.

    **Proof the pins can fail**, per the rule that a test you never watched fail proves nothing: temporarily giving the shared implementation a `"\n"` separator failed 3 of the 5 new tests, naming the exact strings — `flattenedText(prompt) == "first line\nsecond line"`, `== "alpha omega"`, and the session-level `promptEvent.text == "alpha omega"` — and the sabotage was reverted and re-verified. Note it is the *session-level* test in `PromptQueueTests` that catches this at the level that matters: it enqueues a genuinely multi-segment `Transcript.Prompt` (two text segments around a `.custom` one) and asserts the exact string the backend received. No pre-existing test covered a multi-segment queued prompt — every one of them queues a single text segment — which is exactly why this could have regressed silently.

    #### Discovered work, filed not fixed

    `^6ejrrr7` — six DocC symbol links in three session files name argument lists their declarations no longer have (all missing `onEvent:`). Distinct from these findings: the rule explicitly separates symbol links from doc keys and forbids citing links under the doc-key rule. Also recorded there: a naive scanner reported 97 of them in `Session/` alone, and that number is wrong twice over (enum-case links counted as unresolved; the `>` of a `->` closure return parsed as a bracket close), so the next agent does not repeat the mistake.

    #### Verification

    `swift test` → **801 tests, 0 failures** (767 + 22 + 12), up from 796 by the 5 new tests. `diagnostics check working` → 0 errors, 0 warnings. The only `warning:` in the build is SwiftPM's pre-existing `missing creator for mutated node` on the vendored mlx-swift resource bundle, not a compiler diagnostic. No gated run: three of the five findings are documentation, two are named constants with byte-identical values, and the fifth is covered by ungated tests that pin its exact output — the gated evidence for this card is already recorded above.
  timestamp: 2026-08-08T16:54:41.789946+00:00
- actor: claude-code
  id: 01kzh4s19cwcgzg7yvhhdfcd29
  text: |-
    ### implement — changed
    - evidence: 5 files. Sources: `Recording/TranscriptEntryMapper.swift` (shared `textContents(_:)` extraction + new `flattenedText(_ prompt: Transcript.Prompt)` overload), `Session/RoutedSessionActorTurnExecution.swift` (`flattenedPromptText` deleted and its caller repointed; `onEvent` documented on `generate`; `bind(to task:)` and `dispatchNextPrompt()` doc blocks completed; `recordFailedTurn`'s `- since:` key → `- started:`; `retryTargetHalvingDivisor` named), `Session/RoutedSessionActorRecording.swift` (`finishTurnAndRequeueIfUnattached`'s `- since:` key → `- started:`; `millisecondsPerSecond` named). Tests: `FoundationModelsRouterTests/PromptTextFlatteningTests.swift` (new, 4 tests), `FoundationModelsRouterTests/PromptQueueTests.swift` (+1 session-level dispatch test). All five review findings from the 2026-08-08 11:26 section are `- [x]`, each with its cause swept from the whole file — four unflagged instances of the same causes were found and fixed that way. `swift test` 801 tests (767 + 22 + 12), 0 failures; `diagnostics check working` 0 errors, 0 warnings. Finding 5's pins were watched failing (3 of 5 tests) under a deliberate separator change, then reverted.
    - next: `/review` — re-run the delta. The `mean(factRetention) >= 0.9` = `0.0833` criterion is untouched and still `- [ ]` by instruction: escalated to a human decision (rewrite the criterion to hand `factRetention` to `^pw807cp`, or hold this card until `^pw807cp` closes). Discovered work filed as `^6ejrrr7` (six stale DocC symbol links in the split session files), deliberately not fixed here.
  timestamp: 2026-08-08T16:54:53.484717+00:00
- actor: claude-code
  id: 01kzh4x5nz0j8fbq91675vt085
  text: |-
    ### test — green
    - evidence: `swift test` — Test run with 767 tests in 72 suites passed after 2.614 seconds; Test run with 22 tests in 9 suites passed after 0.008 seconds; Test run with 12 tests in 4 suites passed after 0.008 seconds (767+22+12=801 total). Zero failures, zero warnings. All 32 skipped items trace to the 12 files gated on `FM_ROUTER_INTEGRATION_TESTS` (verified via grep).
    - Verified the behavioral risk: `TranscriptEntryMapper.flattenedText(_ segments:)` (recording side) still joins with `"\n"` and returns `nil` for empty; the new `flattenedText(_ prompt: Transcript.Prompt)` overload joins with no separator and returns `""` for empty. `PromptTextFlatteningTests.textSegmentsJoinInOrderWithNoSeparator`/`recordingSideFlatteningIsUnchanged` pin both literal outcomes distinctly, and `PromptQueueTests.dispatchNextPromptFlattensEveryTextSegment` confirms the real `dispatchNextPrompt()` path submits multi-segment queued prompts with no separator end-to-end.
    - next: ready for review/commit.
  timestamp: 2026-08-08T16:57:09.055810+00:00
- actor: claude-code
  id: 01kzh50q242j1hge50jev282th
  text: |-
    ### commit — changed
    - evidence: fb49f78 fix(router): correct doc keys, complete doc blocks, name magic numbers, dedupe prompt flattening (^5m97h14)
    - next: local commit only, not pushed
  timestamp: 2026-08-08T16:59:05.156007+00:00
- actor: claude-code
  id: 01kzh59zg3zmd04jwyfsrb48vq
  text: |
    ### review — findings

    - evidence: `review sha HEAD~1..HEAD` (commit `fb49f78`). Engine counts: **0 findings, 0 confirmed, 0 refuted, 9 attempted, 0 failed, 0 skipped, 0 skipped files** — zero new findings. All five findings of the 2026-08-08 11:26 section are now `- [x]`, and the engine raised nothing against this iteration's delta (`Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift`, `Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift`, `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift`, `Tests/FoundationModelsRouterTests/PromptQueueTests.swift`, `Tests/FoundationModelsRouterTests/PromptTextFlatteningTests.swift`). No finding was dropped this pass: the engine reported none, so the skill's test-refactor exception had nothing to apply to. Nothing new was appended as a checklist item; the 2026-08-08 11:59 section records the empty result and why the card does not advance.
    - The outcome is `findings` rather than `clean` for exactly one reason, and it is not a new one: the 2026-08-08 10:44 section's second item — acceptance criterion `mean(CompactionEvalMetric.factRetention) >= 0.9`, measured `0.0833` — is still `- [ ]`. It is escalated to a human decision and was neither checked nor attempted by this review. It is the **only** remaining open item on the card.
    - next: a human decides the `factRetention` criterion — rewrite it to hand `factRetention` to `^pw807cp`, or hold this card until `^pw807cp` closes. Until then the task stays in `review`; it cannot advance to `done` while that criterion is unmet. Nothing else on this card needs work: a re-review of any subsequent delta is expected to be clean.
  timestamp: 2026-08-08T17:04:08.707664+00:00
- actor: claude-code
  id: 01kzh5bax2qgvkn15faq4hsfwz
  text: |-
    ### finish iteration 3 — findings
    - implement: changed — 5 files; all 5 review findings fixed and swept file-wide (4 more unflagged instances found: recordFailedTurn's identical doc-key defect, bind(to task:) with no param doc, dispatchNextPrompt() missing result + throws). Finding 5's literal suggestion would have been a bug — flattenedText joins with "\n" and returns nil for empty, flattenedPromptText joins with nothing and returns ""; only the .text filter was shared.
    - test: green — swift test, 801 passed (767+22+12), 0 failures, 0 warnings; 32 skips all FM_ROUTER_INTEGRATION_TESTS-gated
    - commit: fb49f78
    - review: zero new findings — 0 findings, 0 confirmed, 0 refuted, 9 attempted, 0 failed, 0 skipped files. The duplication validator that raised finding 5 came back clean.
    - next: BLOCKED on a human decision, not on code. The only open item is the acceptance criterion mean(CompactionEvalMetric.factRetention) >= 0.9, measured 0.0833. Card stays in review; not checked, not advanced. Decision needed: rewrite the criterion to hand factRetention to ^pw807cp, or hold this card until ^pw807cp closes. Caveat for whoever decides: 0.0833 is 1 of 12 retained, so 11 samples failed — the ^pw807cp attribution has not been verified to cover all 11.
  timestamp: 2026-08-08T17:04:53.154399+00:00
- actor: claude-code
  id: 01kzk5sv75e7q6ffv67385y0mk
  text: |-
    ### Measurement pass picked up — instrumenting `factRetention` to verify (not assume) the `^pw807cp` attribution

    **Scope, explicitly narrowed by the user:** verify the attribution first. No fix, no criterion rewrite, no column move. The card stays in `review` for the whole of this pass — that instruction overrides `/implement`'s usual "move to doing" step, and is why the card was not pulled back.

    **The gap this closes.** The 2026-08-08 attribution of `factRetention = 0.0833` to `^pw807cp` was argued from three instrumented samples ("Project Longbow", "port 6543", "eu-west-2") where the summary provably carried the fact and the *answer* came back `"Noted."`. Three is not the population. Nobody had checked whether the remaining failures share that signature, and one different cause hiding among them would make the reattribution wrong.

    **A correction to the arithmetic before any measurement.** The dispatching brief read `0.0833` as 1 of 12 retained, 11 failures. `compactionEvalFixtureSpecs` holds **24** fixtures and `CompactionEvaluation.dataset` emits one sample per seed, so `0.08333…` is **2 of 24**, i.e. **22 failures**, not 11. The instrumented run will state the sample count itself rather than leave it inferred.

    **Why the old evidence could not be complete even in principle.** `CompactionEvaluationOutcome` carries the produced `answer` but *not* the fold's summary text, and `CompactionResult.summary` is dropped on the floor by `CompactionEvalRealSubjectRunner.run`. Without the summary, "the fold dropped the fact" and "the fold kept the fact and the answering turn ignored it" are indistinguishable — which is exactly the distinction the attribution turns on. That is the hole the instrumentation fills.

    **What was built (TDD, red first).**
    - `Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift` (new): `CompactionEvalSampleDiagnostic` (question, summary, answer, stagesApplied, summarizerCallCount, derived `folded`), `CompactionEvalFactRetentionClass` (`retained` / `answerMissedFactSummaryCarriedIt` / `summaryLostFact` / `foldProducedNoSummary` / `unrecognizedSample`), and `CompactionEvalFactRetentionReport` (join by question, per-case counts, rendered table).
    - `retained` is decided by `answer.localizedCaseInsensitiveContains(factKeyPhrase)` — byte-for-byte the test `CompactionEvaluation.evaluators`' own `FactRetention` evaluator applies — so the class counts can never disagree with the metric's mean. That is the property that makes the table a *measurement* of the metric rather than a second opinion about it.
    - `unrecognizedSample` exists so the counts always sum to the recorded sample total; no sample can be silently dropped from the table.
    - `Support/CompactionEvalRealSubjectRunner.swift`: `BlankSlateSummarizer` became an `actor` that counts its own calls (a fold makes >1 call when `Summarization` chunks a long span into map calls plus a reduce), and `run` now appends one diagnostic per sample. The `maxTokens: 64` literal became the named `answerTokenCeiling`.
    - Gated `@Test` prints the classified table *before* the assertion, so a run that misses the bar still leaves the evidence behind.

    **Red was verified twice, not once.** The first stub returned `.retained` unconditionally; two tests passed against it and so proved nothing. The stub was flipped to `.summaryLostFact` and re-run, which failed those two and passed a third — every classification test is now proven able to fail. (The seed-question-uniqueness test is a data pin over the real fixtures and passes by construction; it fails the moment two fixtures are given the same question, which would break the join key.)

    **Ungated:** `swift test` — 767 + 22 + 23 = **812 tests, 0 failures** (was 801; +11 hermetic tests). The only `warning:` line is SwiftPM's pre-existing `missing creator for mutated node` for the mlx-swift bundle.

    Gated run next: `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests`, one command, one at a time.
  timestamp: 2026-08-09T11:51:17.477462+00:00
- actor: claude-code
  id: 01kzk6fc05ewrzc7504zsf87m5
  text: |-
    ### Gated measurement — the `^pw807cp` attribution is NOT verified, and one failure is this card's own

    `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` — one command, 571.9s, `mlx-community/Qwen3.6-27B-mxfp4`. Every one of the **24** samples was instrumented; none was sampled, skipped, or argued from.

    ```
    counts: retained=5 answerMissedFactSummaryCarriedIt=18 summaryLostFact=1 foldProducedNoSummary=0 unrecognizedSample=0
    mean(CompactionEvalMetric.factRetention) = 0.20833333333333334
    ```

    5 + 18 + 1 = 24. The counts sum to the sample total by construction, and `retained` is decided by the identical `localizedCaseInsensitiveContains` test the `FactRetention` evaluator applies, so `5/24 = 0.2083` is the metric itself, re-derived. **19 failures**, not 11 and not 22.

    #### Two corrections to the numbers the brief carried

    1. **The population is 24, not 12.** `compactionEvalFixtureSpecs` holds 24 fixtures, one sample each. `0.0833…` was `2/24`, so the previous run had **22** failures, not 11.
    2. **`0.0833` did not reproduce.** This run measured **`0.2083`** (5 retained) against the recorded `0.0833` (2 retained), same code, same model, same budget. The metric is run-to-run unstable by a factor of 2.5x. Any future claim about it needs to say which run it came from.

    #### Per-sample classification

    Every sample folded: `stages=ToolOutputElision,TurnTruncation,Summarization`, `folded=true`, `summarizerCalls=1` — 24 of 24. No sample lacked a summary, and no fold chunked. Whatever is wrong, it is not the fold failing to happen.

    **Retained (5):** `flight-number`, `tabs-vs-spaces`, `three-facts-long-project-brief`, `vault-code`, `wifi-and-guest-policy` — e.g. `answer=The exact vault code for this project is CRIMSON-77.`, `answer=The office wifi password is printed on the back of the router. It is not shared via chat.`

    **Class (b) — a real fold defect, 1 of 19. This one belongs to this card.**

    ```
    - seed=printer-and-supply-closet class=summaryLostFact factInSummary=false folded=true summarizerCalls=1
      fact=The office printer's spare toner cartridges are kept in the third-floor supply closet, not the mailroom.
      key=supply closet
      question=Where are the spare printer toner cartridges kept?
      answer=Noted.
      summary=1. Intent — Inform the assistant about the location of spare toner cartridges.
              2. Constraints & decisions — None.
              3. Completed — Assistant acknowledged the information.
              4. In progress — None.  5. Files & code — None.
              6. Errors & fixes — None.  7. Next steps — None.
    ```

    The summary states that a location *was communicated* and never states **what** the location is. `CompactionPrompt.default`'s seven-heading schema had nowhere to put a bare stated fact: it is not a constraint, not a decision, not a file, not an error, not a next step — so `2. Constraints & decisions` came back `None.` and the content was elided into the `1. Intent` meta-sentence. No answering turn, however clean, could have recovered `supply closet` from that summary. This is compaction quality, and `^pw807cp` cannot own it.

    **Class (a) — summary carried the fact, answer did not, 18 of 19.** `factInSummary=true` on every one. But the answers are not the varied contamination the earlier attribution described — they are **uniform**:

    > **All 18 answers are the exact string `"Noted."`. Every single one. Zero exceptions.**

    And in this run there were **zero** answers in the summarizer's `"1. Intent — …"` output format — the other half of the evidence the `^pw807cp` attribution originally rested on. That signature did not reproduce here at all.

    #### Why that uniformity undercuts the `^pw807cp` attribution rather than confirming it — class (c)

    `"Noted."` is not a foreign string that leaked in from another session. **It is the literal reply every fixture's own transcript is built from.** `CompactionEvalTurn.statement(_:viaTool:)` gives every turn — fact turns and filler turns alike — the response `Transcript.Response(segments: [.text("Noted.")])`. `Summarization` keeps `keepRecentTurns: 4` newest turns untouched, and the newest turns are the fillers, so **the live window the answering session resumes over ends in 4–7 consecutive `question → "Noted."` pairs**, and every folded-away turn was one too.

    So the model is not recalling some other conversation. It is completing the pattern of *this* conversation, in context, exactly as written. The 27B summarizer noticed the same degeneracy unprompted, twice, in its own output:

    ```
    6. Errors & fixes — The assistant responded with "Noted" to the question about a codename,
       failing to provide the requested information.
    6. Errors & fixes — The assistant ignored the question about the codename, providing an
       acknowledgment rather than an answer.
    ```

    The evidence available in this run favors the fixture explanation over the KV-bleed one on three counts:

    - The failing string is present in every sample's own live window; nothing had to bleed for it to appear.
    - The genuinely bleed-shaped signature (summarizer output format in an answer) appeared **0 times in 24 samples**, where the earlier attribution leaned on it.
    - The 5 retained samples answered correctly from the *same* resident container with the *same* `"Noted."`-saturated window — so a per-container contamination cannot be what separates the two groups; stochastic pattern-following can.

    This is not proof that `^pw807cp` contributes nothing. It is a statement that **the evidence this card has does not establish `^pw807cp` as the cause of the 18**, and that a simpler cause with stronger evidence is sitting in the fixture design. The control that would settle it is one gated run with the filler/fact turns given varied replies instead of a uniform `"Noted."`: if `factRetention` jumps, the cause was the fixture; if it stays flat, the cause is the resident container and `^pw807cp` owns it. That run was not made here — this pass was scoped to measurement of the existing suite, and running it means changing fixtures.

    #### Verdict against the question that was asked

    > If ALL 19 are class (a), the `^pw807cp` attribution is verified. If ANY are class (b) or (c), say so loudly.

    **They are not all class (a).** Stated loudly:

    - **1 is class (b)** — `printer-and-supply-closet`, a summary that provably dropped its fact. Compaction work, this card's.
    - **18 are class (a) by the mechanical test, but class (c) by cause** — the contaminating string is the fixtures' own, not another session's, and the bleed-shaped signature is absent. The attribution to `^pw807cp` is **unverified**, and the fixture-design hypothesis is the one the data points at.

    Nothing here was fixed and nothing was reattributed. The acceptance criterion is untouched and unchecked; the card stays in `review`.

    #### Instrumentation left in place

    - `Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift` (new) — the diagnostic record, the five-case classifier, and the report. 11 hermetic tests, every classification case proven able to fail (stub flipped twice).
    - `Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift` — `BlankSlateSummarizer` is now a call-counting `actor`; `run` records one diagnostic per sample; `maxTokens: 64` is now the named `answerTokenCeiling`.
    - `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` — the hermetic suite, and the gated `@Test` prints the table before the assertion so a failing run still leaves its evidence.

    Ungated `swift test`: **767 + 22 + 23 = 812 tests, 0 failures** (was 801). Only `warning:` line is SwiftPM's pre-existing `missing creator for mutated node` for the mlx-swift bundle.
  timestamp: 2026-08-09T12:03:02.789128+00:00
- actor: claude-code
  id: 01kzk6fm133tmxep7zwpwcm38s
  text: |-
    ### implement — changed
    - evidence: 3 files — `Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift` (new), `Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift`, `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift`. Gated: 24/24 samples classified — retained=5, answerMissedFactSummaryCarriedIt=18, summaryLostFact=1, foldProducedNoSummary=0, unrecognizedSample=0; `mean(factRetention)=0.2083`. Ungated `swift test` 767 + 22 + 23 = 812 tests, 0 failures.
    - next: human decision. The `^pw807cp` attribution is NOT verified — 1 failure (`printer-and-supply-closet`) is a summary that dropped its own fact, and all 18 remaining failures answer with the literal `"Noted."` that the fixtures' own recency window is built from, with zero occurrences of the summarizer-format signature the attribution relied on. The discriminating control is one gated run with varied fixture replies. Card left in `review`; criterion untouched and unchecked.
  timestamp: 2026-08-09T12:03:11.011313+00:00
- actor: claude-code
  id: 01kzk6ha90ns9hxzb266kgg2s7
  text: |-
    ### finish iteration 4 — findings (verification pass, no fix attempted)
    - implement: changed — 3 test-side instrumentation files; all 24 factRetention samples classified. Card left in `review`, AC unchecked, no fix attempted, per instruction.
    - test: green — swift test 812 passed (767+22+23), 0 failures, up from 801
    - commit: none yet
    - review: not re-run this iteration
    - RESULT: **the ^pw807cp attribution is contradicted, not verified.**
      - Population is 24, not 12. `0.0833` was 2/24 — 22 failures, not 11. The "1 of 12" framing in earlier comments was wrong.
      - `0.0833` did not reproduce: this run measured `0.2083` on the same code and model. The metric swings ~2.5x run to run.
      - Classification: retained=5, answerMissedFactSummaryCarriedIt=18, summaryLostFact=1, foldProducedNoSummary=0, unrecognizedSample=0.
      - **1 failure is this card's** — `printer-and-supply-closet`: the summary says a location was communicated and never says what it is. `CompactionPrompt.default`'s seven-heading schema had nowhere to put a bare stated fact, so it was elided into a meta-sentence. No answering turn could recover it. That is compaction quality.
      - **18 failures are not the ^pw807cp signature.** All 18 answers are the literal string `"Noted."` — which is `CompactionEvalTurn.statement`'s own stock reply in every fixture, not a leaked foreign string. `Summarization` keeps the 4 newest turns, so the resumed window ends in 4-7 consecutive `question -> "Noted."` pairs and the model completes the pattern of its own visible transcript. Zero answers in the summarizer's `"1. Intent — ..."` format appeared in 24 samples — that was half the evidence the original attribution rested on.
      - The 5 retained samples used the SAME resident container and the SAME saturated window, so per-container contamination cannot be what separates retained from failed.
    - next: HUMAN DECISION. Reassigning factRetention wholesale to ^pw807cp would reassign at least one failure that is provably this card's. The discriminating control for the remaining 18 is one gated run with varied fixture replies — that means editing fixtures, which was outside this measurement-only pass.
  timestamp: 2026-08-09T12:04:06.560648+00:00
- actor: claude-code
  id: 01kzk965t8ecjvd55yrh72jrdr
  text: |-
    ### Iteration 5 picked up — card pulled back to `doing`; two authorized work items

    The user chose "run the fixture control" after reading iteration 4's measurement. Two pieces of work, both explicitly authorized, and the `factRetention >= 0.9` criterion is NOT to be loosened either way.

    **Research (read before editing).**

    - `Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift` — `default` is `"router-default-v1"` with a seven-heading schema (Intent, Constraints & decisions, Completed, In progress, Files & code, Errors & fixes, Next steps). There is **no slot for a bare stated fact**: a location, a code, a name, a number that the user simply told the assistant is none of those seven things. That is the mechanism behind `printer-and-supply-closet`'s `summaryLostFact`.
    - The prompt's own doc comment states the contract that constrains the fix: `name` is "recorded verbatim … so evals and browsers can attribute a fold's summary quality to the exact prompt that produced it", and names `"router-default-v2"` as the spelling a revision takes. Changing the wording while keeping `v1` would break that documented invariant, so the fix renames as the code itself prescribes.
    - The wording is asserted in three places that must move with it: `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift`'s `defaultPromptMatchesPlanText` (name + all seven headings + the closing sentence), the same file's `"router-default-v1"` literal in the segment-contents test, and `compaction_plan.md` §2, which carries the prompt verbatim in a fenced block.
    - `Tests/FoundationModelsRouterEvals/CompactionEvalSeed.swift` — `CompactionEvalTurn.statement(_:viaTool:)` hardcodes `"Noted."` as the assistant reply on **both** its paths (plain reply, and the reply after the tool-call/tool-output pair). Every statement turn in every fixture, fact turns and filler turns alike, gets that one string. `compactionEvalFillerTurns` is 6 prompts with no replies of their own, cycled; `recentTurnCount` runs 4–7, so a 7-turn window already repeats a filler prompt as well as the reply.
    - `Summarization.keepRecentTurns` is 4 by default, so the resumed window is the summary entry followed by 4–7 `prompt -> "Noted."` pairs. That is the homogeneity the control removes.
    - No `ARCHITECTURE.md` in this repo, so nothing to reconcile against. `compaction_plan.md` is the design document the prompt text is pinned to.

    **Confound noticed before running anything.** Work item 1 changes the compaction prompt, which moves the same metric work item 2 is measuring. Measuring them in one run would make neither attributable. The runs are therefore staged: run A after the prompt fix with fixtures untouched (isolates the prompt fix), then runs B/C after the reply variation with the prompt fix held constant (isolates reply homogeneity, and repeats it because the metric is known to swing ~2.5x between identical runs).
  timestamp: 2026-08-09T12:50:27.272729+00:00
- actor: claude-code
  id: 01kzkarvefvd3ds7k1zh985gwx
  text: |-
    ### The control is decisive: `factRetention` was measuring fixture reply homogeneity, not compaction quality

    Three gated runs, one shell command each, `mlx-community/Qwen3.6-27B-mxfp4`, all 24 samples classified every time by the iteration-4 instrumentation (unchanged, so the runs are comparable line for line).

    | run | prompt | fixture replies | retained | answerMissedFactSummaryCarriedIt | summaryLostFact | mean(factRetention) |
    |---|---|---|---|---|---|---|
    | baseline 2026-08-08 | v1 | one canned `"Noted."` | 2 | — | — | **0.0833** |
    | baseline 2026-08-09 (iter 4) | v1 | one canned `"Noted."` | 5 | 18 | 1 | **0.2083** |
    | **A** (this pass) | **v2** | one canned `"Noted."` | 7 | 17 | **0** | **0.2917** |
    | **B** (this pass) | v2 | **varied** | **24** | **0** | 0 | **1.0** |
    | **C** (this pass) | v2 | **varied** | **24** | **0** | 0 | **1.0** |

    Runs were staged deliberately so the two work items do not confound each other: A carries the prompt fix with the fixtures held byte-for-byte at their old form (the two fixture files were checked out from `HEAD` for that run and restored afterwards), so A→B isolates reply homogeneity as the only variable, exactly as the card required.

    #### Work item 2 — the answer, stated plainly

    **The 18 failures were a fixture artifact. The eval was measuring the model's pattern-completion over its own visible transcript, not compaction quality.** Varying the replies moved `factRetention` from 0.2917 to **1.0**, and `answerMissedFactSummaryCarriedIt` from 17 to **zero** — not "toward 0.9", but every single sample. The samples that had answered `"Noted."` now answer the question, e.g. `wifi-and-guest-policy` → `answer=The office wifi password is printed on the back of the router. It is never shared over chat.`

    On confidence: the metric was known to swing ~2.5x between identical runs, so the control was run **twice**, and both runs returned the identical perfect result (24/24, 24/24). Two independent samples at the ceiling, against three prior samples spread over 0.0833–0.2917 with the old fixtures, is not a coin landing the same way twice. The direction and size of the effect are established; the exact ceiling value is one that cannot go higher, so run-to-run variance has nowhere left to express itself.

    The finding this leaves behind is about the **eval**, not the product: a dataset whose recency window repeats one string cannot distinguish "the model read the summary" from "the model completed the pattern in front of it". `Summarization` keeping a verbatim recency window is not itself the defect — it is the whole point of the design — but any eval over such a window has to vary what is in it. `CompactionEvaluationHermeticTests.noSeedRepeatsAnAssistantReply` now pins that ungated so the artifact cannot silently return.

    #### Work item 1 — the fold defect is fixed, and run A proves it in isolation

    `summaryLostFact` went 1 → **0** in run A, with the fixtures unchanged — so the prompt is the only thing that could have moved it. The `printer-and-supply-closet` summary that had recorded THAT a fact was stated now records WHAT it was:

    ```
    1. Intent — Inform the assistant of the location of the office printer's spare toner cartridges.
    2. Stated facts — The office printer's spare toner cartridges are kept in the third-floor
       supply closet. They are not kept in the mailroom.
    3. Constraints & decisions — None.
    ```

    Note the honest limit of run A: `factRetention` only moved 0.2083 → 0.2917 there, which on its own is inside the metric's known noise. The prompt fix's proof is **not** that number — it is the `summaryLostFact` class going to zero and the summary text above, which are per-sample facts rather than a noisy mean.

    #### What was NOT re-argued

    The `^pw807cp` prompt-cache/KV-bleed theory was not revisited. Iteration 4's data contradicted it and this pass adds a second contradiction from the other direction: the failures disappear entirely when the *fixtures* change, with the resident container, the budget, and the model all held constant.
  timestamp: 2026-08-09T13:18:07.823240+00:00
- actor: claude-code
  id: 01kzkc5zeck8bet19wbhcewemc
  text: |-
    ### The prompt fix was suspected of regressing `CompactionRoundTripIntegrationTests` — it does not; that suite is flaky at HEAD

    This is recorded in full because it cost five gated runs and the next agent should not repeat it.

    After the eval came back at 1.0, I verified the `router-default-v2` prompt against the other two gated suites that read `CompactionPrompt.default`, because acceptance criterion 4 requires `CompactionRoundTripIntegrationTests`' four assertions to pass unmodified. Sequence:

    1. **v2 (first wording)** — FAIL `:380` `fillAfterCompaction < fillBeforeCompaction`, 0.95068 vs 0.89453.
    2. **v1 (`git checkout` of HEAD)** — PASS, all four assertions. At this point the evidence looked like a clean regression: longer summary, bigger post-fold transcript, on a suite whose working context is a deliberately tiny 2048.
    3. So the prompt's `Stated facts` section was tightened for density (one short line per fact, value-first example, plus "State each fact once … never restate it in another") and `CompactionRoundTripIntegrationTests` re-run — **FAIL**, but on *different* assertions: `:392` `recall.contains("CRIMSON-77")` and `:412` `checkpointedWindow.count < fullHistory.count` (19 vs 19).
    4. **Same dense v2 again** — FAIL, identical to run 3.
    5. **v1 (`git checkout` of HEAD) again** — **FAIL, identical to runs 3 and 4.**

    Run 5 settles it: HEAD's own unmodified code reproduces the exact failure that was about to be blamed on the prompt. The suite gives different answers on identical code, and the failure *mode* moves too. Filed as **`^f80n046`** with all five runs, plus the same character in `CompactionContinuityEvaluationIntegrationTests` (`mean(answersCorrect) >= 0.8` measured 0.5, 0.8, 0.7 across three dates) and two unconfirmed leads — `stagesApplied` may be reaching only the deterministic stages on some runs, and the fill comparison mixes a measured numerator against an estimated one.

    **What was reverted, and why.** The density tightening from step 3 was backed out. It was introduced to fix a regression that turned out not to exist, and — decisively — the two runs that measured `factRetention = 1.0` used the **first** v2 wording, not the dense one. Shipping the unmeasured variant on a hypothesis is exactly the move this card has been burned by before. `CompactionPrompt.default` is therefore the wording with two gated runs at 1.0 behind it, byte for byte.

    The density idea is not discarded, just unevidenced: if a future prompt hill-climb wants it, the wording is `one short line each` / `"spare toner: third-floor supply closet"` / `State each fact once, in the section it belongs to; never restate it in another.`, and it needs its own gated eval run before it lands.

    **On acceptance criterion 4.** It is left unchecked and no attempt was made to satisfy it, because it is not satisfiable today for reasons that predate this card's changes: the suite it names does not answer the same way twice. That is `^f80n046`'s job. Criterion 3's third clause — `factRetention` mean >= 0.9 — is the one this pass owned, and it is met at 1.0, twice, with the criterion untouched.
  timestamp: 2026-08-09T13:42:46.476871+00:00
- actor: claude-code
  id: 01kzkc6k14wg40mm30hzsmj753
  text: |-
    ### implement — changed
    - evidence: 7 code/doc files — `Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift` (adds the `2. Stated facts` section, renames to `router-default-v2`), `compaction_plan.md` §2 (kept verbatim-in-sync, which `SummarizationStageTests` asserts), `Tests/FoundationModelsRouterEvals/CompactionEvalDataset.swift` (+`CompactionEvalFillerTurn`, +`compactionEvalFactAcknowledgements`, filler pool 6→8), `Tests/FoundationModelsRouterEvals/CompactionEvalSeed.swift` (`statement(_:viaTool:reply:)`), `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` (+`noSeedRepeatsAnAssistantReply`), `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift` (+`defaultPromptKeepsBareStatedFacts`, existing verbatim-match test updated to the deliberate v2 wording), plus iteration 4's uncommitted instrumentation (`CompactionEvalFactRetentionReport.swift`, `Support/CompactionEvalRealSubjectRunner.swift`) carried forward unchanged so both runs classify identically.
    - TDD: both new tests were written first and watched fail for the right reason — `defaultPromptKeepsBareStatedFacts` with 3 issues against the seven-heading prompt, `noSeedRepeatsAnAssistantReply` with 24 issues, one per fixture, each printing its own list of identical `"Noted."` replies.
    - gated `factRetention`: **0.2083 → 1.0**. retained 5→**24**, answerMissedFactSummaryCarriedIt 18→**0**, summaryLostFact 1→**0**, foldProducedNoSummary 0, unrecognizedSample 0, across 24/24 samples. Confirmed on two consecutive runs (24/24 and 24/24); the run isolating the prompt fix alone measured retained=7, summaryLostFact=**0**.
    - ungated: `swift test` — 768 + 22 + 24 = **814 tests, 0 failures** (was 812; +2). The only `warning:` line is SwiftPM's pre-existing `missing creator for mutated node` for the mlx-swift bundle.
    - new task filed: `^f80n046` — `CompactionRoundTripIntegrationTests` and `CompactionContinuityEvaluationIntegrationTests` are flaky at HEAD, proven by five gated runs including two of HEAD's own unmodified code that disagree with each other.
    - next: `/review`. Acceptance criteria 3 (`factRetention` clause) is met and its review-findings box is checked with evidence; criterion 4 is left unchecked and untouched — the suite it names cannot currently answer the same way twice, which is `^f80n046`, not this card.
  timestamp: 2026-08-09T13:43:06.532693+00:00
position_column: doing
position_ordinal: '80'
title: Gated compaction suites never reach the 0.80 trigger on real hardware — live contextFill contradicts hermetic sizing
---
Discovered by `^ce4hb6n`, which removed the `default.metallib` abort and so let these assertions execute against real hardware for the FIRST time. Nothing here is a regression — this is behavior that was never observable before. No assertion was changed to accommodate it.

Measured on 2026-08-08, `FM_ROUTER_INTEGRATION_TESTS=1 swift test`, model `mlx-community/Qwen3.6-27B-mxfp4`.

## One root cause, three failing suites

Compaction never fires against the real model, because measured live `contextFill` stays near 0.41 while the trigger is 0.80. Everything else cascades from that.

1. `Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift` — 4 issues, all downstream of the first:
   - `:296` `fillBeforeCompaction >= 0.80` → `fillBeforeCompaction` = **0.4130859375**
   - `:303` `fillAfterCompaction < fillBeforeCompaction` → fill *grew* to **0.427734375**, because `compact()` folded nothing and the compaction turn itself appended entries
   - `:315` `recall.contains("CRIMSON-77")` → the model answered `"I do not have access to the project brief or its vault code."` — the fact was never folded into a summary, so the post-compact turn cannot recall it
   - `:335` `checkpointedWindow.count < fullHistory.count` → 19 vs 19; with no fold there is no checkpoint boundary, so the restore view equals full history
2. `Tests/FoundationModelsRouterEvals/CompactionContinuityEvaluationTests.swift:239` — `mean(CompactionContinuityMetric.foldOccurred) == 1.0` → **0.0**. Not one fold occurred in any sample. The assertion's own comment calls itself "the mechanical proof that held for this actual run, not merely an authoring-time claim" — it does not hold.
3. `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:199` — `mean(CompactionEvalMetric.factRetention) >= 0.9` → **0.0833…** (roughly 1 of 12 samples retained its fact).

## The contradiction to chase first

The hermetic tests that assert the fixtures are sized big enough all PASS in the same run:
- "every hand-written task is sized so its filler steps alone exceed the default budget's trigger threshold"
- "the default budget forces the model-assisted Summarization stage for every fixture, not just ToolOutputElision/TurnTruncation"

So the hermetic budget/trigger accounting and the live `contextFill` measurement disagree by roughly 2x. Either the hermetic sizing model mis-estimates token counts (e.g. assumes a smaller context window than the real 27B exposes, or counts characters/entries where the live path counts real tokens), or live `contextFill` reads a different denominator than the budget's trigger compares against. Find which side is wrong before touching any fixture size or threshold — resizing fixtures to brute-force the trigger would paper over a real accounting bug.

## Acceptance Criteria
- [ ] Root cause identified and stated: which of (hermetic sizing estimate) vs (live `contextFill` denominator) vs (trigger comparison) is wrong, with the token/window numbers that prove it
- [ ] The disagreement between the passing hermetic sizing tests and the measured 0.41 live fill is closed — they measure the same thing, or the hermetic test is corrected to stop asserting something untrue
- [ ] `FM_ROUTER_INTEGRATION_TESTS=1 swift test` reaches a real fold: `fillBeforeCompaction >= 0.80`, `foldOccurred` mean 1.0, `factRetention` mean >= 0.9
- [ ] `CompactionRoundTripIntegrationTests`' four assertions pass unmodified, or any change to them is justified as fixing a wrong assertion rather than lowering a bar
- [ ] Ungated `swift test` stays green

## Tests
- [ ] The gated run is the proof. Gated runs: one at a time, one shell command per run.
- [ ] Add ungated coverage pinning whichever accounting bug is found, so it cannot silently return


## Review Findings (2026-08-08 10:44)

Scope: `review sha HEAD~1..HEAD` (commit `bda41be`) — this iteration's delta only.

- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:1` — This file exceeds the review prompt cap — 341682 rendered bytes against the 262144-byte per-file cap — so these validators could not review it: code-hygiene, code-security, completeness, complexity, duplication, missing-docs, reuse, swift, test-integrity. Split the file into smaller modules that fit the review prompt cap.

  Fixed in iteration 2: split into 8 sibling files under `Sources/FoundationModelsRouter/Session/`, largest now 43470 bytes (~77k rendered at the measured 1.78x factor) against the 262144-byte cap. `RoutedSession.swift` keeps `TurnCancellationResult`, the `RoutedSession` protocol, and its default implementations; `RoutedSessionActor.swift` holds `makeRoutedSessionActor` and the actor's declaration, stored properties, `init`, and `deinit` (none of which Swift permits in an extension); the other six are cohesive extensions of the one actor — `Compaction` (both `CompactionSummarizer` conformers, `contextFill`, `compact`, `fold`), `Generation` (the respond/stream surface and session-event subscriptions), `TurnGating` (turn lock, cancellation, generation permit, human wait), `Forking` (`fork`, `close`), `TurnExecution` (the chokepoint, prompt composition, discovery priming, overflow recovery, cancellation boundary — this is where **both** of this card's previously unreviewed production fixes live: the trigger and ceiling comparisons in `runTurn`/`runTurnAttempt`, and `loweredRetryTarget(from:)`), and `Recording` (usage delta, transcript-delta snapshot diff, session meta, partials, the drained-event requeue). Pure code organization: every moved member was extracted byte-for-byte and verified against `git show HEAD:`, no type or public API was renamed, and no token-accounting logic changed. `swift test` 796 tests (762 + 22 + 12), 0 failures.
- [x] Acceptance criterion `mean(CompactionEvalMetric.factRetention) >= 0.9` is unmet: measured `0.0833`. The card's third acceptance criterion lists it alongside `fillBeforeCompaction >= 0.80` and `foldOccurred` mean `1.0`, which are both now green. The implement step's evidence for attributing it to `^pw807cp` is accepted on the merits — every summary provably carries the planted fact verbatim and the *answer* is `"Noted."` or the summarizer's own output format, which is `^pw807cp`'s documented resident-container KV-bleed signature, not a token-accounting failure. The criterion as written on this card is still unmet, so this box is not checked and the task does not advance to the terminal column. A human decides whether to rewrite this criterion to hand `factRetention` to `^pw807cp`, or to keep this card open until `^pw807cp` closes.

  Resolved by measurement in iteration 5 (2026-08-09), and **not** by reassigning it to `^pw807cp` or by touching the criterion, which stands at `>= 0.9` exactly as written. `mean(CompactionEvalMetric.factRetention)` measured **1.0** — 24 of 24 samples retained — on two consecutive gated runs of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests`, and the gated `@Test` passes.

  Two causes were separated by staging the runs so neither could confound the other. **(1) A real fold defect, this card's own.** `CompactionPrompt.default`'s seven-heading schema had nowhere to put a bare stated fact, so such content was elided into an `Intent` meta-sentence that recorded THAT a fact was stated and discarded WHAT it was. A `2. Stated facts` section was added and the prompt renamed `router-default-v2` (its own doc comment requires a new name for new wording). Run A carried that fix with the fixtures held byte-for-byte at their old form: `summaryLostFact` went 1 to **0** and `printer-and-supply-closet`'s summary now reads `2. Stated facts — The office printer's spare toner cartridges are kept in the third-floor supply closet.` **(2) The remaining 17-18 failures were a fixture artifact, not compaction quality.** Every one answered with the literal `"Noted."` that `CompactionEvalTurn.statement` gave every statement turn of every fixture, so the resumed window ended in 4-7 identical `question -> "Noted."` pairs and the eval was measuring the model completing the pattern in front of it. Giving each turn its own reply moved `factRetention` from 0.2917 to 1.0 and `answerMissedFactSummaryCarriedIt` from 17 to **0**, twice.

  The `^pw807cp` attribution is therefore not merely unverified but contradicted from a second direction: the failures vanish when the *fixtures* change, with the resident container, the budget and the model all held constant.

### Findings dropped under the review skill's written test-refactor exception

Both engine findings below ask to change test code that already existed, so the skill's blanket exception drops them. Recorded for history; no action required.

- `Tests/FoundationModelsRouterEvals/CompactionContinuityEvaluation.swift:194` — inline `Int((Double(budget.limit) * budget.target).rounded())` duplicates the new `TokenBudget.targetTokens`. The line predates this delta (`git blame` → `10955bea`, 2026-07-24) and `TokenBudget.tokens(for:)` computes the byte-identical expression `Int((Double(limit) * fraction).rounded())`, so this is deduplication of pre-existing test code with no behavioral difference.
- `Tests/FoundationModelsRouterEvals/CompactionEvaluation.swift:197` — the same finding on the same expression. The line predates this delta (`git blame` → `598fc24c`, 2026-07-23).

### Engine run notes

18 validator/file pairs attempted, 0 failed, 1 file skipped (`RoutedSession.swift`, over the prompt cap). The tool rule `code-hygiene/missing-docs-swift` was unavailable (tool missing, exit status 1); the prompt rule `missing-docs` ran instead.

## Review Findings (2026-08-08 11:26)

Scope: `review sha HEAD~1..HEAD` (commit `2adf089`) — this iteration's delta only.

- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift:100` — The parameter `since started: Date` (line 102) is documented with its external label `since` instead of its internal name `started`. The rule requires documenting the internal (local) parameter name that Swift-DocC resolves against. Change the documentation from `///   - since:` to `///   - started:` to match the internal parameter name.

  Fixed in iteration 3. `finishTurnAndRequeueIfUnattached`'s doc key is now `- started:`. Swept both flagged files for the whole cause rather than the flagged line: every parameter carrying a distinct external label was checked against its doc key, and one further instance was found and fixed in the *other* file — `recordFailedTurn(grammar:since:usageBefore:pendingEvents:onEvent:)` in `RoutedSessionActorTurnExecution.swift` also declares `since started: Date` and also documented it as `- since:`. The remaining `- since:` keys in `RoutedSessionActorRecording.swift` (`finishTurn`, `recordTranscriptDelta`, `makePartialEvent`) are correct: those three declare `since: Date` with no separate internal name, so `since` *is* the internal name. DocC symbol links such as ``finishTurn(grammar:since:usageBefore:pendingEvents:onEvent:)`` were deliberately left alone — the rule states a symbol link uses the declaration's external labels and is not a violation.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift:460` — Magic numbers should be replaced by named constants.

  Fixed in iteration 3. `Int(Date().timeIntervalSince($0) * 1_000)` now reads `* Self.millisecondsPerSecond`, declared as `private static let millisecondsPerSecond: Double = 1_000` beside its one consumer (the same placement the file's sibling `turnBindingToolStamp` uses). Swept the whole file: after the fix the only numeric literal left anywhere in it is that `static let`'s own value, which the deciding `magic-numbers-swift` rule explicitly does not report ("reported nothing for … a `static let` … each of those declarations names its value").
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:91` — The `generate` function's doc comment does not document the `onEvent` parameter, violating the rule that documentation must cover exactly the parameters, return, and throws the signature declares. Add `onEvent` parameter documentation to the `- Parameters:` block, e.g., `///   - onEvent: A sink for this turn's derived ``SessionEvent``s, or `nil` to skip event derivation.`.

  Fixed in iteration 3, and the cause removed from the whole file rather than only from `generate`. Three further declarations in the same file did not document exactly what their signature declares, and all three are corrected: `ModelCallCancellationProbe.bind(to task:)` carried no `- Parameter task:` at all, and `dispatchNextPrompt()` documented neither its `String?` result nor the fact that it `throws` (`- Returns:` appears iff the result is non-`Void`, `- Throws:` iff the function throws). Every other declaration in the file was checked and already complete.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:638` — Magic numbers should be replaced by named constants.

  Fixed in iteration 3. `loweredRetryTarget(from:)`'s body is now `target / retryTargetHalvingDivisor`, declared as `private static let retryTargetHalvingDivisor: Double = 2` immediately above its one consumer. Swept the whole file: the only numeric literal left is that declaration's own value. The `max(target / 2, 0.1)` inside `loweredRetryTarget`'s doc comment is prose describing the bug iteration 1 fixed, not a live literal, and is left verbatim.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift:730` — flattenedPromptText reimplements existing functionality from TranscriptEntryMapper.flattenedText; both extract text content from transcript-related structures (Transcript.Prompt vs transcript entries) by filtering segments and joining text. Call TranscriptEntryMapper.flattenedText(prompt) instead of reimplementing the segment-extraction logic, or if that function operates on a different type, check whether it can be generalized to handle Transcript.Prompt, or extend it with a Prompt-specific overload.

  Fixed in iteration 3 by taking the third option the finding offers — a `Prompt`-specific overload — with the shared extraction genuinely shared rather than copied. `RoutedSessionActor.flattenedPromptText(_:)` is deleted; `dispatchNextPrompt()` now calls `TranscriptEntryMapper.flattenedText(queued.prompt)`. Inside the mapper the `.text` filter was lifted into one `textContents(_ segments: [SegmentPayload]) -> [String]`, which both overloads read, so the recording side and the prompt side can no longer drift on *what* counts as text. The prompt overload reaches `[SegmentPayload]` through `segmentPayload(_:)` — the same mapping `event(from:)` already applies to a live `.prompt` entry, and the reuse that function's own doc invites — rather than adding a second filter over `Transcript.Segment`.

  The two overloads still differ on the two things that are not shared, both preserved byte-for-byte from the deleted implementation and both now documented on the overload: it joins with **no separator** (the recording side joins with `"\n"`), and it answers `""` rather than `nil` for a prompt carrying no `.text` segment. That was the behavioral risk in this finding, so it is pinned by tests rather than asserted: a new ungated `PromptTextFlatteningTests` suite (multiple text segments join with nothing between them; a non-text segment contributes nothing; no `.text` segment flattens to `""`; the recording-side overload keeps its own newline join and its `nil`-for-empty answer) plus a new session-level test in `PromptQueueTests` that dispatches a genuinely multi-segment queued prompt and asserts the exact string the backend received. The pins were proven able to fail: temporarily giving the shared implementation a `"\n"` separator failed 3 of the 5, including the session-level one, and the run was reverted.

### The prior cap finding is confirmed resolved

The 2026-08-08 10:44 section's first item is closed by measurement, not by assertion: this run reports `skipped: 0` and `skipped_files: []` against the previous run's 1 skipped file, with the same 18 validator/file pairs attempted and 0 failed. The nine validators that could not read `RoutedSession.swift` — code-hygiene, code-security, completeness, complexity, duplication, missing-docs, reuse, swift, test-integrity — did run this time, and three of the five findings above are *in* `RoutedSessionActorTurnExecution.swift`, the file that now holds this card's two previously unreviewed production fixes (the trigger and ceiling token comparisons in `runTurn`/`runTurnAttempt`, and `loweredRetryTarget(from:)`). That coverage was the point of iteration 2, and it is now proven present.

### Engine run notes

`counts`: 5 findings, 5 confirmed, 2 refuted, 18 attempted, 0 failed, 0 skipped, no skipped files. All five findings are in production sources under `Sources/FoundationModelsRouter/Session/`; none is a test-refactor finding, so the skill's test-refactor exception drops nothing this pass.

## Review Findings (2026-08-08 11:59)

Scope: `review sha HEAD~1..HEAD` (commit `fb49f78`) — this iteration's delta only.

Zero new findings. The engine returned an empty checklist, so this section adds no item.

### Why this pass is not `clean`

All five findings of the 2026-08-08 11:26 section are `- [x]`, and this run adds none. The single item that keeps this card in `review` is the second item of the 2026-08-08 10:44 section: the acceptance criterion `mean(CompactionEvalMetric.factRetention) >= 0.9`, measured `0.0833`. It is escalated to a human decision — rewrite the criterion to hand `factRetention` to `^pw807cp`, or hold this card until `^pw807cp` closes — and this review neither checked it nor attempted it. It is the only remaining open item on the card, so the card stays in `review` and does not advance to `done`.

### Engine run notes

`counts`: 0 findings, 0 confirmed, 0 refuted, 9 attempted, 0 failed, 0 skipped, no skipped files. Commit `fb49f78`'s code files are `Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift`, `Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift`, `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift`, `Tests/FoundationModelsRouterTests/PromptQueueTests.swift`, and `Tests/FoundationModelsRouterTests/PromptTextFlatteningTests.swift`; none was skipped for the prompt cap. No finding was dropped this pass — the engine reported none, so the skill's test-refactor exception had nothing to apply to.
#phase-1