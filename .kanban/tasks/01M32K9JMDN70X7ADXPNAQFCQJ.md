---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m32kh9exqn3zfgtacavajjp3
  text: |-
    Research done.
    - `RejectedToolCallError` and `RejectedToolCall` are in `MLXLMCommon` (mlx-swift-lm checkout, `Libraries/MLXLMCommon/Tool/RejectedToolCall.swift`). The Router target already links `MLXLMCommon`. `rejection.detail` is always the safe `Reason.diagnosticDetail` text. `rawTextPreview` can hold sensitive values; the change must not log it or put it in the transcript.
    - The retry place is `runTurnAttempt` in `Session/RoutedSessionActorTurnExecution.swift`. The overflow recovery there records the failed attempt with `recordFailedTurn`, then calls `runTurnAttempt` again with `pendingEvents: []` and `allowOverflowRetry: false`.
    - A rejected call never becomes a `.toolCalls` entry, because the parser did not accept it. Thus a `.toolOutput` has no call entry to pair with, even when `callID` is known. The rejection goes back to the model as a short corrective note in the prompt of the retry attempt.
    - Test seam: a scripted `LanguageModel` (same shape as `ScriptedToolCallingModel`) behind the production `MLXFoundationModelsSessionBackend` and a real `LanguageModelSession`. The executor throws `RejectedToolCallError` for the first N calls and records the transcript of each call.
  timestamp: 2026-09-21T18:26:59.165599+00:00
- actor: claude-code
  id: 01m32kxsjhkqg04tq3zez77s5q
  text: |-
    Implementation landed (TDD).
    - RED: `retryAttemptSeesTheRejection` failed with the `RejectedToolCallError` that left the turn. GREEN after the change.
    - Discovery: `LanguageModelSession` keeps no entry of an attempt that throws. The first try sent only the tool-error note, and the retry transcript then did not hold the user prompt. The retry prompt is now the prompt of the failed attempt, a blank line, and the tool error. When a retry is rejected again, its prompt already holds the earlier tool error, so the model sees each rejection of the turn. The same fact means tool calls that ran inside a rejected attempt are not in the retry transcript (the overflow retry has the same property).
    - New `Session/RejectedToolCallRetry.swift`: copies only `reason`, `toolName` and `detail` from `RejectedToolCall`, never `rawTextPreview`. It builds the retry prompt and logs the retry (reason public, tool name private, no raw text). `limit = 2` retries.
    - `runTurnAttempt` takes `rejectedCallRetriesLeft`. The catch branch calls the new `recoverFailedAttempt`, which runs the rejected-call retry first and the overflow fold-and-retry second. An overflow retry keeps the rejected-call retry count, and a rejected-call retry keeps `allowOverflowRetry`.
    - The bound test `retriesStopAtTheBound` was proved able to fail: with the guard changed to `>= 0` it failed on the attempt count; the guard is back to `> 0`.
    - New test helpers: `Helpers/RejectingLanguageModel.swift` and a generic `Helpers/LiveBackendContainer.swift`. The two older containers are copies of the generic one; follow-up task ^kj1bssq moves them onto it.
    - `swift test`: 1345 tests in 144 suites passed (2 known issues that already existed), plus 1 and 83 in the other targets. The one build warning `missing creator for mutated node ... mlx-swift_Cmlx.bundle` already existed before this task and other cards track it.
    - Acceptance item 3 (FoundationModelsACPAgent `SkillTriggerTests` with Qwen3-4B) is for FoundationModelsACPAgent to run, as the card says (card ^0n045ea there).
  timestamp: 2026-09-21T18:33:48.881804+00:00
- actor: claude-code
  id: 01m32kyfq9m3zw97q28w6z9q92
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Session/RejectedToolCallRetry.swift (new), Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Tests/FoundationModelsRouterTests/RejectedToolCallRetryTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/RejectingLanguageModel.swift (new), Tests/FoundationModelsRouterTests/Helpers/LiveBackendContainer.swift (new), Tests/FoundationModelsRouterTests/AutoCompactionTests.swift (doc link only); `swift test` — 1345 tests in 144 suites passed (2 known issues that already existed), 1 test in 1 suite passed, 83 tests in 10 suites passed; 0 failures.
    - next: /review. The FoundationModelsACPAgent SkillTriggerTests check is for that project (its card ^0n045ea).
  timestamp: 2026-09-21T18:34:11.561246+00:00
