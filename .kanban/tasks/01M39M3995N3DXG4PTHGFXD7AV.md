---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m39nwwvk0bbq24jbfgfetn7e
  text: |-
    ## Research: which ceiling stopped seq 132 and seq 225 (question 1)

    Answer: no ceiling stopped the two calls. The ceiling of each call was 262,144 tokens. Each call stopped inside its reasoning block, below the ceiling. Router then gave the stop the label "stopped at the token ceiling", because it reads the `incompleteOutput` flag of the engine as a ceiling stop.

    ### The ceiling value, from the ACP agent to the engine

    Versions of the run: ACP agent `Package.resolved` pins Router bbad3ce and mlx-swift-lm bc13b2f. The `.build/checkouts` are at these revisions.

    1. ACP agent names no ceiling: `FoundationModelsACPAgent/Sources/FoundationModelsACPAgent/Agent/PromptTurn.swift:193` calls `session.streamEvents(to: prompt, maxTokens: nil)`.
    2. Router, stream path: `Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift:374` makes `ResponseTokenCeiling(requested: maxTokens, contextTokens: contextTokens)`. `RoutedSessionActorTurnExecution.swift:29-32` (`responseTokenCeiling(requested:contextTokens:)`) returns `contextTokens` when the caller names no ceiling.
    3. `contextTokens` of the session is 262,144: `session.json` has `"context": 262144` and `"budget": {"limit": 262144}`. The agent log has `18:50:23.426 [FoundationModelsACPAgent:Session] session budget: context=262144 trigger=0.800000 target=0.500000`.
    4. Backend: `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:224-225` (`makeGenerationOptions(maxTokens:)`) sends `maxTokens ?? contextWindow`. The value is 262,144 here, thus the fallback to the window of 0bb3bb5 is not used, and the result is the same value.
    5. The transcript records the value that went to the engine. Both prompt entries have it: seq 61 (attempt 1) and seq 174 (attempt 2) have `"options":{"maximumResponseTokens":262144}`.
    6. Engine (mlx-swift-lm bc13b2f): `Libraries/MLXFoundationModels/MLXLanguageModel.swift:2204` (`runAllowedToolGeneration`) makes the parameters with `maxTokens: requestedMaxTokens ?? Self.defaultMaxTokens`, thus 262,144. The length stop is `Libraries/MLXLMCommon/Evaluate.swift:963-964` (`TokenIterator.next()` returns `nil` at `tokenCount >= maxTokens`) and `Evaluate.swift:2587` (`stopReason = .length`). 39,617 and 12,182 are much less than 262,144, thus the length stop did not occur.

    ### Why the record says "stopped at the token ceiling"

    - Engine: `MLXLanguageModel.swift:1725-1727` sets the response metadata `incompleteOutput: true` when `result.endedInsideReasoning` is true. The flag tells only that the stream ended inside the reasoning block. It does not tell why the stream ended.
    - Router: `Sources/FoundationModelsRouter/Session/FinishReason.swift:64-67` makes `.maxTokens` when the last response entry has that flag, also when the call generated less than the ceiling. `RoutedSessionActorGenerationCalls.swift:115-117` makes the finish reason of each call this way. `GenerationCallUsage.swift:80-81` writes `.maxTokens` as "stopped at the token ceiling".
    - Transcript: the response entries (seq 130, seq 223) are empty. The reasoning entry seq 131 has 162,595 characters and ends in the middle of a word: "Let me look at `_do_insert". The reasoning entry seq 224 has 50,006 characters and ends in the middle of a sentence: "... when the related object was unsaved at the time of assignment, the". So each stream ended inside `<think>`, not at a boundary that the model chose.

    ### What stopped the stream: the evidence excludes some causes, and cannot name the last one

    - Not the ceiling (see above).
    - Not a cancel by Router: Router cancels a model call only at a tool result (`RoutedSessionActorCompactionYield.swift:48-69`, `noteToolResult(_:)`) or on a stop of the user. Seq 132 and seq 225 called no tool. The log has no "a tool result took the context to" line. The only CompactionYield line is at 19:16:25.088, after the end of seq 132: "an attempt stopped at its output token ceiling with the context at or over the trigger; the turn compacts and goes on". That line is the result of the label, and of the summed fill of ^tpsc0nf.
    - Not a cancel by the ACP agent: the turn went on after seq 132 (seq 133 and more calls), and the log has no cancel line.
    - Remaining causes in the engine loop (`Evaluate.swift:2541-2587`): a stop token (the model config has `eos_token_id` 248046 `<|im_end|>` and 248044 `<|endoftext|>`), a stop string of the protocol decoder, or the end of the stream. The engine does not log its `GenerateStopReason`, and the recording does not keep the metadata of the response entry. Thus the evidence cannot tell which of these three occurred. The most probable cause is a stop token that the model sampled inside its reasoning: ^1hcwaqy measured that the last 8/10 of seq 131 and the last 5/10 of seq 224 repeat lines that the model already wrote.
    - Throughput agrees: seq 132 ran 1,409 s for 39,617 tokens (28 tokens/s). Seq 225 ran 445 s for 12,182 tokens (27 tokens/s). The two numbers are not the same value of one bound.

    ### Router defect found

    The ceiling computation is correct. The defect is the label: Router reports a stream that ended inside its reasoning below the ceiling as `FinishReason.maxTokens` ("stopped at the token ceiling"). The ACP agent then maps it to `_truncated`, and `compactsAfterCeilingStop` compacts and sends "Your last output was cut off at the token ceiling. Continue the task." (the prompt of seq 174). The correct behavior needs a decision of the user. See the step record.
  timestamp: 2026-09-24T12:22:57.651605+00:00
