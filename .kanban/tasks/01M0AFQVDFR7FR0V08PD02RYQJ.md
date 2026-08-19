---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bdnjbfmch4nx2837rvw1yf
  text: |-
    Picked up. Answered the card's first question from the source BEFORE any edit.

    ## The trigger and the window are ALREADY injectable. No production change is necessary.

    Read in this order:

    1. `Sources/FoundationModelsRouter/Compaction/TokenBudget.swift` — `TokenBudget` is `public`, and its `public init(limit:trigger:target:hardCeiling:toolOutputLimit:)` takes `limit` and `trigger` as ordinary parameters. `triggerTokens` is `trigger` resolved against `limit`.
    2. `Sources/FoundationModelsRouter/RoutedLLM.swift` — `public func makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:...)` takes `budget: TokenBudget?`. It is the auto-compaction opt-in and it is PUBLIC. It also takes `summarization: Summarization`, whose `public init(keepRecentTurns:maxChunkTokens:summaryTokenRatio:reasoningTokenHeadroom:)` makes the recency window a test input as well.
    3. `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift` — the proactive check inside `runTurn` is `measuredTokens >= budget.triggerTokens`, against the budget the session was vended with. Nothing else decides the trigger.

    So a test supplies the threshold through the PUBLIC surface, not even through `@testable`. Acceptance criterion 5 needs no production knob and none will be added.

    ## Two mechanical facts the test shape must respect

    - The check needs `usageState.measuredTokens` to be non-nil. A fresh session is `.none`, so the FIRST turn can never fold. At least one turn must run before the turn that trips the trigger.
    - `Summarization.apply` returns `nil` when the fold finds no turn outside the recency window (`guard !old.isEmpty`), and `Compactor` then takes the shortfall exit and applies nothing. `Compactor.stages` is a fixed `static let` at `keepRecentTurns` 4, but `Summarization` is vended per session, so `Summarization(keepRecentTurns: 1)` gives the fold an old span after only two turns.

    Therefore the shape is: two short priming turns, then ONE turn that trips the trigger and folds. That is the smallest transcript the automatic path can fold, and the trigger is the test's own number, so no fixture is sized against anything.

    ## Other discoveries

    - `RoutedSession.streamEvents(to:maxTokens:)` yields `.compaction(CompactionResult)` for a fold the turn took on its own, plus `.textDelta` for the answer. That is how "compaction ran without the caller asking" is observed. `Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift` already drives real turns exactly that way.
    - `RoutedSessionActor.runCancellableModelCall` takes NO second generation permit; it publishes a `GenerationPermitLoan`. So a fold inside a turn does not deadlock on the generation gate.
    - The gated real-model harness `buildProfile` now exists in THREE near-identical copies: `CompactionRoundTripIntegrationTests`, `SessionTreeRestorationIntegrationTests`, and the evals runner above. A fourth copy will not be written. A shared `Support/RealModelProfile.swift` is added instead, on the precedent of commit d82c33e, which did the same consolidation for `RealModelContainer.load`. The three pre-existing copies are left untouched, because two of them are 20-minute gated suites this card cannot run to verify. A follow-up card records that clean-up.
  timestamp: 2026-08-18T21:50:32.303052+00:00
