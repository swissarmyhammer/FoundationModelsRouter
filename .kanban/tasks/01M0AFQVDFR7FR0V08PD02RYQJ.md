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
position_column: doing
position_ordinal: '8380'
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
- [x] If a production surface had to change to allow injection, that change is stated and justified rather than slipped in — none had to, and the suite's doc comment says so #compaction #eval #real-model