- actor: claude-code
  id: 01m39nx2f1t9d94vdgm033f60q
  text: |-
    ## Status of questions 2 and 3

    - Question 2 is done. ^tpsc0nf (commit 0a19051, "count the context from the newest call, not the sum of the attempt") corrected the summed fill. The `contextFill=1.877` of this run came from that sum. The unnecessary compaction after seq 132 (log line 19:16:25.088, CompactionYield) came from the summed fill and from the label of question 1.
    - Question 3 now belongs to ^1hcwaqy: a detector that stops a call that repeats itself. The user must approve each default value of that detector. This card does not implement a detector or a new bound.
  timestamp: 2026-09-24T12:23:03.393345+00:00
- actor: claude-code
  id: 01m39nxpy2jgd6rphbkq1dkhsk
  text: |-
    ### implement — stuck
    - evidence: question 1 answered, with no code change. No ceiling stopped seq 132 (39,617) or seq 225 (12,182). The ceiling was 262,144 for each call: ACP `PromptTurn.swift:193` sends `maxTokens: nil`; Router `RoutedSessionActorGeneration.swift:374` and `RoutedSessionActorTurnExecution.swift:29-32` resolve it to `contextTokens` = 262,144 (log 18:50:23.426 "session budget: context=262144"); `LiveModelLoader.swift:224-225` sends it; the transcript prompt entries seq 61 and seq 174 record `maximumResponseTokens: 262144`; the engine length stop is at `Evaluate.swift:963-964` and `:2587`. Each stream ended inside `<think>` below the ceiling (seq 131 ends "`_do_insert", seq 224 ends "the"). The engine sets `incompleteOutput` (`MLXLanguageModel.swift:1725-1727`), and Router `FinishReason.swift:64-67` reads it as `.maxTokens`, printed as "stopped at the token ceiling" (`GenerationCallUsage.swift:80-81`). The engine does not log its stop reason, so a stop token, a stop string, or the end of the stream is not identified. Files changed: none. Tests: none run (no code change).
    - question for the user: A call can end inside its reasoning block before it reaches the ceiling (here at 39,617 and 12,182 of 262,144 tokens). Today Router reports that call as `FinishReason.maxTokens` ("stopped at the token ceiling"). The ACP agent then ends the turn with `_truncated`, and Router compacts and sends "Your last output was cut off at the token ceiling. Continue the task." How must Router report such a call? (a) Keep `.maxTokens` for every call that ends inside reasoning, as now. (b) Add a new `FinishReason` case for "the output ended inside reasoning before the ceiling", with its own record text; the ACP agent then needs a mapping for it, and you decide whether the continuation after a ceiling stop also applies to it. (c) Report `.maxTokens` only when the generated count reaches the ceiling, and `.completed` in all other cases.
    - next: the user answers the question. Then write failing tests in `FinishReasonTests`/`TurnFinishReasonTests` for the chosen behavior, and change `FinishReason.init(turnEntries:outputTokens:lastCallOutputTokens:responseTokenCeiling:)`.
  timestamp: 2026-09-24T12:23:24.354972+00:00
