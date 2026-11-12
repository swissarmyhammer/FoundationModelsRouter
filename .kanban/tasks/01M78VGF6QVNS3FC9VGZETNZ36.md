---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m78vqy13qdwh5q3gc08hbn9f
  text: |-
    Picked up. Research:
    - checkToolCallForNoOp (Session/NoOpToolCallStop.swift) returns before the hold when hasPendingOperation() is false, so the no-op body runs and its result goes through noteToolResult -> noteToolCallProgress, which resets recoveriesSinceProgress for every distinct snippet (waiting-1, waiting-2, ...).
    - Mid-answer run completion: SessionOutbox.post(event:) stages the run mail and wakes the pump (mailArrived -> wakePump). The pump runs one answer at a time, so the mail waits in the queue. Only a continuation submission takes it (runSubmission(isContinuation: true) -> takeMailJoiningTheAnswer in RoutedSessionActorPump.swift). Nothing at a tool result delivers it: noteToolResult only checks compaction, and noteDelegationHintDue only the hint. So a model that keeps calling real tools in one submission never sees the result until the answer ends and the pump starts a new answer with settledRunDeliveryPrompt.
    - Plan for that gap: a run-mail stop at the tool result that completes a round, modeled on DelegationHintStop: record the round, run one continuation; its takeMailJoiningTheAnswer puts the mail in front of the continuation prompt.
    - Coordinator added: with nothing pending, a round of only no-op calls answers each no-op call with a fixed tool-neutral reason as its tool output, and the answer ends. The pending case stays with no trace. Edge case test: a no-op snippet that computes something.
  timestamp: 2026-11-12T21:48:39.331906+00:00
- actor: claude-code
  id: 01m78wcf2tb1qv3mhva9n1qkg2
  text: |-
    Implementation landed (TDD; every new test was RED first for the right reason):
    - NoOpToolCallStop.swift: checkToolCallForNoOp no longer returns early when nothing is pending. The no-op body never runs. After the round's real calls finish, the stop reads hasPendingOperation() and records it as NoOpToolCallStop.operationPending. continueAfterNoOpToolCallStop: a round with real calls continues as before (no-op calls removed). Only no-op calls + pending: no trace in the context, reply "" (as before). Only no-op calls + nothing pending: each no-op call gets the tool-neutral static RoutedSessionActor.noOpToolCallEndReason as its tool output, and the reply is the last .response text of the attempt (else "").
    - Recovery budget: a no-op call never runs, so noteToolCallProgress never sees it. Pinned by ConsecutiveRecoveryBudgetTests "a no-op call in the round of a repeated call does not start the count again" ([1, 2], was [1, 1]).
    - Investigation finding: before this change a run that settled mid-answer was NOT delivered with the next tool result. Its mail waited in the outbox queue, and only a continuation submission's takeMailJoiningTheAnswer (RoutedSessionActorPump.swift) or the next pump answer took it. RED test RunSettledInsideAnAnswerTests showed that the model call after the tool result did not hold the job output. Fix: new RoutedSessionActorRunMailStop.swift. noteRunMailDue() runs on the ToolResultAppendBoundary after noteDelegationHintDue. At the result that completes a round, if queued run mail can start a submission (SessionOutbox.canStartASubmission), it stops the model call and continues with runMailContinuationPrompt. That continuation takes the mail. Each mail id stops an answer at most once (runMailStoppedIds, reset in startAnswerLimits). continueAfterDelegationHint now shares continueAfterCompleteRound.
    - Changed existing test: NoOpToolCallStopTests "no pending operation and a no-op call" now expects runs == 0.
    - Environment: the IntegrationTests package's local Package.resolved (gitignored) pinned FoundationModelsDecision 229f845, which does not build against its Extras pin (missing PooledLogitsModel). I aligned its pins for decision/extras/llamacpp to the root Package.resolved. That is local state only, with a backup in the scratchpad.
    - One flaky observation: "stop, act, ..." in ConsecutiveRecoveryBudgetTests hit its 10 s stopHoldLimit once. That happened while the integration package was compiling at the same time. It passed in 0.08 s alone.
  timestamp: 2026-11-12T21:59:52.154470+00:00
