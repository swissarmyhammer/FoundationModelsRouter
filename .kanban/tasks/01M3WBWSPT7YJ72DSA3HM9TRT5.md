---
comments:
- actor: claude-code
  id: 01m3wdp1z4f76pn57939mdhnd3
  text: |-
    Research done. Findings:
    - The watch is in `RoutedSessionActorRepetitionWatch.swift`. `startRepetitionWatch()` feeds `WatchedText` to `RepetitionDetector.observe`. A finding goes to `noteRepetition`, which sets `RepetitionStopMarker` and cancels the call. `runSubmission` (in `RoutedSessionActorAnswerExecution.swift`) takes the marker in its catch branch and calls `continueAfterRepetitionStop`.
    - The detector already counts the tokens of each complete line. The plan: count the tokens of each `.reasoning` entry there, and give a reasoning-limit finding when the last watched entry is a reasoning entry at or over the limit.
    - A pass that ends with `maxTokens` or `endedInsideReasoning` does not throw. `runSubmission` gets the finish reason after `finishSubmissionAndRequeueIfUnattached`, and today only `compactsAfterCeilingStop` can continue the answer. The plan: when the attempt output after its last reasoning entry has no tool call and no response text, run the same recovery.
    - Plan for the count: the recovery counts against `recoveriesPerAnswer`. No new count.
    - Plan for the setting: `RepetitionDetection.reasoningTokenLimit: Int?`, named default `defaultReasoningTokenLimit = 8_192`. `nil` or `0` sets no limit. The stored form keeps an explicit `null`, so a `nil` value does not decode as the default. A missing key decodes as the default.
    - A new `SessionEvent` case and a new `FinishReason` case cause changes to the exhaustive switches in Sources, Tests, IntegrationTests and Examples.
    - Item 3 changes the behavior of tests that expect an answer to end at `endedInsideReasoning` on the first pass (for example `SubmissionFinishReasonTests.finishReasonIsPerAnswer`). The card asks for this change.
  timestamp: 2026-10-01T19:04:59.108456+00:00
- actor: claude-code
  id: 01m3wehv988xzjhrvvmv7t53gs
  text: |-
    Implementation done. What changed:
    - `RepetitionDetection.reasoningTokenLimit: Int?` with the named default `defaultReasoningTokenLimit = 8_192`. `nil` or `0` sets no limit, and a detection that is not enabled sets no limit (`reasoningTokenLimitInForce`). The log line names the value: `reasoningTokenLimit = 8192` is in `loggedValues`. The stored form now has an explicit `encode(to:)`, so a `nil` limit is stored as `null` and does not load as the default. A stored form with no key loads with the default.
    - `RepetitionDetector` counts the tokens of the complete lines of each `.reasoning` entry. `reasoningLimitFinding()` gives a finding only when the last watched entry with text is that reasoning entry. A pass whose response text or tool call follows the reasoning acts, and the limit does not stop it. The tool-body check (`checkToolCallForRepetition`) does not apply the limit, because a pass that wrote a tool call acts.
    - The watch stop marker is now `WatchStopMarker` with a `WatchStopReport` (`.repetition` or `.reasoning`). A reasoning stop keeps the whole reasoning so far (no cut, and no `repeatedPartRemoval` event), closes the stopped attempt with `FinishReason.reasoningTokenLimit`, emits `SessionEvent.reasoningStopped(ReasoningStop)`, logs under the new category `ReasoningStop` and the metadata key `reasoning_stop`, and runs a recovery with `reasoningStopContinuationPrompt`.
    - Item 3: after an attempt that ends with `maxTokens` or `endedInsideReasoning`, `runSubmission` reads the last pass (after the last `.prompt` or `.toolOutput`). When that pass wrote only reasoning (`ReasoningOnlyOutput`), the answer emits `reasoningStopped` (with the ceiling as the limit for `maxTokens`, and no limit for `endedInsideReasoning`) and runs the same recovery. Over the compaction trigger at a ceiling stop, it compacts first. The pass check reads the whole last pass, because a real model can write its reply and then a `<think>` block after it (see `RealToolAnswerComparisonTests`).
    - All recoveries share `recoveriesPerAnswer`. No new count and no new bound.
    - Discovery: `IntegrationTests` does not build on `main`, because its `Package.resolved` pins an old FoundationModelsExtras with no `Mailbox`. This is not from this task. New task ^cfbqtfm records it.
    - Existing tests changed because the card changes the behavior: `CeilingStopCompactionTests.endedInsideReasoningOverTheTriggerDoesNotCompact` now expects one reasoning recovery, and `SubmissionFinishReasonTests.finishReasonIsPerAnswer` now uses `recoveriesPerAnswer: 0`, so its first answer still ends truncated.
    - Owner decision still open: the default 8,192 is the card proposal from one run of 12 instances. The doc comment of `defaultReasoningTokenLimit` says the owner must confirm it.
  timestamp: 2026-10-01T19:20:09.768024+00:00