- actor: claude-code
  id: 01m39nyzvj7ttzg2kzaytk7aem
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — Q1 answered: no ceiling stopped the calls (ceiling 262,144 each); both streams ended inside the reasoning, and Router labels that `.maxTokens`. Question: how must Router label that stop.
    - test: not run (no code change)
    - commit: none
    - review: not run

    ### Decision (orchestrator, per the rule "compaction: decide, do not ask")
    Choose option (b): add a new `FinishReason` case for "the output ended inside the reasoning before the ceiling".

    Reasons:
    - The label must be true. `.maxTokens` says "stopped at the token ceiling", and that is false here (39,617 and 12,182 of 262,144). Option (a) keeps the false label.
    - Option (c) reports `.completed`, but the output is not complete: the reasoning ends mid-word and the response is empty. A host cannot see the problem.
    - A separate case lets the ACP agent and ^1hcwaqy recover from this stop without the ceiling text.

    Scope of the change:
    - `.maxTokens` only when the generated count of the last call reaches the ceiling of the call. An output that ends inside the reasoning below the ceiling gets the new case.
    - `compactsAfterCeilingStop` stays for `.maxTokens` only. The new case does not compact and does not send `ceilingStopContinuationPrompt`, because its text says "cut off at the token ceiling". A compaction does not help an output that is under the trigger.
    - The log and the generation call text say what occurred (for example "ended inside the reasoning before the ceiling"), not "stopped at the token ceiling".
    - No new limit and no new constant.
    - FoundationModelsACPAgent needs a mapping for the new case. Record that as a follow-up for that repo; do not edit that repo here.
  timestamp: 2026-09-24T12:24:06.258534+00:00
- actor: claude-code
  id: 01m39p38g4ctw3sc9gqd00cdfk
  text: |-
    ## Research for option (b)

    - `FinishReason` has two cases (`completed`, `maxTokens`). It is not `Codable`. The recording keeps only the text of `GenerationCallUsage.description` (`report(generationCall:)` in `RoutedSessionActorGenerationCalls.swift`). Thus the text is the only serialization to change.
    - The only exhaustive `switch` over `FinishReason` in this repo is `GenerationCallUsage.stopDescription`.
    - `compactsAfterCeilingStop(_:)` already has `guard finishReason == .maxTokens`. A new case does not compact without a change there. Only its doc must name the new case.
    - The one log about a ceiling stop (`continueAfterCeilingStop`, CompactionYield) runs only after `compactsAfterCeilingStop` is true, thus only for `.maxTokens`. No other log writes the finish reason.
    - The DocC catalog (`FoundationModelsRouter.docc`) does not name `FinishReason`. The docs to change are the doc comments on `FinishReason`, `TokenUsage.finishReason` and `GenerationCallUsage.finishReason`.
    - Tests that expect `.maxTokens` from the `incompleteOutput` flag with a count below the ceiling: `TurnFinishReasonTests.flaggedLastResponseIsMaxTokens`, `truncatedTurnReportsMaxTokens`, `finishReasonIsPerTurn`. The probe `.truncatedInsideReasoning` sends no usage, so its count is below the ceiling. These tests change to the new case. The tests that reach the ceiling by count (`CeilingStopCompactionTests`, `CompactionRenderCounterTests`, `GenerationCallUsageTests.ceilingCallReportsMaxTokens`) stay `.maxTokens`.
    - Name of the new case: `endedInsideReasoning`. It is the name the engine uses (`result.endedInsideReasoning`).
  timestamp: 2026-09-24T12:26:26.180017+00:00
