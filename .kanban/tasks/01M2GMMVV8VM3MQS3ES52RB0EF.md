---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2gpkb67pgqx4jf9gryq46v7
  text: |-
    Research results:
    - Upstream MLXLanguageModel.swift sends `incompleteOutput` at 5 sites: (1) allowed-tool path when the result ended inside reasoning, (2) think-then-call phase 1 not closed, (3) required-tool guided decode `incomplete`, (4) guided schema decode `incomplete`, (5) unconstrained path only when `endedInsideReasoning`. The unconstrained path gives no metadata when the budget ends in the answer text.
    - The unconstrained path gives `maxTokens` to MLX `GenerateParameters`. The generation stops when the count is equal to `maxTokens`, and `.updateUsage` reports `generationTokenCount`. Thus a truncated answer has output tokens equal to the ceiling.
    - `Transcript.Response` has no usage of its own (SDK swiftinterface). Router only has the usage delta of the full attempt (`liveSession.usage`). In a tool loop, the SDK makes more than one executor call in one attempt, and the delta is the sum of all calls.
    - The ceiling is calculated in `respondBody` and in `streamGeneratingBody`. `finishTurn` does not know it.
    - Discovery priming adds seeded entries before the attempt. These entries are in `unrecordedTranscriptEntries()` before the `.prompt` entry of the attempt.
  timestamp: 2026-09-14T19:34:12.423540+00:00
- actor: claude-code
  id: 01m2gq3evns5d76zepqqy0684d
  text: |-
    Implementation landed.

    Decision: `FinishReason(turnEntries:outputTokens:responseTokenCeiling:)` gives `.maxTokens` when (a) the last response carries `incompleteOutput`, or (b) the ceiling is known, `tokensOut` of the attempt is equal to or more than that ceiling, and the attempt made one generation call. The attempt made more than one call when a `.toolCalls` entry follows the last `.prompt` entry. Seeded entries of discovery priming come before the prompt, so they do not count.

    Why rule (b) excludes a tool loop: the usage delta of an attempt is the sum of all executor calls in the loop. With a named ceiling of 256, a tool call of 100 tokens and an answer of 200 tokens give 300 >= 256, and the turn would report `.maxTokens` falsely. A false `.maxTokens` is also a wrong stop reason. The remaining gap (a tool loop whose last call stops in the answer text) is recorded as new task ^rhpqq34.

    The ceiling now flows as a parameter: the callers of `generate` calculate it one time with `responseTokenCeiling(requested:contextTokens:)` and pass it to `respondBody`/`streamGeneratingBody` and to `generate` -> `runTurn` -> `runTurnWork` -> `runTurnAttempt` -> `finishTurnAndRequeueIfUnattached`/`recordFailedTurn` -> `finishTurn`. I did not use a stored actor property, because the swift initialization rule forbids a stored property that a later method fills in. A `nil` ceiling (context unknown, caller named none) turns rule (b) off; the backend floor is not visible to the session.

    Tests: `CeilingProbeEnding.truncatedInAnswerText` sends part of the answer and `.updateUsage` with output equal to `maximumResponseTokens`, and no metadata. RED was seen first: 5 issues, each `finishReason → .completed`. New tests cover respond with nil and named ceiling, streamEvents with a named ceiling, and 6 unit cases for the count rule.
  timestamp: 2026-09-14T19:43:00.469436+00:00
- actor: claude-code
  id: 01m2gq3j0b79v015d6j5yqjbpr
  text: |-
    ### implement — changed
    - evidence: `swift test` — 1316 tests in 141 suites passed (2 known issues from existing withKnownIssue tests), plus 1 and 83 tests passed; TurnFinishReasonTests 16 tests passed. 8 files: Sources/FoundationModelsRouter/Session/{FinishReason,RoutedSessionActor,RoutedSessionActorGeneration,RoutedSessionActorRecording,RoutedSessionActorTurnExecution,SessionEvent}.swift, Tests/FoundationModelsRouterTests/{TurnFinishReasonTests,Helpers/CeilingProbeLanguageModel,AutoCompactionTests}.swift
    - next: /review
  timestamp: 2026-09-14T19:43:03.691963+00:00
- actor: claude-code
  id: 01m2gqmyhvbbc775pe3666w36j
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (b80e025); 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed; 9 files reviewed; 6 .kanban files not reviewed (.reviewignore).
    - next: none. The task moved to done.
  timestamp: 2026-09-14T19:52:33.595454+00:00
- actor: claude-code
  id: 01m2gqne4ytc3wher4edvky44q
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 9 files
    - test: green — swift test, 1400 passed, 0 failed, 0 skipped
    - commit: b80e025
    - review: clean — 0 findings; task in done
  timestamp: 2026-09-14T19:52:49.566235+00:00
position_column: done
position_ordinal: ffffd580
title: A turn that reaches the ceiling in its answer text reports completed
---
## The problem

Card ^thrrzpc added `TokenUsage.finishReason`. It reads the `incompleteOutput` metadata that the MLX executor sends on the response entry.

The unconstrained MLX path sends that metadata ONLY when generation stops inside a reasoning block (`endedInsideReasoning` in `MLXLanguageModel.swift`). When the model closes its thought and then runs out of tokens in the answer text, no metadata arrives. `finishReason` is then `.completed`, and the turn is again silent.

## Facts to check

- `.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/MLXLanguageModel.swift`: find each `emitMetadata(["incompleteOutput": true]` site and the condition around it.
- The ceiling of the turn is known to the session (`RoutedSessionActor.responseTokenCeiling(requested:contextTokens:)`), and `tokensOut` is known when the turn closes.

## The work

1. Decide how Router detects a truncated answer with no metadata. One candidate: `tokensOut` of the attempt is equal to or more than the ceiling the attempt gave the backend.
2. Do NOT change `Libraries/MLXFoundationModels` (upstream code).
3. Add a test with a backend that stops at the ceiling in the answer text and sends no metadata.