---
assignees:
- claude-code
position_column: todo
position_ordinal: 8b80
title: 'Two fold shapes are no longer measured: a three-fact head probed in the middle, and a tool-delivered head probed after the first fact'
---
Found by the review of commit `134342a` (task ^k0d30s4). It is a statement of span, not a defect of that commit.

## What happened

Task ^k0d30s4 cut `compactionEvalFixtureSpecs` from 24 fixtures to 7, because the whole-dataset gated tier could not hold the two-minute budget. The user chose to make the test smaller.

On each FIELD the dataset varies, the seven span everything the 24 spanned:

| field | the seven carry | the 17 that went carried |
|---|---|---|
| `facts.count` | 1, 2, 3 | 1, 2, 3 |
| `probedFactIndex` | 0, 1, 2 | 0, 1, 2 |
| `probedFactViaTool` | true, false | true, false |
| `recentTurnCount` | 4, 5, 6, 7 | 4, 5, 6 |

The seven carry more on the recency window, and the longest context is a fixture that stays.

## The gap

Two COMBINATIONS of those fields went away with the 17:

1. **A three-fact head probed in the middle.** The two three-fact fixtures that stay probe index 0 (`three-facts-support-escalation`) and index 2 (`three-facts-long-project-brief`). The deleted `three-facts-onboarding` probed index 1 of three. A middle fact is the hardest fact for a summary to keep, because the summarizer must reach past a fact on each side of it.
2. **A tool-delivered head probed after the first fact.** All three fixtures that stay with `probedFactViaTool: true` — `db-port`, `encryption-algorithm` and `budget-cap-tool-and-owner` — probe index 0. The deleted `config-flag-and-owner` delivered by tool and probed index 1. `ToolOutputElision` runs before `Summarization`, so this combination measures what elision does to a fact that is not the first of its head.

`CompactionEvalRepresentativeSubsetTests` cannot see either gap. Each of its bars reads ONE field on its own: a head-size set, a delivery set, and three separate position tests. A pair of fields is not held by any bar.

## Why this is worth doing

The correction costs NO time. It does not add a seed, so the tier still runs seven samples and the two-minute limit still holds. A person changes the shape of a fixture that stays, or gives a fixture that stays a second probed shape.

## Work

Decide, then do one of these:

1. Change the `probedFactIndex` of `three-facts-long-project-brief` from 2 to 1, and give the middle position to it. This loses the LAST position on a three-fact head, so check what `subsetProbesEveryPositionInTheHead` then asserts — that bar reads the whole subset, and `license-key-and-region` probes index 1 of two, so a last position must come from somewhere.
2. Change one of the three tool-delivered fixtures to probe a later fact. `budget-cap-tool-and-owner` holds two facts and probes index 0, so index 1 is available on it.
3. Decide that neither combination is worth the change, and write that decision in the doc of `compactionEvalRepresentativeSubsetIDs`, with the reason.

Then add a bar that holds the COMBINATION rather than the field, so a later edit cannot lose it in silence. For example: the subset must probe a three-fact head at each of index 0, 1 and 2, and must carry a tool-delivered head probed after index 0.

## Care needed

Do NOT add a fixture. The tier measured 89.0 s against a limit of 120 s on 2026-08-21, and one more seed costs about 15.9 s. Eight seeds derive a bound of 2.14 minutes, which the limit of 2 no longer covers, and `CompactionEvalTierBarTests` refuses it from the upper side.

Do NOT run the gated tier to check this. The change is to a fixture's shape, and the ungated bars hold it.

## Acceptance Criteria

- [ ] A decision is made and written down: which combination the seven must carry, or why neither is carried
- [ ] `CompactionEvalRepresentativeSubsetTests` holds each carried combination with a bar that reads two fields together
- [ ] The subset still holds seven seeds, and `CompactionEvalTierBarTests` stays green
- [ ] A plain `swift test` at the root stays green #compaction #eval #test-debt