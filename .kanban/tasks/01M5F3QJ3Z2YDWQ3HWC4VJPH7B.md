---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m5j2y2kkff2g03caabb6zzr0
  text: 'Waits on ^2cqepsd (user decision 2026-10-22): index.md replaces session.json and facts.json. Where this card says facts.json, write the facts into the session''s index.md frontmatter instead (through the ^2cqepsd save path, best-effort and atomic).'
  timestamp: 2026-10-22T15:16:06.899148+00:00
- actor: claude-code
  id: 01m5j7qgvx82a3z72q8s4fk7xw
  text: |-
    ### gap from ^6kq5bqd (ROUTER-5 delivery rules)
    - `send` refuses an archived target through the resolver (`SessionAddressResolution.archivedReason`) and never calls the launcher for it. Today the archived state comes from `facts.json` `archivedAt` for a recorded session (RecordedSessions), and for a live session only from `SessionStateTracking.archive()`, which nothing calls yet.
    - So a live session whose facts hold `archivedAt` still reports its tracked state and a send to it is delivered. `archive(_:by:)` must call the entry's `tracking.archive()` (or take the session off the live list), and carry `archivedAt` onto index.md (^2cqepsd), so the refusal covers each archived session.
  timestamp: 2026-10-22T16:39:55.005146+00:00
depends_on:
- 01M5F3HHXA8XHWQWDZJ2CC8D3F
- 01M5F3PESH74WZB1EDN6KQ5BQD
- 01M5F3KKY94S2A8N8JCBN9FC99
- 01M5F43CQ0KR0A2E8FA8CAT9XK
- 01M5HS4PZCZH6W43MM72CQEPSD
position_column: todo
position_ordinal: '9080'
title: 'ROUTER-11: archive(_:by:) stops the turn, leaves the live list, writes archivedAt, and sends archived'
---
## Goal
`RouterSessionDirectory.archive(_:by:)` ends a session (D68, D72): it stops a running turn, removes the session from the live list, writes `archivedAt` to `facts.json`, and sends `archived(id:)`. An archived session takes no message and is never restored.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-11-archive-a-session
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.8
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 6 (`archive`), 13.3

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`, replace the provisional `archive`:
  - Unknown id: throws `unknownSession(id)`.
  - Already archived (live state or `facts.archivedAt` on disk): gives its summary again and sends no event.
  - Live session: `cancelAll()` (`Session/RoutedSession.swift`; stops a running turn as a cancel does), then `updateFacts { $0.archivedAt = now }` (ROUTER-1), then `close()` and unregister, then the state reducer's `archived` (ROUTER-9), then `archived(id:)`. Held unread messages of the session (ROUTER-5 ledger) are dropped, not mailed.
  - Recorded, not live: write `archivedAt` into its `facts.json` on disk; send `archived(id:)`. Never call the launcher.
  - `by` is the session or the user that archives: write it to the log with the session id (the audit); it is not a stored fact in ROUTER-1. There is no built-in limit; only a deny rule in the `runCode` risk check (MT-1, Multitool) can stop a model call.
- The archived refusal in `send` already comes from the resolver and the delivery card; this card adds the tests that prove it after an archive and after a restart.

## Subtasks
- [ ] Failing test first: archive a working session (a scripted model that waits); its turn ends cancelled, it is gone from the live query, and an events stream gets `archived(id:)`.
- [ ] Implement the live path, with `archivedAt` in `facts.json` and the held messages dropped.
- [ ] Implement the recorded path and the idempotent second call (no second event).
- [ ] After a restart (a new router on the same roots): the session is found only with `includesRecorded`, its state is `archived`, and `facts.json` has `archivedAt`.
- [ ] A send to it gives `refused` with the reason "archived", and the fake launcher's `restoreSession` is never called.

## Acceptance Criteria
- [ ] Archive of a working session stops its turn, removes it from the live list, writes `archivedAt`, and sends one `archived` event.
- [ ] A second archive gives the summary and sends no event.
- [ ] After a restart, the session is `archived` and appears only with `includesRecorded`.
- [ ] A later send is refused with the reason "archived", and the launcher is not called.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift`
- [ ] `swift test --filter RouterSessionDirectoryArchive` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api