- actor: claude-code
  id: 01m3wehyxexb8epb1y86ecjyvv
  text: |-
    ### implement — changed
    - evidence: `swift test`: 1451 tests in 183 suites passed, 2 known issues that were there before, no compile warning. New file `Tests/FoundationModelsRouterTests/ReasoningTokenLimitTests.swift` (5 suites, 20 test cases). Sources changed: RepetitionDetection.swift, RepetitionDetector.swift, ReasoningStop.swift (new), RoutedSessionActorReasoningStop.swift (new), RoutedSessionActorRepetitionWatch.swift, RoutedSessionActorAnswerExecution.swift, RoutedSessionActorCompactionYield.swift, RoutedSessionActorPump.swift, FinishReason.swift, GenerationCallUsage.swift, SessionEvent.swift, SessionAnswer.swift, SessionProjection.swift, RouterTelemetry.swift. Also tests and helpers, Examples/MultiModelGeneration/main.swift, IntegrationTests/RealToolAnswerComparisonTests.swift and generation-queue.md.
    - next: /review. The owner must confirm the default of 8,192 tokens.
  timestamp: 2026-10-01T19:20:13.486848+00:00
- actor: claude-code
  id: 01m3wem4n1ndfkbymt8syf1phz
  text: |-
    ### test — green
    - evidence: swift test (one run, no code change) — 1451 tests in 183 suites passed, 0 failures; 23 tests in 11 suites passed; 19 tests in 3 suites passed; 0 skipped. 2 known issues come from two withKnownIssue tests that already existed (BoundedWaitTests, RealModelHarnessTests). They assert an issue is recorded. They are not skips.
    - warning seen: SwiftPM prints "missing creator for mutated node" for the mlx-swift_Cmlx bundle. It is a build-system message about a dependency. It does not come from package source. The build was incremental (2.27 sec), so a source warning cached from an earlier build would not show.
    - next: review. IntegrationTests package build problem is on card ^cfbqtfm and was not part of this run.
  timestamp: 2026-10-01T19:21:24.897865+00:00
position_column: doing
position_ordinal: '80'
title: Stop a pass whose reasoning goes past a limit, and run a recovery that tells the model to act
---
## Problem

A reasoning model can think for a long time in one call, write no tool call, and never act. No setting of Router stops this before `passTokenLimit` (16,384 tokens). When a pass reaches that limit inside the reasoning, the answer ends with nothing: the next submission generates 0 tokens in 2 ms, and the turn ends.

Evidence: SWE-bench run of 2026-10-01 in FoundationModelsACPAgent. Two of the first 12 instances ended this way with no patch:

| Instance | Last call | Time | What the reasoning held |
|---|---|---|---|
| `django__django-13447` | fed 31,420, generated 16,384, "stopped at the token ceiling, left text" | 560 s | a counting loop (card: shape compare) |
| `django__django-14016` | fed 34,103, generated 16,384, "stopped at the token ceiling, left text" | 570 s | 64,659 characters: the model tried to remember the upstream fix ("upstream" 37 times, "remember" 19 times), and wrote about 45 python code blocks in its reasoning and never ran them |

For `django__django-14016` the repetition detector worked correctly: in each eighth of the reasoning, 36 to 85 of about 85 lines were new. This is not repetition. It is reasoning with no end.

Transcripts: `bench/preds.code-context.transcripts/<instance>/` in FoundationModelsACPAgent.

In the 10 instances of the same run that made a patch, the longest call was 9,584 tokens.

## What to do

1. Add `reasoningTokenLimit` to `RepetitionDetection` (or to a new settings value beside it): the most reasoning tokens of one generation pass. Proposed default: 8,192. A `nil` or `0` value sets no limit.
2. When a pass reaches the limit inside the reasoning, stop the call as the repetition stop does: keep the reasoning so far, and run a recovery submission with a short prompt that tells the model to act (make a tool call, or give the answer). Count it against `recoveriesPerAnswer`, or give it a count of its own.
3. When a pass reaches `passTokenLimit` inside the reasoning (`FinishReason.endedInsideReasoning` or `maxTokens` with reasoning only), run the same recovery, not a continuation that ends the answer with 0 tokens.
4. Emit a session event for the stop with its numbers (reasoning tokens, limit, recovery number), as `repetitionStopped` does, so a host can log it.
5. Name the stop in `FinishReason` when no recovery is left, so a host can map it to its own stop reason.

## Tests

- A scripted reasoning of 10,000 tokens with new lines and no tool call: the call stops at 8,192, a recovery runs, and the recovery prompt reaches the model.
- A reasoning below the limit that ends in a tool call: no stop.
- No recovery left: the answer ends with the named finish reason.
- The setting decodes with its default when the key is absent.

## Owner decision needed

The default value. 8,192 is a proposal from one run of 12 instances with `mlx-community/Qwen3.8-27B-mxfp4`. #generation-queue