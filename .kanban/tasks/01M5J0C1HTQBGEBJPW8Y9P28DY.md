---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5j0t3r10e28p499cf5zy2hv
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (abe2fe90), counts 0 findings / 0 confirmed / 0 refuted (7 validator runs attempted, 0 failed); no finding on Tests/FoundationModelsRouterTests/Helpers/SessionDirectoryEventReads.swift (next(through:)) or the atRest(_:) / event-read lines of Tests/FoundationModelsRouterTests/RouterSessionDirectoryLauncherTests.swift; no prior findings on this card.
    - next: none — moved to done
  timestamp: 2026-10-22T14:38:59.841046+00:00
position_column: done
position_ordinal: ffffffffae80
title: Fix RouterSessionDirectoryLauncherTests event-order tests that race the first turn's stateChanged (ROUTER-8 x ROUTER-9)
---
## Problem
Three tests in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryLauncherTests.swift` fail on most runs, at HEAD (10f141bf) as well as with the ^xvgffec rename:
- `startSendsExactlyOneStartedWithTheFactsOfTheRequest()` (expects `[.started(summary, ...), marker]`)
- `startWritesTheFactsALauncherDidNotCopy()` (expects `received.dropFirst() == [.factsChanged(summary), marker]`)
- `startRegistersASessionFromAnotherRouter()` (expects `[.started(summary, ...), marker]`)

Cause: the tests were written for ROUTER-8 before ROUTER-9 (0ac457bf) made the directory send `stateChanged`. `start(_:)` mails the first message, so the first turn sends `stateChanged(working)` before the test emits its marker, and the summary `start` returns can already hold `state: working` while the `started` event holds `state: idle`. Observed: `received[1]` is `stateChanged(id:, state: working, lastSummary: nil)`, not the marker; the `started` summary has `state: idle` while the returned summary has `state: working`.

## What
Make the three tests assert what ROUTER-8 owns without racing the turn: one `started` (no second `started`), its facts and `requestedByClient`, and for the broken launcher one `factsChanged` with the request facts. Compare the summaries without the work state (or read up to the marker and filter `stateChanged`). Do not weaken the "exactly one `started`" check.

## Acceptance Criteria
- [x] `swift test --filter RouterSessionDirectoryLauncherTests` passes on 10 runs in a row.
- [x] Each test still fails if `start` sends a second `started`, drops a request fact, or drops `requestedByClient`.

#session #router-api #test