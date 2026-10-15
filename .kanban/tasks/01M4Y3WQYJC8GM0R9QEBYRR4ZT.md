---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4ymjwaenyrvjramq91cavrq
  text: |-
    Research: Mail.promptText is the only place that makes the text of a mailed elicitation answer. ContextRenderer.promptText(delivering:followedBy:) joins it into the `.prompt` entry text when the pump delivers. A restore and ContextRenderer.context(of:) read the recorded entry text and do not call Mail.promptText again, so an old recording keeps its text. An ElicitationResponse from before the reason field decodes with reason nil (decodeIfPresent), so its text is the same. The pinned Extras (7f530ff) has `reason`, `decline(reason:)` and `cancel(reason:)`. No public API change: the new helper `reasonText(of:)` is private.

    Format (also on the card): `[answer to elicitation <ULID>] <action>: <content>`, then for a decline or a cancel with a reason: `\nreason: <reason>`. No reason gives the text as before.

    Red: the new suite ElicitationAnswerPromptTextTests ran with 2 of 4 tests failed by assertion (the decline and cancel with a reason gave only `... decline: none` / `... cancel: none`). The 2 no-reason tests passed, as expected.
  timestamp: 2026-10-15T01:59:45.742083+00:00
- actor: claude-code
  id: 01m4ymk2fwz2hdb74ztt1ff8ae
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Session/SessionMessage.swift (new private `reasonText(of:)`, appended to the elicitation answer text), Tests/FoundationModelsRouterTests/ElicitationAnswerPromptTextTests.swift (new, 4 tests). Red: 2 of 4 failed by assertion before the change. `swift build --build-tests`: Build complete, only the mlx "missing creator" line. Suite once: "Test run with 4 tests in 1 suite passed". Full suite once (`swift test --skip-build`): "Test run with 1729 tests in 209 suites passed after 6.149 seconds with 1 known issue" (the RealModelHarness embedding slot known issue, as before), "Test run with 25 tests in 13 suites passed", "Test run with 19 tests in 3 suites passed". `cd IntegrationTests && swift build --build-tests`: Build complete, only the mlx line. Not committed.
    - next: /review. The card stays in doing.
  timestamp: 2026-10-15T01:59:52.060701+00:00
- actor: claude-code
  id: 01m4ymqv4k9eedsyt6mcms34aw
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 8ede7176). 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. 2 files reviewed: Sources/FoundationModelsRouter/Session/SessionMessage.swift, Tests/FoundationModelsRouterTests/ElicitationAnswerPromptTextTests.swift. The 4 .kanban files are excluded by .reviewignore.
    - hand checks:
      - No reason: `reasonText(of:)` returns "" when `reason == nil`. Thus the text is byte-identical to the text before the change. The two no-reason tests compare against the old one-line format.
      - Recordings and restore: `ContextRenderer.promptText(delivering:followedBy:)` has two callers only, and both are live submission paths (RoutedSessionActorAnswerExecution: the first attempt and the retry prompt). `ContextRenderer.context(of:)` rebuilds the recorded `.prompt` entry text and removes the mail records. It does not call `Mail.promptText`. Extras decodes `reason` with `decodeIfPresent`, so an old recording gives `reason == nil`.
      - Reason line: the first line cannot contain a line break (ULID, action raw value, JSON with sorted keys, or `none`). Thus the first "\nreason: " always starts the reason, and the reason is all text after it. A line break or the text "reason:" in the reason cannot move that point. The cancel test uses a reason with a line break. The card format says that a line break in the reason stays.
      - Red first: the implement comment records 2 of 4 tests failed by assertion before the change (the decline and the cancel with a reason), and the 2 no-reason tests passed.
    - next: none. The card moves to done.
  timestamp: 2026-10-15T02:02:28.371060+00:00
- actor: claude-code
  id: 01m4ymrhst1a74c73mzf7qbdm1
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — reason line in the prompt text of a mailed decline or cancel
    - test: green — full suite 1729 tests in 209 suites passed; IntegrationTests build clean
    - commit: 8ede7176
    - review: clean; card in done
  timestamp: 2026-10-15T02:02:51.578349+00:00
position_column: done
position_ordinal: ffffffe680
title: Put the decline or cancel reason in the prompt text of a mailed elicitation answer
---
Do not start this task until the reviewer says so.

SessionMessage.promptText (Sources/FoundationModelsRouter/Session/SessionMessage.swift) makes the text of a mailed elicitation answer from the action and the content only. Thus a model that gets a mailed decline or cancel does not see the reason.

Change: the prompt text of a mailed elicitation answer includes the reason of a decline or a cancel (ElicitationResponse.reason, Extras task 16, Extras commit cada984), so that the model sees it. An answer with no reason gives the same text as before.

Tests: a decline with a reason, a cancel with a reason, and a decline and a cancel with no reason (the text does not change). #elicitation-phase-1

## Format

- An answer with no reason (the same text as before): `[answer to elicitation <ULID>] <action>: <content>`. `<content>` is the JSON of the content with sorted keys, or `none`.
- A decline or a cancel with a reason: the line above, then a line break, then `reason: <reason>`. The reason is the text of the user as it is (a line break in the reason stays). Example: `[answer to elicitation 01M4...] decline: none` + `\n` + `reason: I do not want to share my address.`
- An accept never has a reason (Extras makes it unrepresentable).

## Recording compatibility

- The recorded `.prompt` entry keeps its text. A restore and `ContextRenderer.context(of:)` use that recorded text. They do not call `Mail.promptText` again. Thus a recording made before this change keeps its text.
- An `ElicitationResponse` recorded before the reason field decodes with `reason == nil` (`decodeIfPresent`), so its prompt text is the same as before.

- [x] Put the reason after the first line of the text of a decline or a cancel
- [x] Tests: decline with a reason, cancel with a reason, decline with no reason, cancel with no reason