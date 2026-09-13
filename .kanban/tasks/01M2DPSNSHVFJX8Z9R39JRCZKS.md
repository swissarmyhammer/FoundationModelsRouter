---
assignees:
- claude-code
position_column: done
position_ordinal: ffffd280
title: Put a short background run's result in its own handle
---
## Status

Done. The work is committed, pushed, and green. This card records work that was done in the Multitool session. That session cannot reach this board.

## Commits

- `aa1dff2` on `pool`: "feat(background): put a short run's result in its own handle".
- `c80dc68` on `main`: the same commit, cherry-picked before the pool merge was ready.
- `31f8545` on `main`: the merge of `pool` into `main`. The change is complete after the merge.
- Multitool `b6a3f97`: "feat(runcode): answer a short snippet with its own result".

## Problem

A background call gave the model a completion token. The model then used one more round trip to get the result. Most runs are short, so for those runs the handle cost more than the work. A bench analysis of the Multitool showed this waste.

## Change

1. `BackgroundTool` has two new declarations, each with a default: `inlineSettleGrace`, which is `nil` (a tool that declares nothing does not change), and `resultInstruction(forCompletionToken:)`, which uses `PendingRunEnvelope.defaultResultInstruction`.
2. `BackgroundToolRunner.launch` waits for that grace period for the run it started, in `settledEnvelope(for:awaiting:within:)`. The wait does not cancel the run and does not remove it from the mailbox.
3. `PendingRunEnvelope` has a settled condition: `pending` is false, with `outcome` and `detail`. There is one envelope and one wire form, and only the `pending` field changes what the model does. `decoded(fromRendered:)` recognizes only an exact envelope and refuses one that is partly filled.
4. `SessionOutbox` has `withdrawStagedEvents(correlationID:)` behind the new `StagedEventWithdrawing` protocol. When a run gives its result inline, it withdraws its staged events, so the model does not read the same result again before its next prompt. The journal and the host events do not change.
5. `TokenCappingTool` caps only the `detail` of a settled envelope. The completion token and the sentence stay complete.
6. `SessionMailbox.boundingDetail` is now static, so the mailbox and the runner cut a terminal with the same rule.

## Tests

- New cases in `BackgroundToolRunnerTests` and `PendingRunEnvelopeTests`.
- Two new fixtures in `ToolMountFixtures`: `InlineGraceTool` and `DefaultSentenceGraceTool`.
- The full suite on `main` passed in the Multitool session: 1263 tests in 135 suites, plus 83, with the 2 known issues that were already there. #hosting #long-running #performance