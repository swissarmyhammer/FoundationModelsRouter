---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
title: An async client cannot correlate prompt to turn to events, and a drained prompt is briefly uncancellable
---
Blocking work for an Agent Client Protocol style async UI. Established by read-only investigation on commit `ee5b881`. The prompt queue itself is fine — these are correlation and lifecycle gaps around it.

## What already works (do not rebuild)

`SessionOutbox.prompts` is a real user-prompt queue: FIFO, id-addressable, never coalesced (`Session/SessionOutbox.swift:92`, `:186-191`). Enqueue returns a stable `ItemID` (`RoutedSession.swift:665`), `pendingPrompts()` returns the queue in order (`:686`), and `cancel(id:)` / `replace(id:prompt:)` (`:701`, `:717`) edit a still-queued prompt and race the drain safely, returning `.alreadySent` once dispatched (`SessionOutbox.swift:195-205`, `:263-271`).

## Gap 1 — no correlation from prompt to turn to events

- `enqueue` hands back an `ItemID`, but `dispatchNextPrompt()` returns only `String?` (`RoutedSession.swift:581`); the id is consumed by `drainForDispatch()` (`SessionOutbox.swift:322`) and never surfaced again.
- No turn identity is public at all — `currentTurnId`/`lastTurnId` are private actor state (`RoutedSessionActor.swift:235-238`).
- `SessionEvent` carries no prompt or turn identifier (`Session/SessionEvent.swift:24-89`); `turnEnded` carries only `TokenUsage`.

So a client cannot say "these events belong to the prompt the user typed". Survivable while there is one stream per turn; impossible once anything interleaves.

## Gap 2 — one event sink per turn, no session-wide fan-in

`onEvent` is a per-call closure threaded through `generate` → `runTurn` → recording; it is never stored on the actor (`RoutedSessionActorTurnExecution.swift:93-98`, `:169-175`). `respond(to:)` and `dispatchNextPrompt()` pass none, so those turns derive no events at all (`RoutedSessionActorGeneration.swift:27`; `RoutedSessionActorTurnExecution.swift:710-713`). The only session-wide channel, `streamSessionEvents()`, carries one event type today. A client cannot receive one merged stream of everything happening on a session.

## Gap 3 — the drained-but-not-started window is uncancellable and unobservable

Between `drainForDispatch()` and acquiring `turnLock`, a prompt is:
- gone from `pendingPrompts()`, so `cancel(id:)` returns `.alreadySent` (`SessionOutbox.swift:200-204`);
- not yet the in-flight turn, so `cancelCurrentTurn()` returns `.noTurnInFlight` (`RoutedSessionActorTurnGating.swift:43`);
- invisible — `AsyncSemaphore.waiterCount` is internal and explicitly "not part of the gating contract" (`Concurrency/AsyncSemaphore.swift:116`).

Cancelling the enclosing `Task` does not help: gate acquisition is deliberately cancellation-immune, so the turn still takes its place in line (`AsyncSemaphore.swift:18-31`, `:28-31`; rationale at `RoutedSession.swift:355-358`). This window is real whenever another turn is running — i.e. exactly when a user is most likely to hit cancel.

## Gap 4 — two submission paths with no defined interleaving

`enqueue` + `dispatchNextPrompt` is the queue path, but nothing drains it automatically and auto-drain is a recorded non-goal (`RoutedSession.swift:563-573`). `respond`/`streamEvents` deliberately bypass the queue — `generate` calls `drainPendingEvents()`, not `drainForDispatch()`, so an ad hoc turn never dequeues a waiting prompt (`RoutedSessionActorTurnExecution.swift:109-122`; rationale `SessionOutbox.swift:287-291`). A client mixing both gets two independent orderings.

Also note ordering between concurrent callers is undefined *before* the lock: `turnLock` is strictly FIFO once reached (`AsyncSemaphore.swift:13-16`, `:57-87`), but which caller reaches it first is actor-executor scheduling, and `streamEvents` does not even await the gate on the caller's task — it spawns an unstructured `Task` that races to `beginTurn()` (`RoutedSessionActorGeneration.swift:64-78`).

## Acceptance Criteria

- [ ] A submitted prompt yields a handle that remains valid through dispatch, so a client can map prompt to turn to events
- [ ] Every `SessionEvent` carries enough identity to attribute it to its turn, and to the prompt that caused it where one exists
- [ ] A prompt can be cancelled at any point before its turn actually begins generating — the drained-but-not-started window is closed or made observable, with the chosen semantics documented
- [ ] Queue depth including drained-but-not-started work is observable, or its absence is documented as deliberate with the reason
- [ ] Ordering guarantees between the queue path and the direct `respond`/`streamEvents` path are documented, whatever they are — today they are two independent orderings and that is not written down
- [ ] Ungated `swift test` green

## Notes
- Do NOT weaken the deliberate cancellation-immunity of gate acquisition without a recorded decision — it exists so a cancelled turn cannot corrupt the queue's fairness.
- Overlaps `^zn8n9md` (detached-run events) — both touch `SessionEvent` identity; coordinate rather than redefining it twice.</description>
</invoke>
