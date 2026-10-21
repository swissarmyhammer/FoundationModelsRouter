---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5gb79gk2qsm814b3836zffk
  text: |-
    Implementation notes:
    - The live registry and the open streams now sit in ONE Mutex (`RouterSessionDirectory.Registry { entries, fanout }`, field `state`, which replaces the old `live` Mutex). `register` sends `started` under that same lock. The new `Directory/SessionDirectoryEventFanout.swift` holds no lock of its own; it keeps the continuations (makeStream with `.bufferingNewest(256)`, add/remove/send/count).
    - `register(_:kind:parentID:requestedByClient:)` now has `requestedByClient: String? = nil`. Existing callers (RoutedLLM.registerVendedSession, RoutedSessionActorForking, SessionTreeRestoration, RouterSessionDirectoryQueryTests) compile unchanged because of the default.
    - To make "no second `started` is ever sent for a session" hold, a second registration of an id whose entry still holds a live session replaces the entry and sends nothing. The query tests re-register vended sessions, and this rule keeps them from sending a duplicate `started`. An id that was unregistered (close()) or whose session is gone sends `started` again, so a restore of a closed session counts as a new start.
    - Internal `emit(_:)` gives the later cards (factsChanged/stateChanged/messageDelivered/archived) a way to send through the same lock. Internal `openEventStreamCount` lets a test check that a dropped stream leaves the directory. Dropping the AsyncStream runs onTermination synchronously, and the test depends on that.
    - The events() doc says "change log" in plain words and does not spell the type name. That keeps the `ChangeLog` source-scan test (which reads all of Sources/FoundationModelsRouter) true while the doc still states the rule.
    - The tests use a marker event (`.archived(id:)` through `emit`) to show that a stream holds nothing more, so no read waits on an event that never comes.
    - The build prints `warning: missing creator for mutated node: ... mlx-swift_Cmlx.bundle/Contents/MacOS`. This SwiftPM build-graph warning was there before the change (it appeared on the RED build) and comes from the mlx dependency, not from this code. The full suite reports "9 known issues", which come from existing withKnownIssue tests and not from this suite.
  timestamp: 2026-10-21T23:02:28.627280+00:00
- actor: claude-code
  id: 01m5gb7bp3g8hk9c0y86xgkewz
  text: |-
    ### implement — changed
    - evidence: 3 files. Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift (modified), Sources/FoundationModelsRouter/Directory/SessionDirectoryEventFanout.swift (new), Tests/FoundationModelsRouterTests/RouterSessionDirectoryEventTests.swift (new, 10 tests). `swift build --build-tests` built clean. `swift test --filter RouterSessionDirectory` passed 37 tests in 4 suites. The full `swift test` passed 2025 tests in 252 suites, plus 33 and 19 tests in the other test bundles.
    - next: /review
  timestamp: 2026-10-21T23:02:30.851478+00:00
- actor: claude-code
  id: 01m5gbf6b2a0ps919249a7y6vq
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (acdecb80) — 0 findings, 0 confirmed, 0 refuted; 7 files attempted, 0 failed (3 source/test files reviewed, 4 .kanban files excluded by .reviewignore)
    - next: task moved to done
  timestamp: 2026-10-21T23:06:47.522806+00:00
- actor: claude-code
  id: 01m5gbfhz4rqjc85xkmtr64wbt
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — RouterSessionDirectory.swift, SessionDirectoryEventFanout.swift (new), RouterSessionDirectoryEventTests.swift (new)
    - test: green — swift test, 2025/33/19 passed, 9 known issues
    - commit: acdecb80
    - review: clean — 0 findings
  timestamp: 2026-10-21T23:06:59.428366+00:00
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
position_column: done
position_ordinal: ffffffffa780
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
- [x] Failing test first: open `events()`, vend a session, and get `started` with its summary.
- [x] Add the fan-out with `.bufferingNewest(256)`; a test that sends 300 events to a stream nobody reads and then reads it gets the newest 256.
- [x] Two streams opened before a vend both get `started`; a stream opened after the vend does not get it.
- [x] Order test: for one session, `started` comes before any later event of that session (use a second event kind through an internal emit to check).
- [x] Doc comment on `events()` that states the ChangeLog rule above.

## Acceptance Criteria
- [x] Each `events()` call gives an independent stream; each gets `started` for each session registered after the call.
- [x] The buffer keeps the newest 256 events for a reader that does not read.
- [x] `started` is the first event of each session on each stream.
- [x] No `seq` or cursor field is added to any event, and Router has no `ChangeLog` use (a source search in the test target can check `ChangeLog` does not appear under `Sources/FoundationModelsRouter`).

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryEventTests.swift`
- [x] `swift test --filter RouterSessionDirectoryEvent` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api