- actor: claude-code
  id: 01m78xtnxq7ba6v7cwmkmw1mn6
  text: |-
    ### implement — changed
    - evidence: commit eb2a7305. Root `swift test`: 2648 tests/308 suites + 41 + 19 passed, no compiler warnings. The no-op guard refactor came after that run; the filtered rerun of NoOpToolCall|RunSettledInsideAnAnswer|ConsecutiveRecoveryBudget|DelegationHint passed 32/32. `swift test --package-path IntegrationTests`: 60 tests, 1 failure. PinnedChatTemplateDateIntegrationTests:201: the model answered 2024-07-26. That test calls the MLX backend directly and uses no session code. Filed as ^5hjddsq. The eval integration target was still running at report time.
    - Divergence from card text: the card says that with nothing pending "the context holds no trace of the no-op call". The coordinator's added requirement replaces that for a round of only no-op calls: the call stays in the context and is answered with noOpToolCallEndReason. A mixed round with nothing pending still removes the no-op call.
    - Untested guard: runMailStoppedIds (one stop per mail) only matters when a continuation cannot take the mail (a screening mail is ahead). No test reaches it.
    - next: /review
  timestamp: 2026-11-12T22:25:06.487787+00:00
- actor: claude-code
  id: 01m78xxq29cxjr6rsx654xmjbh
  text: 'Eval integration target (`swift test --package-path IntegrationTests --filter FoundationModelsRouterEvalIntegrationTests`): 1 test in 1 suite passed (69 s). The only open integration failure is ^5hjddsq, the pinned-date test, which does not touch the session code.'
  timestamp: 2026-11-12T22:26:45.961530+00:00
position_column: review
position_ordinal: '80'
title: A no-op tool call with nothing pending ends the answer instead of running forever
---
Reported by FoundationModelsACPAgent (checked24, django-14608, session 01M78T63VRWDNBWFV1EB541M5V, a double-check child).

The child gave its final text "VERDICT: PASS". Mail then woke it: the result of a background command. It ran a test (exit 0). After that it called only no-op runCode snippets: `return "waiting"`, `return "standby"`, `return "waiting for 01M78V87…"` (that command had already completed), then `return "waiting-2"` through `return "waiting-63"`. That went on for 20+ minutes at about 6 s per call, and every call "succeeded". The first two got "Nothing ran". Once the command completed, nothing was pending, so `checkToolCallForNoOp` (Sources/FoundationModelsRouter/Session/NoOpToolCallStop.swift:170) returned early at `guard await hasPendingOperation()`. The repetition watch did not fire because the literal text changed on every call.

## Rule
A no-op call (the host check `isNoOpToolCall` says so) never runs as a normal call, whether or not anything is pending.
- **Something pending:** keep the current behavior. Stop the round and let the pending result start the next submission.
- **Nothing pending:** nothing can arrive, so stop the round the same way and end the answer. The context holds no trace of the no-op call. If the round also had real calls, continue with their results, as today. If the round had only no-op calls, the answer ends; it should end with the model's last text where the attempt has one.
- **Progress:** a no-op call is never progress for the recovery budget (`recoveriesSinceProgress`, ^0jbps9v), and never resets it.

## Also investigate
The model thought 01M78V87PK35W56WDS05TB7JYY was still pending after its completion events. Check how a background run that completes in the middle of an answer reaches the model. If the completion is only delivered as mail after the answer ends, a model that never ends the answer never learns the result. In that case, deliver the completion with the next tool result of the same answer. Report what the code actually does, and pin it with a test either way.

## Subtasks
- [x] RED test: a model that keeps calling distinct no-op snippets (`waiting-1`, `waiting-2`, …) with nothing pending. The answer ends after the first such round, and no no-op body runs.
- [x] RED test: a no-op call does not reset `recoveriesSinceProgress`.
- [x] Implement the rule in NoOpToolCallStop.swift and update its docs.
- [x] Coordinator addition: with nothing pending, each no-op call of a round of only no-op calls gets `RoutedSessionActor.noOpToolCallEndReason` (tool-neutral) as its output; edge-case test with a computing snippet.
- [x] Investigate how a mid-answer run completion is delivered, and fix it with a test if it is only delivered after the answer.
- [x] Full suite green. #recovery
