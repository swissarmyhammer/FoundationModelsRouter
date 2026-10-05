---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m46mzbk1zt8e9ccbdhd9ph5m
  text: |-
    Research done.

    - MLX source (mlx-swift-lm, MLXLanguageModel.swift): the executor sends one `.updateUsage` only after the generation completes (`completionInfo`). A cancelled call throws before that point. Thus the SDK usage of a cancelled call has input 0, and output is the sum of the token counts of the emitted fragments. The `RepeatingReasoningModel` test executor does the same (no `.updateUsage`, token count 1 for each line). This agrees with the run: fill 0.031 = 8192 / 262144.
    - `recordStoppedAttempt` replaces `backend` before `finishSubmission`. `takeGenerationCall` then reads the new backend against the ledger baseline of the old backend, and gives nil. So the stopped call has no `generationCall` row, and `renderedContext` falls back to the delta of the attempt.
    - `TokenCounter.count(Transcript)` does not count `.reasoning` entries (CharacterTokenCounter and TokenizerTokenCounter both skip them).
    - `continueAfterReasoningEnd` and a ceiling stop: the attempt completes normally, the backend is not replaced before `finishSubmission`, and the MLX executor sends its usage. These paths measure the render correctly. `replaceRender(with:)` runs after `finishSubmission` and does not touch `usageState`.
    - Found: `continueAfterCompactionYield` also replaces `backend` before `finishSubmission`, but it passes `attempt.usageBefore` (the baseline of the old backend). The usage delta of that submission is then the count of the new backend minus the old baseline, which can be negative. This is not in the scope of this card. I will add a new task for it.

    Decision (the card permits it): after a watch stop, the size of the render is counted with `tokenCounter`: the count of the pass input part of the render (instructions, prompts, tool outputs) plus the count of the output text that the render keeps for the stopped pass. The stopped call is reported as a `generationCall` before the backend is replaced. When the backend reported no input for it (a cancelled MLX call), its fed tokens are the counted pass input, and the usage of the submission adds them.
  timestamp: 2026-10-05T18:24:48.225067+00:00
- actor: claude-code
  id: 01m46p29ctv7254mjeq99rzcm8
  text: |-
    Implementation landed.

    Confirmed with a real-model test (IntegrationTests, `CancelledGenerationTeardownIntegrationTests`, Llama-3.2-1B): a cancelled MLX call moves the backend usage by input 0 AND output 0. The executor sends its one `.updateUsage` only after a call completes. So the stopped call cannot be read from the backend at all. My first version reported the stopped call only when the usage moved; that passed the scripted tests (the scripted executor counts 1 token for each line) but would drop the call in production. The fix now counts each count that the backend does not report.

    What changed:
    - New `RoutedSessionActorWatchStopUsage.swift`: `WatchStopMeasure` and `measureWatchStop(_:rebuilt:render:)`. It runs before the backend is replaced. Fed tokens = `tokenCounter.count` of the rebuilt transcript up to the output of the stopped pass (`ReasoningOnlyOutput.lastPassStart(in:)`). Generated tokens = the counted text of the pass output (reasoning, response text, tool-call arguments). The backend count wins for each field when it is not zero. Render size = `tokenCounter.count` of the render that the next pass receives (after `RepeatedPartRemoval`).
    - `takeStoppedGenerationCall` in `RoutedSessionActorGenerationCalls.swift`: reports the stopped call through the same ledger bookkeeping as `takeGenerationCall` (extracted `noteEndedCall` and `generationCallUsage`). A call whose live pass ended at a `.toolCalls` entry and whose usage did not move is not reported again: the tool open already reported it (tool-call repetition check, ^dzw15st).
    - `recordStoppedAttempt` adds the counted tokens to the usage of the attempt, so `tokens.in` and `tokens.out` of the submission and of the answer include the stopped pass.
    - `finishSubmission` takes `watchStop:`. It reports the measured stopped call (it does not call `takeGenerationCall` against the replaced backend), and it sets `usageState` to the counted render. A watch stop sets the fill also when its diff has no `.response` entry (a pass that only reasoned).
    - `continueAfterReasoningEnd` and the ceiling stop: no change needed. The attempt completes, the backend is not replaced before the finish, and the MLX executor reports usage. `replaceRender(with:)` runs after the finish; the render it installs is the one that `measureWatchStop` counted.

    Note: `TokenCounter.count(Transcript)` does not count `.reasoning` entries (the chat template does not replay them). So after a reasoning stop, the fill is the counted render without the stopped reasoning. That is the counter's model of what the next pass reads.

    New task ^8szxhab: `continueAfterCompactionYield` has the same replace-before-finish shape and passes the old baseline.
  timestamp: 2026-10-05T18:43:52.858130+00:00
