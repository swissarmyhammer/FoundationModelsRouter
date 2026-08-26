---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0xs27wc0xbvybxxzfqdsdzy
  text: 'Progress. I read the validator rules (55 rules, full dump). I completed the rename in Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift: TrackResult case `parked` -> `tracked`, `return .parked` -> `return .tracked`, doc prose changed to track/tracked for the registry and suspend/suspended for waiter continuations, local `let parked` -> `suspended` in resumeWaiters. A sub-agent now completes the same rename in DetachingTool.swift (with the three exempt doc spots the waitSeconds-removal tasks will delete), ToolContext.swift, RoutedSession.md, and the ~28 test files, then runs `swift build --build-tests` and `swift test`. Known compile breaks to repair: RespondRunPlaneDrainTests.swift `releaser.park(on:)` -> `releaser.track(on:)`, and the local `park` closure in TurnCancellationTests.swift -> `suspend`.'
  timestamp: 2026-08-26T00:56:01.676627+00:00
position_column: doing
position_ordinal: '80'
title: Finish the removal of the "park" vocabulary
---
## What
Complete the rename that is in progress in the working tree (~160 modified files, uncommitted). The word "park" must not occur in the code. Vocabulary:
- A run that continues in the background: "background run". The verb is "background".
- The mailbox registry action: "track". Rename `SessionMailbox.TrackResult` case `parked` to `tracked`.
- A waiter, turn, or continuation that stops and waits: "suspend", "block", or "wait" — never "park".

**Known state:** `swift build` is green, but `swift build --build-tests` FAILS — the in-flight rename missed two call sites: `Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift:159` (`BackgroundRunReleaser` has no member `park`) and `Tests/FoundationModelsRouterTests/TurnCancellationTests.swift:858` (`try await park()`). Repair these first.

Remaining "park" sites:
- `Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift` (~16), `ToolContext.swift` (~5), `DetachingTool.swift` (~31)
- `Tests/FoundationModelsRouterTests/**` (~350: prose, `let parked` locals, test names, the marker string "PARK-INSIDE-THE-FOLD")
- `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md`

**Scope exception:** in `DetachingTool.swift`, skip doc text that the waitSeconds-removal tasks delete anyway (the `waitSeconds` docs, `invalidClocks` docs, and the "A tool that must never park is mounted on " message get deleted by tasks ^19c9vv4/^bzekmfd/^1pch3ee). Rename identifiers there; do not polish doomed prose.

## Acceptance Criteria
- [ ] `swift build --build-tests` compiles.
- [ ] `rg -i '\bpark' Sources Tests` matches only the `DetachingTool.swift` doc text named in the scope exception, or nothing.
- [ ] The full test suite is green.
- [ ] The whole repaired tree is committed as one commit — the green baseline for every later task.

## Tests
- [ ] No new tests. Run `swift test`; all existing tests pass.

## Workflow
- Use `/tdd` — first make the test target compile, then run the suite, then finish the rename, then run the suite again.