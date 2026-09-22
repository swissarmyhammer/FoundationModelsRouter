---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
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