---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Pinned chat-template date integration test fails: Muse Glimmer answers 2024-07-26'
---
Found while running `swift test --package-path IntegrationTests` for ^zetnz36 (2026-11-12).

`PinnedChatTemplateDateIntegrationTests` "a submission with no instructions answers the pinned date rather than today's" fails at PinnedChatTemplateDateIntegrationTests.swift:201: the expectation `answer == pinnedDate` does not hold, and the model reply is `2024-07-26`. The test calls `MLXFoundationModelsSessionBackend.respond` directly. It uses no routed session, no tools, and no no-op check, so the session changes of ^zetnz36 do not reach it.

Also seen: the IntegrationTests package's local Package.resolved pinned FoundationModelsDecision 229f845. That pin does not build against its Extras pin (`PooledLogitsModel` not found). Aligning the decision, extras and llamacpp pins to the root Package.resolved fixed the build.

- [ ] Find out why the pinned date does not reach the model (the template's date branch or the pin itself)
- [ ] Integration run green #bug