- actor: claude-code
  id: 01m39parstwcenzvbj7vbyfrdb
  text: |-
    ## Implementation of option (b)

    - `FinishReason.init(turnEntries:outputTokens:lastCallOutputTokens:responseTokenCeiling:)`: the count test comes first. When the last call spends the ceiling, the result is `.maxTokens`, also with the `incompleteOutput` flag. Otherwise the flag gives `.endedInsideReasoning`. Otherwise `.completed`.
    - A changed behavior to know: with the flag and no known count (for example a tool loop with no last-call count), the result was `.maxTokens` and is now `.endedInsideReasoning`. The decision says `.maxTokens` only when the count reaches the ceiling, so this follows the decision.
    - `GenerationCallUsage.stopDescription`: `.endedInsideReasoning` writes "ended inside the reasoning before the ceiling". This text goes to the run journal as the `generationCall` event.
    - `compactsAfterCeilingStop` was already `guard finishReason == .maxTokens`, so the code did not change there. Its doc now names the new case. The CompactionYield log line runs only after that guard, so it still says only a true ceiling stop.
    - TDD: the RED run showed 6 failures. One of them showed the defect of the run: an output that ended inside the reasoning over the trigger compacted and sent the ceiling continuation prompt. After the change all 6 pass.
    - Test helpers: `CeilingProbeLanguageModel` got the ending `truncatedInsideReasoningAtCeiling` (the flag and a usage equal to the ceiling). `CeilingStopCompactionModel` got `cutEndsInsideReasoning`. Its capabilities now declare `.reasoning`, because the cut call can send a reasoning entry.
    - Follow-up for the ACP agent: ^0g8hv5x.
  timestamp: 2026-09-24T12:30:32.250399+00:00
- actor: claude-code
  id: 01m39pawdnzfykq1y1p32698ky
  text: |-
    ### implement — changed
    - evidence: 9 files. Sources: Session/FinishReason.swift, Session/GenerationCallUsage.swift, Session/SessionEvent.swift, Session/RoutedSessionActorCompactionYield.swift. Tests: TurnFinishReasonTests.swift (+3 unit tests, +1 live test, 2 tests changed to `.endedInsideReasoning`), GenerationCallUsageTests.swift (+1), CeilingStopCompactionTests.swift (+1), Helpers/CeilingProbeLanguageModel.swift, Helpers/CeilingStopCompactionModel.swift. RED: `swift test --filter "TurnFinishReasonTests|GenerationCallUsageTests|CeilingStopCompactionTests"` gave 6 failing tests (8 issues). GREEN: the same filter with CompactionRenderCounterTests passed 44 tests in 4 suites. `swift build --build-tests`: 0 warnings from the code. `swift test`: 1344 tests in 151 suites passed (2 known issues from `withKnownIssue` in RealModelHarnessTests and BoundedWaitTests, not changed). Follow-up task ^0g8hv5x created.
    - next: /review. The task stays in doing. No commit.
  timestamp: 2026-09-24T12:30:35.957202+00:00
- actor: claude-code
  id: 01m39pe3788qm2zqa41zbn7yr1
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` — build complete, 0 errors, 0 warnings in project code (one pre-existing SwiftPM diagnostic from the third-party `mlx-swift` binary resource bundle, not our code, unchanged by this diff). `swift test` — 1344 tests in 151 suites passed (2 known issues, both from `BoundedWaitTests`, an existing test that checks the timeout-report path on purpose), plus 1 test in 1 suite passed, plus 19 tests in 3 suites passed. No failures. No skipped or disabled tests found in the test tree.
    - next: ready for review of the `^gfxd7av` diff (`FinishReason.endedInsideReasoning`, `.maxTokens` ceiling-only rule).
  timestamp: 2026-09-24T12:32:21.224736+00:00
- actor: claude-code
  id: 01m39pff0bwbzba608j3djgwcn
  text: |-
    ### commit — changed
    - evidence: b3b3d72 fix(session): label an output that ends inside the reasoning, not as a ceiling stop (^gfxd7av)
    - next: none, local commit only, no push
  timestamp: 2026-09-24T12:33:06.059081+00:00
- actor: claude-code
  id: 01m39pn63rr79wx1bqhejny0t6
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit b3b3d72). 0 findings (confirmed 0, refuted 0, attempted 7, failed 0, skipped 0). 9 files reviewed; 8 `.kanban/` files not reviewed because of `.reviewignore`. The description has no prior `## Review Findings` section.
    - next: none. The task moved to done. The ACP agent mapping is follow-up ^0g8hv5x.
  timestamp: 2026-09-24T12:36:13.560197+00:00