- actor: claude-code
  id: 01m0beddgrqx8jp1nddddfsqpe
  text: |-
    Implementation landed. Two files, both tests. No production file changed.

    ## The shape, and why it is three turns and not one

    The card asks for ONE turn that trips the trigger. That is what the test asserts on, but the session needs two turns before it:

    1. A fresh session's `usageState` is `ContextUsageState.none`, so the trigger check reads no measured tokens and the FIRST turn can never fold, whatever the trigger is.
    2. `Summarization` answers `nil` when every turn is still inside the recency window, so the fold needs at least one turn outside it.

    At `Summarization(keepRecentTurns: 1)` two priming turns is the smallest transcript the automatic path can fold. Turn three is the turn under test.

    ## The two numbers the test states

    - `syntheticTriggerShareOfContext = 0.02` of the 4096-token window, which resolves to 82 tokens against the 3277 the production default of 0.80 resolves to.
    - `foldTargetShareOfContext = 0.001`, which resolves to 4 tokens. Unreachable on purpose: `ToolOutputElision` and `TurnTruncation` can never land the transcript there, so the pipeline always falls through to `Summarization` and the fold under test is always the model-assisted one. A reachable target would make WHICH stage folded depend on how long the model's replies happened to run, which is the defect `f80n046` records against the round-trip suite.

    `TokenBudget.limit` is the session's own window and not a number of its own, so a measured `contextFill` and `TokenBudget.trigger` sit on one scale. `TokenBudget.triggerTokens` records what happens when they do not.

    ## The RED run, before the green one

    The assertions were proved to bind to the trigger wiring, not to the model. With `budget: nil` on `makeSession` and nothing else changed, the run reported `foldsInTheTurn=0` and failed on the applied-fold requirement, while the trigger assertion still passed at a fill of 0.114 against 0.02. Restoring the budget made it green. So a run that goes red here says the automatic fold stopped happening; it does not merely say the model wrote something different.

    ## Measured, three consecutive runs, identical numbers

    | what the run measured | value |
    |---|---|
    | wall clock | 4.7 s, 5.0 s, 5.0 s |
    | of which model load | 1.9 s, 2.0 s, 2.0 s |
    | trigger / target, in tokens | 82 / 4 |
    | context fill, before and after the turn | 0.167 -> 0.107 |
    | folds inside the turn | 1 |
    | stages the fold applied | ToolOutputElision, TurnTruncation, Summarization |
    | the fold's transcript | 733 -> 369 estimated tokens |

    Three identical fold numbers is `.greedy` doing its job.

    ## Two things worth knowing for the next reader

    **The fixture has ONE size bound left, and it is not a trigger bound.** `Summarization` floors a call's summary allowance at `minimumSummaryTokens` (128). That floor binds for any span under 512 estimated tokens, and while it binds the allowance stops falling with the span — so a small span can buy a summary as large as itself and `Compactor` discards the fold for failing to shrink. The first scripted turn is therefore written past the floor, at 639 estimated tokens. The first draft of it was 410 tokens, the floor bound, and the fold saved only 31% instead of the 50% it saves now.

    **A no-op fold event lands on the second turn as well.** The trigger is crossed after turn one, so turn two runs the check, finds no turn outside the recency window, and reports a `CompactionResult` with an empty `stagesApplied`. It costs no generation. That is why the test asserts on the APPLIED folds of the turn under test rather than on any compaction event.

    ## A choice made, and a card filed

    The gated real-model profile builder existed in three near-identical copies. Rather than write a fourth, the new suite calls `Support/RealModelHarness.swift`, on the precedent of commit d82c33e. The three copies are left alone — two are 20-minute gated suites this card cannot run to prove the change safe — and `^hxyj3q1` records the move.
  timestamp: 2026-08-18T22:03:33.784154+00:00
- actor: claude-code
  id: 01m0bedkq9envccnbwa8887pfr
  text: |-
    ### implement — changed
    - evidence: 2 files — /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterIntegrationTests/AutoCompactionTriggerIntegrationTests.swift, /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterIntegrationTests/Support/RealModelHarness.swift. `FM_ROUTER_COMPACTION_SMOKE=1 swift test` — 984 unit tests, 30 integration tests, 58 evals, all passed, 0 failures, 0 warnings, 22.5 s for the whole package. The new suite alone: 4.7 s, 5.0 s, 5.0 s over three runs.
    - next: /review
  timestamp: 2026-08-18T22:03:40.137136+00:00
