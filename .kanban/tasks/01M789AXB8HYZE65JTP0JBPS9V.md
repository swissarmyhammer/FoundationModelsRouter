---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m789espz2asxamvyctxfmn0k
  text: 'Research: tool results reach the session at `noteToolResult(_:)` (RoutedSessionActorCompactionYield.swift) through `ToolResultAppendBoundary`, delivered by `ToolFailureDelivery` (FoundationModelsExtras) after the tool body returns, with `toolName` and `arguments` (GeneratedContent). `ToolCallIdentity(toolName:argumentsJSON:)` from IdenticalToolCallRun.swift can be built from that, so the reset lives at the result boundary: a result whose identity is new in the answer resets `recoveriesThisAnswer`; a repeat does not. `router.recoveries` / `router.stops` are counted host-side in FoundationModelsACPAgent PromptTally.countRouterStop(recovery:): stops counted, and recoveries = stops whose `recovery` was non-nil — a total over the prompt, not Router''s counter, so it keeps its meaning. Test helpers: StagedReasoningModel (one script per call) + RepeatingReasoningScript.reasoningHeldAtLimit() + `.toolCall` ending (fixed args) in ReasoningStopRecoveryTests.'
  timestamp: 2026-11-12T16:29:05.631814+00:00
- actor: claude-code
  id: 01m78asbc4j9czecmm1404mh3m
  text: 'RED: Tests/FoundationModelsRouterTests/ConsecutiveRecoveryBudgetTests.swift. Before the change: stop/act x4 gives recoveries [1, 2, nil, nil]; repeat-call case [1, 2, nil]; mixed (3 identical runCode -> repeated-tool-call stop, reasoning stop, distinct call, reasoning stop) [1, 2, nil]. The no-progress case [1, 2, nil] passes, as the card says it does today. Env note: `swift test` first failed to compile in deps (Decision main needs PooledLogits from newer Extras): the gitignored Package.resolved pinned stale family revisions; `swift package update FoundationModelsExtras FoundationModelsLlamaCpp ...` fixed it. One early run of the suite hung >13 min with 3 tests in flight; later runs of the same build finished in 0.05 s, so that hang looks flaky (watch the full suite for it).'
  timestamp: 2026-11-12T16:52:19.972636+00:00
- actor: claude-code
  id: 01m78aykqss57ekav0qkb63te8
  text: |-
    GREEN. Implementation: `RepetitionWatchState.recoveriesThisAnswer` renamed to `recoveriesSinceProgress`, plus `toolCallsThisAnswer: Set<ToolCallIdentity>` (both cleared in `startAnswerLimits()`). New `noteToolCallProgress(_:)` in RoutedSessionActorRepetitionWatch.swift, called from `noteToolResult(_:)` at the tool-result boundary: when the result's `ToolCallIdentity` (new `init?(result: ToolResultAppend)`, ToolCallIdentity is now Hashable) was not seen earlier in the answer, the count goes to 0. Repeats and calls whose arguments cannot be compared do not reset it. Doc comments that said per answer were corrected in RepetitionDetection, RepetitionStop/ReasoningStop/WatchStop `recovery`, `recoveriesAllowed`, `recoveriesUsed`, the reasoning-stop and repetition-watch extension docs, the pump's `startAnswerLimits`, and RoutedSessionActor.repetitionWatch. `router.recoveries` (ACP PromptTally) counts the stops whose `recovery` is non-nil, so it is still the total of recoveries in the prompt; the WatchStop docs now say this. `recovery`/`recoveries=N/M` in WatchStop.description now mean the count since the last progress. Full `swift test`: 2642 tests in 306 suites + 41 + 19 passed, exit 0, only the known mlx-swift_Cmlx.bundle notice.

    ### implement — changed
    - evidence: 13 files: Sources/FoundationModelsRouter/Session/{IdenticalToolCallRun,ReasoningStop,RepetitionDetection,RoutedSessionActor,RoutedSessionActorCompactionYield,RoutedSessionActorPump,RoutedSessionActorReasoningStop,RoutedSessionActorRepetitionWatch,WatchStop}.swift; Tests/FoundationModelsRouterTests/{ConsecutiveRecoveryBudgetTests (new), Helpers/RepeatingReasoningModel, Helpers/SessionEventCollection, Helpers/StagedReasoningModel}.swift; `swift test` exit 0
    - next: /review
  timestamp: 2026-11-12T16:55:12.377032+00:00
- actor: claude-code
  id: 01m78bwx7q9mk2wdn1w16dv0cn
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (caaefa73). The engine found 1 (confirmed 1, refuted 0). The caller-requested unbounded-wait check found 1 more. Tests/FoundationModelsRouterTests/ConsecutiveRecoveryBudgetTests.swift:38 (caller/unbounded-wait), Tests/FoundationModelsRouterTests/ConsecutiveRecoveryBudgetTests.swift:60 (reuse/reuse)
    - next: bound the `.untilStopped` hold so a wrong behavior fails instead of hanging, and add a suite time limit. Then merge `runStagedAnswer` with the driver in ReasoningStopRecoveryTests into one shared helper.
  timestamp: 2026-11-12T17:11:45.143972+00:00
- actor: claude-code
  id: 01m78bxcetwbkpv2ca5j9e7jxq
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 9 Session sources, ConsecutiveRecoveryBudgetTests.swift (new), 3 helpers
    - test: green — swift test, 2642+41+19 passed; new suite 15/15 repeat runs
    - commit: caaefa73 (pushed so ACPAgent can take the fix)
    - review: findings — Tests/FoundationModelsRouterTests/ConsecutiveRecoveryBudgetTests.swift:38 (unbounded wait), Tests/FoundationModelsRouterTests/ConsecutiveRecoveryBudgetTests.swift:60 (reuse)
  timestamp: 2026-11-12T17:12:00.730805+00:00
