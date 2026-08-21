---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0k6x21fpzznc75snzq2qrdh
  text: |-
    Picked up (implement). Decision from the orchestrator, recorded here so no one opens it again: carry BOTH combinations, each by a change of `probedFactIndex` on a fixture that stays. (1) `budget-cap-tool-and-owner` probes index 1 (Marcus, the finance owner) by tool instead of index 0. `db-port` and `encryption-algorithm` keep index 0 by tool. (2) `three-facts-support-escalation` probes index 1 (6 hours) instead of index 0. `three-facts-long-project-brief` keeps index 2. No fixture is added; the subset stays at seven seeds; the gated tier is not run.

    Research: the corpus `compactionEvalMeasuredBytesPerToken` is measured over is every fixture's `context` and `facts`, every acknowledgement, and every filler prompt and reply — 41 pieces, 9824 bytes. `question` and `factKeyPhrase` are NOT in that corpus, and `probedFactIndex` is an integer. So the change moves no corpus byte and the constant stays 4.79; I will verify the piece count and byte count by the doc's own method before and after the edit. `CompactionEvalSeed.build(from:)` delivers the fact at `probedFactIndex` by tool when `probedFactViaTool` is set, so (1) really makes elision act on the second fact of the head. `subsetProbesEveryPositionInTheHead` reads index 0 from any fixture; `sesame-allergy`, `db-port` and `encryption-algorithm` still probe index 0, so it stays green. No test outside the dataset names "4,200" or "2 hours" (the continuity dataset has its own copies and is not touched).
  timestamp: 2026-08-21T22:26:13.167347+00:00
- actor: claude-code
  id: 01m0k73kfvm0t8rn2geebaqfap
  text: |-
    ### implement — changed
    - evidence: TDD on `CompactionEvalRepresentativeSubsetTests`. Two bars added that read two fields together — `subsetProbesAThreeFactHeadInTheMiddleAndAtItsEnd` (head size 3 must be probed at index 1 and index 2; index 0 of three is not required, and the doc of `requiredThreeFactProbedIndices` says why) and `subsetProbesAToolDeliveredHeadAtAndAfterItsFirstFact` (a tool-delivered head probed at index 0 AND one probed after index 0). Both watched RED before the fixture change: three-fact heads probed at [0, 2]; tool-delivered heads probed at {0} only. Then `budget-cap-tool-and-owner` moved to `probedFactIndex: 1` (key phrase `Marcus`, question "Who must give written approval for a spend increase above the cap?") and `three-facts-support-escalation` moved to `probedFactIndex: 1` (key phrase `6 hours`, question "After how long does a tier-2 support ticket escalate to the on-call engineer?"). Both bars GREEN after.
    - corpus: the corpus `compactionEvalMeasuredBytesPerToken` is measured over holds contexts, facts, acknowledgements and filler prompts/replies; `question`, `factKeyPhrase` and `probedFactIndex` are not in it. Measured by the doc's own method (each piece encoded on its own, UTF-8 bytes summed) before and after the edit: 41 pieces, 9824 bytes, both times. The corpus did not move, so the constant stays 4.79 and no re-derivation was needed.
    - files: `Tests/FoundationModelsRouterEvalSupport/CompactionEvalDataset.swift` (two fixtures' probed index, key phrase and question; the table and a decision paragraph in the doc of `compactionEvalRepresentativeSubsetIDs`), `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift` (two constants and two bars in `CompactionEvalRepresentativeSubsetTests`).
    - tests: `swift test --filter 'CompactionEvalRepresentativeSubsetTests|CompactionEvalTierBarTests'` — 15 tests in 2 suites passed (10 subset bars, 5 tier bars); subset still seven seeds. Whole root `swift test` — FoundationModelsRouterTests 1032 tests in 98 suites passed (2 pre-existing known issues), FoundationModelsRouterEvals 83 tests in 10 suites passed; zero failures. The only warning is SwiftPM's pre-existing `missing creator for mutated node` on the mlx bundle, which is not from this change. `swift build --build-tests --package-path IntegrationTests` — Build complete. The gated tier was not run. No floor, no fixture count, no `compactionEvalMeasuredBytesPerToken` touched.
    - next: /review
  timestamp: 2026-08-21T22:29:47.643681+00:00
position_column: doing
position_ordinal: '80'
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

## Decision (orchestrator, 2026-08-21; do not open again)

Carry BOTH combinations, each by a change of `probedFactIndex` on a fixture that stays: `budget-cap-tool-and-owner` probes index 1 by tool (`db-port` and `encryption-algorithm` keep index 0 by tool), and `three-facts-support-escalation` probes index 1 of three (`three-facts-long-project-brief` keeps index 2). The first of a three-fact head is not carried: it is the easiest shape, and the one- and two-fact heads probe index 0 already. No fixture is added. The doc of `compactionEvalRepresentativeSubsetIDs` records this.

## Care needed

Do NOT add a fixture. The tier measured 89.0 s against a limit of 120 s on 2026-08-21, and one more seed costs about 15.9 s. Eight seeds derive a bound of 2.14 minutes, which the limit of 2 no longer covers, and `CompactionEvalTierBarTests` refuses it from the upper side.

Do NOT run the gated tier to check this. The change is to a fixture's shape, and the ungated bars hold it.

## Acceptance Criteria

- [x] A decision is made and written down: which combination the seven must carry, or why neither is carried
- [x] `CompactionEvalRepresentativeSubsetTests` holds each carried combination with a bar that reads two fields together
- [x] The subset still holds seven seeds, and `CompactionEvalTierBarTests` stays green
- [x] A plain `swift test` at the root stays green #compaction #eval #test-debt