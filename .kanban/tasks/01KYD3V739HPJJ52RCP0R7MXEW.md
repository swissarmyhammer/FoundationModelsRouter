---
position_column: todo
position_ordinal: '8180'
title: Chain cancellation into in-flight turns so a client stop reaches running tool calls
---
## What

Today an ACP client pressing "stop" cannot cancel a running MCP tool call, and the break is in Router.

`plan.md` -> Turn loop states the current contract plainly: *"Cancellation is queue-side. `cancel(_:)` withdraws a still-pending queued prompt before it is ever dispatched... There is no separate 'abort an in-flight turn' primitive: a turn already handed to the model runs to completion inside the actor's isolated call, exactly like any other `async` work a caller can cancel by cancelling its own enclosing `Task`."*

That is a defensible design for prompt queueing, but it leaves a real chain broken:

```
ACP session/cancel  ->  [Router: no in-flight cancel]  ->  MCP notifications/cancelled
```

`FoundationModelsMCP` *does* propagate Swift task cancellation to protocol-level `notifications/cancelled`, and long-running MCP tool calls can now run for minutes (detached, soft-deadline model). So the downstream half works and the upstream half works; Router is the missing link.

## Work

Provide a way to cancel an **in-flight** turn, not just a queued prompt:

- An explicit API on `RoutedSession` to cancel the turn currently running, cancelling the `Task` that owns `body(composedPrompt)` so cancellation propagates into tool calls (and therefore into MCP).
- Define what the caller observes: a partial turn, a `StopReason`, and how the transcript records a cancelled turn. Recording must not be left half-written.
- Interaction with the serial gate split (see the `awaitingUser` task): cancelling a turn parked in a human wait must release/rebalance permits correctly and not leak.
- Interaction with the outbox: a cancelled turn's drained events must not be silently lost -- decide whether they requeue or are recorded as delivered.
- Keep the existing queue-side `cancel(_:)` semantics intact; this is additive, not a replacement.

Document explicitly that cancellation is **best-effort past the boundary**: MCP's `notifications/cancelled` is advisory, so a server may keep working. The honest report is "we stopped listening," not "it stopped."

## Acceptance Criteria

- [ ] An in-flight turn can be cancelled through an explicit API, and cancellation reaches tool calls executing inside the model call.
- [ ] A tool that observes `CancellationError` sees it (proving propagation past `body`).
- [ ] Queue-side `cancel(_:)` behavior is unchanged for still-pending prompts.
- [ ] Transcript/recording state after a cancelled turn is well-defined and not partially written.
- [ ] Gate permits stay balanced when cancelling a turn inside `awaitingUser`.
- [ ] The outbox rule for a cancelled turn's drained events is implemented and documented.
- [ ] Docs state that propagation past the process boundary is advisory.

## Tests

- [ ] Cancelling an in-flight turn causes a long-running tool's `await` to throw `CancellationError` -- the regression this task exists for.
- [ ] A cancelled turn leaves a consistent transcript; a subsequent turn on the same session succeeds.
- [ ] Cancelling a turn parked in `awaitingUser` leaves gate counts balanced and does not block other sessions.
- [ ] Queue-side cancellation of a pending prompt still produces no turn.
- [ ] A cancelled turn's drained outbox events follow the documented rule (requeued or recorded), asserted either way.
- [ ] Cancelling twice, or cancelling after completion, is a safe no-op.

## Workflow

- Use `/tdd` -- write failing tests first, then implement to make them pass.
