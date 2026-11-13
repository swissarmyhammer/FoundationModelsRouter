---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m797e4pfdej0w5stssp15hjc
  text: |-
    ### finish iteration 1 — clean
    - cause: the pin reached the model. The pin is `26 Jul 2024`; the failed reply `2024-07-26` is the same day in a different shape. The test compared strings. CI run 43204276958 passed the test (the reply was in the shape of the pin).
    - implement: changed — PinnedChatTemplateDateIntegrationTests.swift compares calendar days (`calendarDay(of:)` reads `d MMM yyyy` and `yyyy-MM-dd`); the answer must be the pinned day and not today.
    - test: green — `swift test --package-path IntegrationTests --filter PinnedChatTemplateDateIntegrationTests`: 2 tests in 1 suite passed after 17.828 seconds, reply `26 Jul 2024`. The `2024-07-26` reply did not repeat with the current local pins.
    - the Package.resolved mismatch of the IntegrationTests package is local only (the file is gitignored); `swift build --package-path IntegrationTests --build-tests` passed on 2026-11-12 with the current pins.
    - commit: 5c5835e4
    - review: clean — review sha HEAD~1..HEAD, 0 findings.
  timestamp: 2026-11-13T01:13:01.391795+00:00
position_column: done
position_ordinal: ffffffffff8b80
title: 'Pinned chat-template date integration test fails: Muse Glimmer answers 2024-07-26'
---
Found while running `swift test --package-path IntegrationTests` for ^zetnz36 (2026-11-12).

`PinnedChatTemplateDateIntegrationTests` "a submission with no instructions answers the pinned date rather than today's" fails at PinnedChatTemplateDateIntegrationTests.swift:201: the expectation `answer == pinnedDate` does not hold, and the model reply is `2024-07-26`. The test calls `MLXFoundationModelsSessionBackend.respond` directly. It uses no routed session, no tools, and no no-op check, so the session changes of ^zetnz36 do not reach it.

Also seen: the IntegrationTests package's local Package.resolved pinned FoundationModelsDecision 229f845. That pin does not build against its Extras pin (`PooledLogitsModel` not found). Aligning the decision, extras and llamacpp pins to the root Package.resolved fixed the build.

- [x] Find out why the pinned date does not reach the model: it reaches it; the reply `2024-07-26` is the pinned day in a different shape, and the test compared strings.
- [x] Integration run green #bug