- actor: claude-code
  id: 01m0bewyjgnwtgthfcmq5esds7
  text: |
    ### review — findings
    - evidence: 1 finding — Tests/FoundationModelsRouterIntegrationTests/AutoCompactionTriggerIntegrationTests.swift:434. The validator fleet on `review sha HEAD~1..HEAD` was clean (0 findings, 0 confirmed, 0 refuted, 7 pairs attempted); the finding comes from the directed doc-accuracy check.
    - next: correct the priming-turn comment's stated reason. `ContextUsageState.none` gives `measuredTokens` 0, not nil, so the turn-one check runs and fails only because the trigger is positive. The recency-window reason, the `RealModelHarness` extraction, and acceptance criterion 4 were all verified correct and need no change.
  timestamp: 2026-08-18T22:12:02.768674+00:00
- actor: claude-code
  id: 01m0bf2v0s4pcsh87v0e2smx5r
  text: |-
    The one open finding is corrected. I read both sources before the edit, and the finding is correct on both facts.

    ## What the source says

    1. `Sources/FoundationModelsRouter/Compaction/TokenBudget.swift` — `ContextUsageState.measuredTokens` gives `0` for `.none` and `nil` only for `.unknown`. `tokens(for:)` is `Int((Double(limit) * fraction).rounded())`, so a trigger of `0.0` does resolve to `0` tokens.
    2. `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift` — the pre-turn check is `if let budget = autoCompactionBudget, let measuredTokens = usageState.measuredTokens, measuredTokens >= budget.triggerTokens`. `.none` gives a non-nil 0, so the `let` binding holds and the check DOES run on turn one. It compares `0 >= 82` and that is false.

    So the old comment gave a false mechanism. The turn-one fold is stopped by the SIZE of the trigger, not by the absence of a measurement.

    ## The correction

    The comment now states that a fresh session measures 0 tokens, that `.none` gives 0 and only `.unknown` gives `nil` and stops the comparison, that the check runs on turn one against `budget.triggerTokens`, and that 0 is below any POSITIVE trigger. It keeps the edge case rather than hiding it: a trigger of 0.0 resolves to 0 tokens and would fire on turn one. The recency-window half of the sentence is unchanged, because the finding confirms it is correct.

    ## The sweep

    I searched the whole file for the same mistaken reading of `.none`. There is one site only, and it is the one corrected. Two other files carry the phrase "measured nothing", but both are about a summarizer that answered too long, not about `ContextUsageState`, so neither is the same defect.

    ## The run

    `FM_ROUTER_COMPACTION_SMOKE=1 swift test` — 984 unit tests, 30 integration tests, 58 evals, 0 failures, 28.5 s. The `1 known issue` in the unit run is the pre-existing `withKnownIssue` in `BoundedWait.swift`, and its test passed. The gated suite reported the same numbers as the recorded measurement: triggerTokens 82, targetTokens 4, fill 0.167 -> 0.107, one applied fold, 733 -> 369 tokens, 4.7 s.
  timestamp: 2026-08-18T22:15:15.737073+00:00
- actor: claude-code
  id: 01m0bf30a0j72mqpa666e0kby6
  text: |-
    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterIntegrationTests/AutoCompactionTriggerIntegrationTests.swift. `FM_ROUTER_COMPACTION_SMOKE=1 swift test` — 984 unit, 30 integration, 58 evals, 0 failures, exit 0, 28.5 s. The finding's checkbox is checked; 0 findings are open.
    - next: /review
  timestamp: 2026-08-18T22:15:21.152228+00:00