- actor: claude-code
  id: 01m32mew5sq55xrp6tjj6yxrpa
  text: |-
    ### test — green
    - evidence: `swift test` at the package root — 1345 tests in 144 suites passed (2 known issues, expected), 1 test in 1 suite passed, 83 tests in 10 suites passed. 0 failures, 0 warnings, 0 skips. `swift build` clean.
    - formatter/lint: no `.swiftformat`/`.swift-format`/`.swiftlint.yml` in this repo, and the shared CI workflow (`swissarmyhammer/workflows/.github/workflows/swift-ci.yaml`) runs no format/lint gate. Ran `swiftformat` with the four stated options (`--pattern-let inline --short-optionals always --single-line-for-each convert --guard-like-if-statements convert`) scoped to the files this change touched.
    - Fixed 5 `wrapArguments` findings in the lines this change added to `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift` (the `runTurnAttempt` call in `runTurnWork`, the `recoverFailedAttempt` call and its two `runTurnAttempt` calls, and the moved `TokenBudget(...)` call).
    - Auto-formatted the 4 new files in full, because every line in each is new: `Sources/FoundationModelsRouter/Session/RejectedToolCallRetry.swift`, `Tests/FoundationModelsRouterTests/Helpers/LiveBackendContainer.swift`, `Tests/FoundationModelsRouterTests/Helpers/RejectingLanguageModel.swift`, `Tests/FoundationModelsRouterTests/RejectedToolCallRetryTests.swift`.
    - Left pre-existing `swiftformat` findings untouched in `RoutedSessionActorTurnExecution.swift` (lines outside the diff's added ranges) and in `Tests/FoundationModelsRouterTests/AutoCompactionTests.swift` (only a doc-comment line changed there), because this change did not cause them.
    - SourceKit (`sourcekit-lsp`) reports 2 stale "Cannot find 'RejectedToolCallRetry' in scope" errors on `RoutedSessionActorTurnExecution.swift`. `swift build` and `swift test` — the real compiler and test runner — both resolve the symbol with no error, and the environment already flags `sourcekit-lsp` as not properly installed for this workspace, so this is a stale index, not a real build failure.
    - next: none. Ready for review.
  timestamp: 2026-09-21T18:43:08.601980+00:00
position_column: doing
position_ordinal: '80'
title: A rejected tool call ends the whole turn instead of going back to the model
---
## What happens

When the model writes a tool call that MLX cannot parse, `MLXLanguageModel` (mlx-swift-lm, branch `stable`, `Libraries/MLXFoundationModels/MLXLanguageModel.swift`, the `.rejectedToolCall` cases) throws `RejectedToolCallError`. Router lets the error go out of the turn. The host (FoundationModelsACPAgent) then ends the turn with the stop reason `_error`. The model never sees the error, and it never gets a second try.

## Evidence

Measured on 2026-09-21 in the FoundationModelsACPAgent integration suite `SkillTriggerTests`, with `mlx-community/Qwen3-4B-Instruct-2507-4bit` and greedy decoding. Two samples end after 9 to 12 seconds with `_error`, no text and no tool call, in every run. The host log names the cause:

    failed: RejectedToolCallError(rejection: RejectedToolCall(reason: invalidArguments, format: json, ...
      rawTextPreview: "<tool_call>\n{\"name\": \"runCode\", \"arguments\": \"{ \\\"code\\\": \\\"async function ...

The `arguments` value is a JSON string, which the parser accepts, but the JSON inside it has escapes that are not valid (a regular expression in JavaScript code, inside a JSON string, inside JSON). A small model does this often, and any model can. The shipped standard model `mlx-community/Qwen3.8-27B-mxfp4` did not do it in the same samples.

## What must change

A rejected tool call must go back to the model as a tool error that says why the call was rejected (the `RejectedToolCall.reason` and, when known, the tool name), and the turn must continue, so the model can write the call again.

Suggested place: the turn loop in `Session/RoutedSessionActorTurnExecution.swift`. The overflow recovery there already catches an error, changes the conversation, and runs `runTurnAttempt` again with a flag that stops a second retry. A rejected call can use the same shape: catch `RejectedToolCallError`, add the rejection to the transcript as the answer of that call (or as a short corrective note, if a rejected call has no call id to pair), and run the attempt again. Bound the retries (for example two), so a model that rejects every time still ends the turn, and then with the rejection error as today. Do not put the raw text preview into a log: `RejectedToolCall` says it can hold sensitive argument values.

## Acceptance

- A Router test with a scripted backend that throws `RejectedToolCallError` on the first attempt and answers on the second proves: the second attempt sees the rejection in its transcript, and the turn ends normally.
- A Router test proves that the retries stop at the bound, and that the turn then fails with the rejection error.
- In FoundationModelsACPAgent, `ACP_AGENT_SKILL_TRIGGER_MODEL=mlx-community/Qwen3-4B-Instruct-2507-4bit ACP_AGENT_SKILL_TRIGGER_SAMPLES=release-notes swift test --package-path IntegrationTests --filter SkillTriggerTests` no longer ends with `_error`. (FoundationModelsACPAgent will run this check; it tracks the defect as its card ^0n045ea.)