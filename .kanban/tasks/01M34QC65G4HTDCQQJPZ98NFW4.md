---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m358ykzx5hhppgctgpxmh74f
  text: 'Research: `settledOrder` has one reader only: `retainSettledTerminalEvent` (the eviction loop). `sweep` and `close` do not read it. `sweep` calls `retainSettledTerminalEvent` and reads `settledTerminalEvents` only. So `settledOrder` goes with the constant. The only other reader of `settledTerminalEventRetentionLimit` is the test `settledTerminalEventRetentionIsBounded` in `Tests/FoundationModelsRouterTests/SessionMailboxTests.swift`. No doc outside `.kanban/` names the bound.'
  timestamp: 2026-09-22T19:19:44.893852+00:00
- actor: claude-code
  id: 01m35900vew5td0ex45xg77aa4
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift (constant, `settledOrder` and eviction loop deleted; doc on `settledTerminalEvents` says kept for the session's lifetime), Tests/FoundationModelsRouterTests/SessionMailboxTests.swift (`settledTerminalEventRetentionIsBounded` replaced by `settledTerminalEventsAreKeptForTheSessionLifetime`: 129 settlements, then `wait` and `cancel` on the first token answer with its settled terminal). The count 129 lives in the test only.
    - next: test
  timestamp: 2026-09-22T19:20:30.830590+00:00
- actor: claude-code
  id: 01m3591q3x0cp1tt5vw4jbswwp
  text: |-
    ### test — green
    - evidence: `swift test` — 1356 tests in 145 suites passed (2 known issues are the intended `withKnownIssue` checks in BoundedWaitTests and RealModelHarnessTests), plus 1 and 83 tests in the other runners passed; 0 failed. The new test `settledTerminalEventsAreKeptForTheSessionLifetime` passed. `swift build --build-tests` and `swift build --package-path IntegrationTests --build-tests` complete with no compiler warning. The only build line is the SwiftPM note "missing creator for mutated node" on the mlx-swift_Cmlx.bundle dependency product, not on project source.
    - next: commit
  timestamp: 2026-09-22T19:21:26.397171+00:00
- actor: claude-code
  id: 01m35967k0kv75gqjqvz1w0y8r
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (c204c8d): 0 findings, 0 confirmed, 0 refuted; 7 attempted, 0 failed. No prior findings on the card. The task moved to done.
    - next: finish ledger
  timestamp: 2026-09-22T19:23:54.336218+00:00
- actor: claude-code
  id: 01m3596ejajc1smwvw3mgefbwb
  text: |-
    ### finish iteration 1 — done
    - implement: changed — Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift (constant, `settledOrder`, eviction loop deleted; doc updated), Tests/FoundationModelsRouterTests/SessionMailboxTests.swift (new test `settledTerminalEventsAreKeptForTheSessionLifetime`); `rg 'settledTerminalEventRetentionLimit|settledOrder'` outside `.kanban/` finds nothing
    - test: green — `swift test`: 1356 tests in 145 suites passed (2 intended known issues), plus 1 and 83 tests passed, 0 failed; `swift build --package-path IntegrationTests --build-tests` complete
    - commit: c204c8d
    - review: clean — none
  timestamp: 2026-09-22T19:24:01.482775+00:00
position_column: done
position_ordinal: ffffe580
title: Remove the settled terminal event retention bound in SessionMailbox
---
## Decision (from the owner, 2026-09-22)

`SessionMailbox.settledTerminalEventRetentionLimit` (128, `Hosting/SessionMailbox.swift:32`) is an invented bound and must go. A session keeps every settled terminal event for its lifetime.

## Why

The bound came from commit 8e9566f (2026-08-04) with a reason for a bound ("a session-lifetime mailbox must not grow without bound") and no reason for the number. The memory argument does not hold: each terminal holds at most `terminalDetailTailLimit` (4,096) characters, and the session's transcript is already far larger. The eviction is a correctness hole: after 128 settlements, `wait` or `cancel` on an older token answers `unknownToken`, and the model cannot tell that from a token that never existed. A long agent session reaches 128 settlements.

## Where it is used

- `SessionMailbox.swift:32`: the constant.
- `SessionMailbox.swift:73-78`: `settledTerminalEvents` and `settledOrder`, the FIFO that exists only for the eviction.
- `SessionMailbox.swift:405-412`: `retainSettledTerminalEvent`, the eviction loop.
- `Tests/FoundationModelsRouterTests/SessionMailboxTests.swift:246-`: the test `settledTerminalEventRetentionIsBounded`.

## Do this

1. Delete the constant and the eviction loop. `retainSettledTerminalEvent` stores the terminal and nothing more.
2. Delete `settledOrder` if nothing else reads it. Check `sweep` and `close` first.
3. Replace the bounded-retention test with one that settles more than 128 runs and then reads the first token's terminal through `wait` and `cancel`. Both must answer with the settled terminal.
4. Update the doc comment on `settledTerminalEvents`: kept for the session's lifetime.

## Acceptance

- `rg 'settledTerminalEventRetentionLimit|settledOrder'` finds nothing, unless `settledOrder` has another reader, in which case it stays with a doc that says why.
- The new test passes. All tests pass. #compaction #limits