- actor: claude-code
  id: 01m0bf8k7ns542x9aw11t1zwb9
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 6bed76a) — 0 findings, 0 confirmed, 0 refuted; 7 validator/file pairs attempted, 0 failed, 0 skipped. 1 file reviewed, 2 not reviewed (`.kanban/`, excluded by `.reviewignore`). Round one's one finding is checked.
    - directed accuracy check: the corrected comment at `Tests/FoundationModelsRouterIntegrationTests/AutoCompactionTriggerIntegrationTests.swift:435-443` is TRUE against source, not only different. `ContextUsageState.measuredTokens` gives `0` for `case .none` and `nil` for `case .unknown` (`Sources/FoundationModelsRouter/Compaction/TokenBudget.swift`), which is what the comment now says. The pre-turn check in `RoutedSessionActorTurnExecution.runTurn` binds `let measuredTokens = usageState.measuredTokens` and compares `measuredTokens >= budget.triggerTokens`, so only `.unknown` stops the comparison and the check DOES run on turn one, as the comment now says. `TokenBudget.triggerTokens` is `tokens(for: trigger)` and `tokens(for:)` is `Int((Double(limit) * fraction).rounded())`, so a trigger of `0.0` gives `0` tokens and `0 >= 0` holds — the comment's edge case is correct. `syntheticTriggerShareOfContext` is `0.02`, a positive trigger, as the comment says. The false "whatever the trigger is" universal is gone.
    - sweep: `ContextUsageState` appears once in the file, at the corrected comment. No other site in the file carries the same mistaken reading of `.none`. The recency-window half of the sentence and the `foldKeepRecentTurns` doc are unchanged and stay correct.
    - next: none. Card is in `done`.
  timestamp: 2026-08-18T22:18:24.373288+00:00
position_column: done
position_ordinal: ffb580
title: Test auto-compaction with a synthetic trigger threshold, so no fixture has to be grown to trip it
---
From the user, 2026-08-18:

> a better way to test auto compaction would be to do so with a synthetic limit on the triggering threshold of the context window

Auto-compaction has no fast test at all. `^w1cz46m` covers `Compactor.compact` called directly, which is the manual path. The automatic path — context fill climbs, the trigger fires, a fold happens inside a turn — is measured only by `CompactionRoundTripIntegrationTests` against the 30B model, at 425 seconds.

## Why this is the right shape

`^vjf3mdm` grew all 24 eval seeds so their transcripts would be large enough to trip the 0.80 trigger against a real context window. That was solving the wrong problem. The trigger is a number. If a test can set it low, a small transcript trips it, and the whole fixture-sizing arithmetic disappears:

- No seed needs to be grown to reach a threshold.
- `CompactionEvalSeedSizingTests` exists to prove the fixtures still clear their bound. A synthetic threshold makes that bound a test input rather than a property of the fixture.
- The measured 4.81 bytes-per-token constant, and the estimate-versus-tokenizer gap that broke `CompactionRoundTripIntegrationTests` twice, stop mattering for the trigger question.

## What to build

A test that sets the trigger threshold (and, if needed, the context window it is a fraction of) to a synthetic value small enough that a short transcript crosses it, then drives ONE turn and asserts the fold happened automatically:

- `contextFill` crosses the trigger.
- Compaction ran without the caller asking for it.
- The turn still returned an answer.
- The transcript after is smaller than before.

Use the smallest model that can do the job, as `^w1cz46m` does.

## First question to answer

Whether the trigger and the window are already injectable. `TokenBudget` carries the trigger; check whether a test can supply its own value through the public or `@testable` surface without changing production code. If it cannot, say so before changing anything — making a production knob test-settable is a design decision worth stating rather than assuming.

## Answer, 2026-08-18

They are already injectable, through the PUBLIC surface. No production code changed.

- `TokenBudget` is public and its `public init(limit:trigger:target:hardCeiling:toolOutputLimit:)` takes `limit` and `trigger`.
- `RoutedLLM.makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)` is public and takes that budget. It also takes `summarization`, which makes the recency window a test input too.
- The proactive check in `RoutedSessionActorTurnExecution.runTurn` is `measuredTokens >= budget.triggerTokens` against that same budget. Nothing else decides the trigger.

## What was built

`Tests/FoundationModelsRouterIntegrationTests/AutoCompactionTriggerIntegrationTests.swift`, gated on `FM_ROUTER_COMPACTION_SMOKE` beside the smoke suite, against `mlx-community/Llama-3.2-1B-Instruct-4bit` at greedy decoding. Measured at 4.7 s, 5.0 s, 5.0 s over three runs, of which 2.0 s is the model load.

`Tests/FoundationModelsRouterIntegrationTests/Support/RealModelHarness.swift` holds the shared profile builder the new suite uses. `^hxyj3q1` records the three pre-existing copies it does not touch.

## Acceptance Criteria