position_column: review
position_ordinal: '80'
title: Recovery budget counts consecutive stops with no progress, not every stop in the answer
---
## What
This bug came from FoundationModelsACPAgent's live checked24 bench, on django-14016. That instance produced an EMPTY patch after 513 s of a 9000 s limit. The root session is 01M788THPCT3W4GA0GKV02K68S; the transcript is bench/preds.checked24.transcripts/django__django-14016/01M788THPCT3W4GA0GKV02K68S/transcript.jsonl in FoundationModelsACPAgent.

The answer was stopped at the reasoning token limit 4 times:
- seq 13667: stop → recovery → the model acted: searchTools (13670), then runCode (13688).
- seq 13704: stop → recovery → runCode (13707).
- seq 13720: stop → runCode (13723).
- seq 13738: stop with no recovery left. `router.recoveries=2 router.stops=4`, and the answer ended.

Every stop was followed by real progress: a tool call with a new result. `recoveriesPerAnswer` (RepetitionDetection.swift:86, default 2) is counted across the whole answer:
- `repetitionWatch.recoveriesThisAnswer`, in RoutedSessionActorRepetitionWatch.swift:24, :306-311 (`nextRecovery`) and :611
- it is reset only at the start of an answer (RoutedSessionActorPump.swift:501)

The count is shared by repetition stops, reasoning-limit stops (RoutedSessionActorReasoningStop.swift:99) and WatchStop (WatchStop.swift:85, :95). So a model that thinks long before each step runs out of recoveries after two steps.

## Rule
The budget counts consecutive stops with no progress between them:
- **Progress resets the count.** Progress is a tool call after a recovery that completes with a tool result, and is not a repeat.
- **What counts as a repeat.** The call is identical in tool name and arguments to an earlier call in the answer; reuse the identity of IdenticalToolCallRun.swift / the repeated-tool-call stop.
- **Why repeats don't count.** A loop of identical tool calls must still use up the budget. Otherwise a repeated-tool-call stop followed by the same call would recover forever.
- "stop, act, stop, act, …" never runs out of recoveries.
- "stop, stop, stop" with no action in between still ends the answer after `recoveriesPerAnswer` recoveries.

Keep the name `recoveriesPerAnswer` and its coding key, `recoveriesPerTurn`. Correct its doc comment and the other doc comments that say "per answer" so they state the consecutive rule. Read where tool results are recorded in the pump or answer execution, and reset the counter there.

The host log line "no recovery was left" and the `router.recoveries` / `router.stops` metadata should stay accurate. Check what `router.recoveries` reports now (the current count, or the total in the answer), and keep the meaning documented.

## Acceptance (test first)
- [x] A hermetic test with a scripted model: 4 reasoning-limit stops, each followed after its recovery by a distinct tool call with a result. The answer does not end on the 3rd or 4th stop; all 4 recover. This test fails before the change.
- [x] A test: stops with no tool call between them end the answer after `recoveriesPerAnswer` recoveries, as they do today.
- [x] A test: a recovery followed by a tool call identical to an earlier one does not reset the count.
- [x] Repetition stops (text repetition and repeated tool call) and reasoning-limit stops share the same consecutive count. Pin one mixed case.
- [x] `swift test` green. #recovery

## Review Findings (2026-11-12 11:09)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> The `caller/unbounded-wait` item comes from the check the caller asked for: can these tests, or the staged-reasoning helpers they use, wait forever when the behavior is wrong. The engine's own items carry a validator name.

- [ ] `Tests/FoundationModelsRouterTests/ConsecutiveRecoveryBudgetTests.swift:38` `caller/unbounded-wait` — Every test in this suite runs `reasoningStopScript` (`RepeatingReasoningScript.reasoningHeldAtLimit()`). Its `.untilStopped` hold waits on an `AwaitedEvent` that no code sends (`RepeatingReasoningModel.Executor.waitForStop`), so only a cancel from the session can end it. `StagedReasoningModel` picks each script by call count (`log.renders.count`), not by what the session asked for. So when the budget behaves wrongly, a held script can land on a call that the session never stops, for example a call after the reasoning-off final pass that runs when no recovery is left. The test then waits forever instead of failing. The suite has no `.timeLimit` trait. This is what happened on the first RED run against the old code: three tests stayed in flight for more than 13 minutes. Make a wrong behavior fail, not hang. Give the hold a bound: `waitForStop` races the event that is never sent against a deadline far above the passing run (under 0.1 s), and when the deadline passes it records an `Issue` that names the call index, then throws. As a backstop, add `.timeLimit(.minutes(1))` to `@Suite` here. Running out of scripts is not a hang: a call after the last script answers at once.
- [ ] `Tests/FoundationModelsRouterTests/ConsecutiveRecoveryBudgetTests.swift:60` `reuse/reuse` — The new `runStagedAnswer` helper re-implements the same staged-answer driver that already exists in `ReasoningStopRecoveryTests`. The new copy only differs in its detection, tool, and temp-dir prefix, so two near-identical drivers will diverge as the fixture changes. Parameterize the existing helper rather than adding a parallel copy. Move the common driver into one shared helper (for example in `Helpers/StagedReasoningModel.swift` beside `StagedReasoningSessionFixture.make`) that takes the scripts, detection, and tools as parameters. Have both `ConsecutiveRecoveryBudgetTests` and `ReasoningStopRecoveryTests` call it, passing `RepetitionDetection()` and `CountingRunCodeTool(runs: RunCount())` from this suite.