- actor: claude-code
  id: 01m39pnkn0qwknvxj0htxpnj4a
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 9 files; new FinishReason.endedInsideReasoning; 6 new or changed tests
    - test: green — swift test, 1344 passed, 0 failed, 0 skipped
    - commit: b3b3d72
    - review: clean — 0 findings; task in done
  timestamp: 2026-09-24T12:36:27.424887+00:00
position_column: done
position_ordinal: fffffc80
title: One generate call can generate tens of thousands of tokens before it stops at the ceiling
---
## Evidence

Transcript: `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/bench/preds.t90.transcripts/django__django-13964/01M38ATWY3RB45SQSYD5BX53P8/transcript.jsonl` (read the `generationCall` records). Model mlx-community/Qwen3.8-27B-mxfp4, window 262,144, compaction trigger 0.8. Router bbad3ce.

- There were 31 generation calls in one turn. Fed tokens went from 4,064 to 43,912. The largest real context (fed plus generated) was 59,672 tokens, 0.228 of the window. The compaction trigger (209,715 tokens) was never near.
- Two calls generated much more than the other calls. Each record says "stopped at the token ceiling":
  - seq 132: fed 20,055, generated 39,617. It ran from approximately minute 2.3 to minute 25.8 of the turn.
  - seq 225: fed 43,912, generated 12,182.
- Each of the other calls generated between 56 and 9,529 tokens.
- After seq 225, the turn ended with the stop reason `_truncated` and no edit. The run used 2,741 s of agent time and made an empty patch.

## Questions

1. Which ceiling stopped seq 132 at 39,617 tokens and seq 225 at 12,182 tokens? The two values are different, so the ceiling is not one fixed number. The window had more than 200,000 tokens of room in both calls, so the window did not stop them. Examine commit 0bb3bb5 ("send the window of the model when a call names no ceiling") and the ceiling that the ACP agent sends.
2. The fill value (`contextFill=1.877`) is the subject of ^tpsc0nf. It is a sum across the calls of an attempt. Because of it, the ceiling stop at seq 132 caused a compaction that was not necessary.
3. What must occur when one call generates this much without a tool call? Possible answers: continue after the ceiling stop, set a lower bound, or a different action. Per the rule "no invented limits", a new bound is the decision of the user.

## Status

- [x] Question 1 answered: no ceiling stopped the two calls. Each call had the ceiling 262,144 (the prompt entries seq 61 and seq 174 record `maximumResponseTokens: 262144`). Each stream ended inside its reasoning block, below the ceiling. The engine then sets `incompleteOutput`, and Router `FinishReason` reads that flag as `.maxTokens` ("stopped at the token ceiling"). See the research comment for the file:line trace.
- [x] Question 2 done by ^tpsc0nf (commit 0a19051).
- [x] Question 3 moved to ^1hcwaqy (a detector for a call that repeats itself; the user approves each default value).
- [x] Decision: option (b), recorded in the comment "Decision (orchestrator ...)". A new `FinishReason` case for an output that ends inside the reasoning before the ceiling.

## Scope of option (b)

- [x] New case `FinishReason.endedInsideReasoning`.
- [x] `.maxTokens` only when the generated count of the last call reaches the ceiling of the call. The `incompleteOutput` flag below the ceiling, or with no known count, gives `.endedInsideReasoning`.
- [x] `compactsAfterCeilingStop` stays for `.maxTokens` only. `.endedInsideReasoning` does not compact and does not send `ceilingStopContinuationPrompt` (test `CeilingStopCompactionTests.endedInsideReasoningOverTheTriggerDoesNotCompact`).
- [x] The generation call text says "ended inside the reasoning before the ceiling".
- [x] Each exhaustive `switch` over `FinishReason` and the doc comments are updated. `FinishReason` is not serialized; the recording keeps only the generation call text.
- [x] No new limit and no new constant.
- [x] Follow-up for FoundationModelsACPAgent: ^0g8hv5x.

## Source

A peer session (foundationmodelsacpagent-e5) reported this run.