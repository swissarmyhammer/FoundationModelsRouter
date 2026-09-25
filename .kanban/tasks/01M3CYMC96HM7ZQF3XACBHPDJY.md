---
assignees:
- claude-code
depends_on:
- 01M3CYK7FSPBXGC7NWD3QX0MPT
position_column: todo
position_ordinal: '9380'
title: 'Public message API: send a message, name it by MessageID, cancel with cancel()'
---
## Why

After task ^3qx0mpt, a session is a message queue with one pump. The public API still speaks of turns and of an external driver: `enqueue(prompt:)` returns a `PromptID`, a driver calls `awaitQueuedWork()` and `dispatchNextPrompt()`, and `cancelCurrentTurn()` returns `TurnCancellationResult`. The user decided on 2026-09-25 that `respond(prompt)` "is only a helper: it sends a prompt and waits for the next final answer", and that no lock and no turn is visible in the API. Breaking the consumers is acceptable (user decision 2026-09-24). Design: `generation-queue.md`, sections 5.4, 5.6 and 5.10.

## What to do

1. Add `send(_ prompt: Transcript.Prompt) async -> MessageID` and `send(_ prompt: String)`. `send` returns when the message is in the outbox. It never waits for a submission and never throws a lock or turn error, from any task, also from a tool of the same session.
2. Rename `PromptID` to `MessageID`. `pendingPrompts()` becomes `pendingMessages()`, `replace(id:prompt:)` keeps its meaning on a waiting message, and `PromptQueueDepth` becomes `MessageQueueDepth` (waiting count, and the ids of the running submission).
3. `respond(to:maxTokens:)`, `streamResponse(to:maxTokens:)` and `streamEvents(to:maxTokens:)` stay as helpers: send, then wait for (or stream until) the answer of that message.
4. Remove `dispatchNextPrompt()` and `awaitQueuedWork()`: the pump delivers each message and each settled run by itself.
5. Replace `cancelCurrentTurn() -> TurnCancellationResult` with `cancel() -> CancellationResult` (`.requested`, `.nothingToCancel`), and `cancel(id:)` / `cancelPrompt(id:)` with `cancel(message:) -> MessageCancellationResult` (`.withdrawn` for a waiting message, `.cancelledInSubmission` for a message whose submission runs, `.alreadyAnswered`).
6. Update the DocC of `RoutedSession` and the public-surface tests.

## Acceptance Criteria

- [ ] A test: `send` from a tool of the same session, during its submission, returns a `MessageID` at once, and the message is in the prompt of the next submission.
- [ ] A test: `send` on an idle session starts a submission with no other call.
- [ ] A test: `cancel(message:)` returns `.withdrawn` for a waiting message (it never reaches a prompt) and `.cancelledInSubmission` for a message whose submission runs.
- [ ] A public-surface test compiles against `send`, `MessageID`, `cancel()`, `cancel(message:)` over a plain import.
- [ ] `rg -n "dispatchNextPrompt|awaitQueuedWork|PromptID|cancelCurrentTurn|TurnCancellationResult" Sources` finds nothing.
- [ ] Full `swift test` green, 0 new warnings. #generation-queue