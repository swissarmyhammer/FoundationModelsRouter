---
depends_on:
- 01M5ARTSQ3ZSQMRH1Z5QSTWWJ1
position_column: todo
position_ordinal: '8280'
title: Router emits PrePrompt and PostPrompt for each mail
---
## Context
This card is a Router change for the hook system that was designed in a FoundationModelsACPAgent session (2026-10-19). The user approved this change on 2026-10-19. It needs the Router card "Router holds a HookDispatcher, gives it to each session, and emits SessionStart and SessionEnd".

## What
Emit `PrePrompt` (pre, awaited) for each mail before it goes to the model, and `PostPrompt` (post) when the answer of that mail ends. Use symbol names, not line numbers.

Facts from the Router source (`Session/RoutedSessionActorPump.swift`, `RoutedSessionActorQueueing.swift`):
- `mail(_:)` and `send(_:)` are synchronous, and `mailArrived()` only calls `wakePump()`. None of them is the delivery point.
- Mail goes to the model in two places: `runAnswer(of:)` → `deliver(_:)` after `takeNextBatch`, and `takeMailJoiningTheAnswer()`, which adds mail to an answer that is already running.
- One batch can hold many mails.
- `runNextAnswer` has the rule "No suspension point between the take and the work that holds the mail". This rule keeps cancel correct.

**Approach (agreed with the user, 2026-10-19): screen the mail while it is in the queue.**
- When a `userMessage` or `agentMessage` mail is queued and the dispatcher is not empty, mark it "screening" (one more kind of hold, next to `heldMailIDs`), and run its `PrePrompt` chain in a task that the session owns.
- `takeNextBatch` and `takeMailJoiningTheAnswer` take only mail that is not screening, and stop at the first screening mail, so the queue order stays the same.
- When the chain ends: `.proceed(e)` or `.approved(e)`: put `e.text` into the mail, remove the mark, and `wakePump()`. `.blocked(reason)`: withdraw the mail from the queue with the terminal event that a withdrawn mail gets now (`cancelled`, through `emitCancelled`), and emit `PostPrompt(blocked(reason))`.
- A cancel of a mail while its chain runs withdraws the mail as now, and the result of the chain is ignored.
- Thus there is no await between the take and the work, and the cancel rule of `runNextAnswer` stays true. When the dispatcher is empty, no mail is marked, and the pump does not change.

Rules:
- `PrePrompt` only for the mail kinds that carry model input text from outside the session: `userMessage` and `agentMessage`. Not for `elicitationAnswer`, `runEvent` or `catalogChange`. One event for each mail, also in a batch.
- The model and the transcript get the replaced text. For now, approve has the same effect as proceed.
- `PostPrompt` (post) at `answered`, `answerFailed` and `cancelled` for the mail. Only a mail that got a `PrePrompt` gets a `PostPrompt`, and it gets exactly one. A blocked mail gets only `PostPrompt(blocked)`: its `cancelled` terminal event does not make a second `PostPrompt`.

## Acceptance Criteria
- [ ] A recording visitor gets `SessionStart`, `PrePrompt`, `PostPrompt(answered)` in order for one prompt.
- [ ] Two mails in one batch give two `PrePrompt` events.
- [ ] A mail that joins a running answer also gets `PrePrompt` before the model gets it.
- [ ] A block stops the delivery: the model gets no pass, the caller's prompt ends, and the visitor gets exactly one `PostPrompt`, with `blocked`.
- [ ] `runEvent` mail gets no `PostPrompt`.
- [ ] A replaced `text` is what the model and the transcript get.
- [ ] A cancel of a mail while its `PrePrompt` chain runs ends the mail as cancelled, and the model gets no pass.
- [ ] `runEvent` mail gets no `PrePrompt`.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/PromptHookTests.swift` (Swift Testing): each criterion above, with a scripted model and slow or blocking test visitors.
- [ ] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.

#hooks