- [x] The trigger threshold is a test input, not a property the fixture has to be sized against
- [x] One test drives a real turn, trips the trigger synthetically, and asserts the fold happened without the caller asking
- [x] It runs in seconds against a small model, and prints its own wall clock the way `^w1cz46m` does
- [x] It states in its doc comment what it proves and what it does not
- [x] If a production surface had to change to allow injection, that change is stated and justified rather than slipped in — none had to, and the suite's doc comment says so

## Review Findings (2026-08-18 17:06)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 6 not reviewed (`.kanban/`, excluded by `.reviewignore`).

The validator fleet returned zero findings over the two new files (7 validator/file pairs attempted, 0 failed, 0 skipped). The item below comes from the directed accuracy check this pass was asked to make, not from a validator.

- [x] `Tests/FoundationModelsRouterIntegrationTests/AutoCompactionTriggerIntegrationTests.swift:434` `directed-check/doc-accuracy` — the comment above the two priming turns in `aSyntheticTriggerFoldsInsideTheTurn` states a false reason: "A fresh session has measured nothing yet (`ContextUsageState.none`), so its FIRST turn can never fold whatever the trigger is". `ContextUsageState.measuredTokens` answers `0` for `.none`, not `nil` — only `.unknown` answers `nil` and skips the comparison (`Sources/FoundationModelsRouter/Compaction/TokenBudget.swift`, `case .none: return 0`). So the pre-turn check in `RoutedSessionActorTurnExecution.runTurn` DOES run on turn one, and it compares `0 >= budget.triggerTokens`. Turn one does not fold here because `triggerTokens` is 82, a positive number — not because nothing was measured, and not "whatever the trigger is": `triggerTokens` is `Int((Double(limit) * fraction).rounded())`, so a trigger of `0.0` resolves to `0`, `0 >= 0` holds, and the check fires on turn one. State the reason the source supports — a fresh session measures `0` tokens, which is under any positive trigger — and drop the "whatever the trigger is" universal. Sweep the file for the same mistaken reading of `.none`; the second half of the same sentence, and the `foldKeepRecentTurns` doc, both state the recency-window reason correctly and need no change.

### Verified in this pass, no change needed

- `Summarization.apply` does return `nil` when no turn sits outside the recency window — `guard !old.isEmpty else { return nil }` after `TranscriptTurns.partition(turns, keepRecentTurns:)`. The doc comment's second mechanical reason is correct as written.
- `RealModelHarness.make` is a faithful extraction of the copy in `CompactionRoundTripIntegrationTests.buildProfile` for its one caller: same `noopResolution`, same root-plus-writer `DurableRecording` pair, same one `ResidentModelGates` set shared by `.standard` and `.flash` with a separate set for `.embedding`, same `UnusedEmbeddingContainer` stand-in. It differs only in `definitionName` and in taking `context` directly rather than reading it back off `noopResolution(slot).contextTokens` — the same value either way. The router id it deliberately does not take is needed only by a caller that restores a session tree across two routers, which this caller is not.
- Acceptance criterion 4 is met. The suite doc carries a "What this suite does NOT prove" section that states the synthetic threshold proves the wiring fires, not that 0.80 of a real window is the right moment to fold, and it also disclaims summary quality and fixture-size coverage.
- Every number the doc comments cite checks out against source: `Summarization` defaults `keepRecentTurns` 4, `maxChunkTokens` 2000, `summaryTokenRatio` 0.25, `reasoningTokenHeadroom` 4096; `minimumSummaryTokens` 128, so the floor binds under 512 estimated tokens; `Compactor.stages` is a fixed `static let` of `ToolOutputElision()` and `TurnTruncation()` at their own default of 4; `Compactor.charsPerTokenEstimate` is 4.0, so the 2556-byte `openingBrief` does estimate 639 tokens.
- `RoutedModel/makeSession(...)` is the right symbol for the doc link — `RoutedModel` is the public generic class in `LanguageModelProfile.swift` that `RoutedLLM` names. #compaction #eval #real-model