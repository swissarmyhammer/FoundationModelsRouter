---
position_column: todo
position_ordinal: 8c80
title: 'Session outbox: pending prompt material with ids, coalescing, auto-connected EventEmitting tools, driver wakeup'
---
## What

Give routed sessions an **outbox**: a staging area for everything that wants to enter the conversation at a future turn boundary — tool events from long-running work AND queued user prompts. This is deliberately NOT a queue of `Transcript.Entry` (entries are the record of committed turns); it holds *prompt-side material* that only becomes an entry by being sent.

**Cross-repo prerequisite (prose, not a board dependency):** requires the OperationTool events feature (`OperationEvent` / `OperationEventSink` / `EventEmittingTool`) to have landed in `/Users/wballard/github/swissarmyhammer/FoundationModelsOperationTool` — see that repo's board, `long-running` tag.

Type layering (pinned): tools post `OperationEvent`s — plain host-neutral data, no transcript types — through `OperationEventSink`. The outbox stores those events natively (coalescing operates on their typed fields). Transcript vocabulary appears in the outbox only for queued user prompts (`Transcript.Prompt`); events are converted to `Transcript.Segment`s later, at dispatch, by the injection task — events are always passengers in some Prompt, never entries or prompts of their own.

- Add a dependency on `FoundationModelsOperationTool` (lightweight; host → substrate direction — Router knows the `EventEmittingTool`/`OperationEventSink` protocols, tools never know Router).
- **Tools parameter + automatic connection (pinned — no manual connect API):** `makeSession` gains a `tools: [any Tool]` parameter (mirroring Apple's `LanguageModelSession(tools:)`), threaded through `RoutedModel.makeSession` → `LanguageModelSessionBackend` → the underlying `LanguageModelSession`, so the model can call the tools. During session construction, conformance discovery wires event emitters to this session's outbox: `for tool in tools { (tool as? any EventEmittingTool)?.connect(outbox) }`. Nobody remembers to connect — implementing the protocol IS the subscription. A tool instance connects to one sink (tool-per-session; note in design docs, do not build sink fan-out speculatively).
- `SessionOutbox` (actor), owned per `RoutedSession` (`Sources/FoundationModelsRouter/Session/RoutedSession.swift`). Two item kinds, each with a stable id assigned at enqueue:
  - **Turn-riding events** — `OperationEvent`s that will fold into whichever prompt dispatches next. The outbox conforms to `OperationEventSink`; policy: keep every `.completed`, coalesce `.progress` latest-per-`(tool, correlationID)`.
  - **Turn-starting prompts** — full `Transcript.Prompt`s (queued user messages). Never coalesced; dispatch strictly in enqueue order, one turn each. (Enqueue/edit/cancel/dispatch API is the follow-on prompt-queue task — this task lands the storage, kinds, ids, and drain primitive.)
- Drain primitive: `drainForDispatch()` returns pending events (+ optionally the next queued prompt) and marks them committed — called from inside the serial-gated chokepoint by the injection task, so drains never interleave with a concurrent turn. Committed items are gone; `pending()` returns a snapshot of what remains, per kind, with ids.
- Fork behavior: forks inherit the parent's tool list through construction, and with fresh-per-session outboxes a fork's emitting tools connect to the *fork's* outbox — decide, document, and test (propose fresh-per-session).
- Driver wakeup: an awaitable surface — `nextEvent()` and/or an `AsyncSequence` of outbox activity — so an idle app loop can start a turn when background work completes instead of polling.

Non-goal (record it): durable on-disk outbox persistence. Queued prompts are SDK types and events are Codable — both round-trippable via `TranscriptEntryMapper`/`CustomSegmentRegistry` machinery — so durability is a natural later extension; note it, don't build it.

## Acceptance Criteria
- [ ] `makeSession(tools:)` threads the tool list into the underlying `LanguageModelSession` (model can call them) AND auto-connects every `EventEmittingTool` to the session's outbox — a fake emitting tool passed in `tools:` delivers events with no explicit connect call anywhere
- [ ] A tool that does not conform to `EventEmittingTool` passes through untouched (mixed tool lists work)
- [ ] Coalescing: N `.progress` posts for one correlationID pend as 1 (the latest); interleaved `.completed` events all survive in order; queued prompts never coalesce and preserve enqueue order
- [ ] `pending()` reports items with stable ids and kinds; `drainForDispatch()` commits and empties exactly what it returns, race-free with concurrent posts
- [ ] `nextEvent()` suspends while the outbox is empty and resumes on the next post
- [ ] Fork behavior: a fork's emitting tools feed the fork's own outbox — decided, documented, tested
- [ ] Public API documented; `swift test` green

## Tests
- [ ] Unit tests in `Tests/FoundationModelsRouterTests/` — auto-connect via `makeSession(tools:)`, mixed tool lists, kind-specific policies, drain/commit semantics under concurrent post, wakeup, fork behavior
- [ ] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running