- actor: claude-code
  id: 01m46p2csyt1saebrem8yb1fgq
  text: |-
    ### implement — changed
    - evidence: 11 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorWatchStopUsage.swift (new), RoutedSessionActorGenerationCalls.swift, RoutedSessionActorRecording.swift, RoutedSessionActorRepetitionWatch.swift, RoutedSessionActorReasoningStop.swift; Tests/FoundationModelsRouterTests/WatchStopUsageTests.swift (new), Helpers/RepeatingReasoningModel.swift, Helpers/SessionEventCollection.swift, ReasoningTokenLimitTests.swift; IntegrationTests/.../CancelledGenerationTeardownIntegrationTests.swift. `swift test`: 1481 tests passed (2 known issues that pre-existing tests record on purpose), 23 passed, 19 passed. `swift test --package-path IntegrationTests --filter CancelledGenerationTeardownIntegrationTests`: 2 passed.
    - next: /review. The acceptance item "Tell the FoundationModelsACPAgent session" stays open for the orchestrator.
  timestamp: 2026-10-05T18:43:56.350174+00:00
- actor: claude-code
  id: 01m46p4kr050nq8z7cnkp9cna3
  text: |-
    ### test - green
    - evidence: swift test, exit 0. Run 1: 1481 tests in 186 suites passed, 2 known issues. Run 2: 23 tests in 11 suites passed. Run 3: 19 tests in 3 suites passed. 0 failures, 0 skipped.
    - note: the 2 known issues come from tests that expect an issue (RealModelHarness and BoundedWait). They are not failures.
    - note: one build line says "missing creator for mutated node" for the mlx-swift_Cmlx bundle. It comes from the SwiftPM build of a dependency. It is not a source warning.
    - next: review
  timestamp: 2026-10-05T18:45:08.992070+00:00
position_column: doing
position_ordinal: '80'
title: context.fill after a watch stop measures the stopped pass, not the render
---
## Problem

The FoundationModelsACPAgent run of 2026-10-05 logged `context.fill=0.031` for two prompts that ended with `_reasoning_limit` (run log lines 2678 and 8020):
- django__django-13710: tokens.in=144653. The last measured render was about 19,150 tokens (seq 330), so the fill must be about 0.073.
- django__django-13964: tokens.in=1233016. The last measured render was about 50,273 tokens (seq 1284), so the fill must be about 0.19.

The value 0.031 is the same for both. It is 8,192 / 262,144 (0.03125): the reasoning limit divided by the context of the session. Thus the fill very probably measures only the stopped pass and not the render. Agent task ^4wsx6t5 says that the agent reads `context.fill` from the last submission (FoundationModelsACPAgent `EventProjection.swift:326-328`). That is correct use. Router gives the value: `SessionAnswer.contextFill` and `TokenUsage.contextFill` come from the last `submissionEnded`.

## Where Router makes the value

1. `RoutedSessionActorRepetitionWatch.swift`, `recordStoppedAttempt`: the session reads the usage of the attempt. Then it replaces `backend` (`backend.replacingTranscript(...)`), and only after that it calls `finishSubmissionAndRequeueIfUnattached`. The new backend starts a usage count of its own.
2. `RoutedSessionActorRecording.swift`, `finishSubmission`, lines 53–58: `takeGenerationCall` reads the usage of the new backend minus the ledger baseline of the old backend. That gives no ended call, so the stopped call gets no `generationCall` row. Then `renderedContext = generationCallLedger?.newestCall ?? usage`. A recovery attempt has only the stopped call, so `newestCall` is nil and the fill uses `usage`, the delta of the attempt. That delta is not the size of the render.
3. The transcript confirms this: the 3 stopped passes of each instance have no `generationCall` row. The sum of the `generationCall.tokensIn` values equals `response.tokensIn` exactly. Thus the input tokens of the stopped passes are also missing from `tokens.in`. That is a second error.

Do this first: confirm with a test what `usage.input` is for a cancelled MLX call. The fill shows that the input is near 0.

## Fix

- After a watch stop (repetition or reasoning), set `usageState` to the size of the render that the next pass receives. For example, count the rebuilt render with `tokenCounter`, or add the output that the render keeps to the last measured render. Do not use the delta of the attempt.
- Report the stopped call as a `generationCall`, with its fed and generated tokens, before the backend is replaced. Then `tokens.in` and `tokens.out` include the stopped passes.
- Check the same path for `continueAfterReasoningEnd`, a ceiling stop, and `replaceRender(with:)`.

## Acceptance criteria

- [x] A test with a scripted backend that has a render of N tokens and a reasoning stop. The `contextFill` of the `submissionEnded` is the size of the render over `contextTokens`, not the stopped pass alone.
- [x] The stopped call has a `generationCall` event and journal row, and the input tokens of the stopped pass are in the usage of the answer.
- [x] The same for a repetition stop.
- [ ] Tell the FoundationModelsACPAgent session when this is done, so that ^4wsx6t5 can close.

Related: ^0dcsd3t (the recovery after a reasoning stop). Requested by the FoundationModelsACPAgent session. #router #defect #cross-repo