---
assignees:
- claude-code
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
position_column: todo
position_ordinal: '8680'
title: 'ROUTER-3: The directory events() stream (started, per-session order, bufferingNewest 256; no seq, the graph wraps it in ChangeLog)'
---
## Goal
`RouterSessionDirectory.events()` gives each caller its own stream of `SessionDirectoryEvent`, with `started` for each registered session, in order for each session.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-3-session-directory
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.2 ("Events")
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md section 7 (the event stream rules 1 to 5)
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-extras.md#extras-9-endpoint-conventions (rule 9) and /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-extras.md#extras-10-change-log-and-shared-codes; TestudoApp decision D115

## ChangeLog note (decided with the Multitool session)
`SessionDirectoryEvent` carries no sequence number and no cursor. The `sessions` graph (`SessionsGraph`, MT-10, in FoundationModelsMultitool) wraps each event that it reads from `directory.events()` in the `ChangeLog<Event>` of the Extras GraphQL toolkit (EXTRAS-10), which gives the cursor (epoch plus sequence) and `at` in `ChangeLogEntry`. Router does not use `ChangeLog`, does not link GraphQL (D74, D106), and adds no `seq` field. If EXTRAS-3 lands with a seq field after all, stop and ask before you fill it.

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`, and if it helps a small new `Directory/SessionDirectoryEventFanout.swift`:
  - Each `events()` call makes a new `AsyncStream<SessionDirectoryEvent>` with `.bufferingNewest(256)`; it gets each event after the call. A slow reader loses old events, not new ones.
  - `register` (synchronous, `nonisolated`) yields `started(summary, requestedByClient: nil)` into each open continuation under the same lock that adds the entry, so `started` is first for that session and the events of one session stay in order.
  - The `started` summary is built with no `await` from `session.facts` (`nonisolated`, Mutex-backed, ROUTER-1 vend card) and the kind and parent id that `register` receives.
  - `register` takes an optional `requestedByClient: String?` (ROUTER-8 fills it from `SessionConfiguration`), so `started` carries it in the one event; no second `started` is ever sent for a session.
  - A continuation that terminates is removed.
  - An event never holds message text longer than the ROUTER-5 length limit (rule 5): note it in a doc comment; the message cards enforce it.
- The later cards add `factsChanged`, `stateChanged`, `messageDelivered` and `archived` through the same fan-out.

## Subtasks
- [ ] Failing test first: open `events()`, vend a session, and get `started` with its summary.
- [ ] Add the fan-out with `.bufferingNewest(256)`; a test that sends 300 events to a stream nobody reads and then reads it gets the newest 256.
- [ ] Two streams opened before a vend both get `started`; a stream opened after the vend does not get it.
- [ ] Order test: for one session, `started` comes before any later event of that session (use a second event kind through an internal emit to check).
- [ ] Doc comment on `events()` that states the ChangeLog rule above.

## Acceptance Criteria
- [ ] Each `events()` call gives an independent stream; each gets `started` for each session registered after the call.
- [ ] The buffer keeps the newest 256 events for a reader that does not read.
- [ ] `started` is the first event of each session on each stream.
- [ ] No `seq` or cursor field is added to any event, and Router has no `ChangeLog` use (a source search in the test target can check `ChangeLog` does not appear under `Sources/FoundationModelsRouter`).

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryEventTests.swift`
- [ ] `swift test --filter RouterSessionDirectoryEvent` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api