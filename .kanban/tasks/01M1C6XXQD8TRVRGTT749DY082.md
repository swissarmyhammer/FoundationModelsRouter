---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: A compaction fold drops a fact stated late in the span, because the summary bound is a content-blind prefix cut
---
## What

CI is red on `main`. The failing test is real-model, and it is finding a real product
defect rather than flaking:

```
IntegrationTests/.../CompactionSmokeIntegrationTests.swift:458
Test "a fact planted at the very end of the folded span is still in the summary the fold stores"
Expectation failed: summary.contains(Self.plantedFactValue)
```

## It is intermittent, and it is NOT caused by any recent change

Measured today, same commits, different runs:

| commit | run 1 | re-run |
|---|---|---|
| `4162da1` | pass | — |
| `475befb` | pass | **FAIL** |
| `5a8075b` | **FAIL** | **FAIL** |

`475befb` passing and then failing on a re-run of the SAME commit is the decisive
evidence. The change between `475befb` and `5a8075b` is card ^bbbkas1, which touches
one access level and adds one `ToolContext` overload — nothing in the compaction path.
So this is not a regression from that card.

## The mechanism, from the test's own comment

The test documents what card ^azd033m measured:

> The bound the stage applies to a summarizer's answer keeps a PREFIX of it, so it is
> content-blind: it keeps what the model said first and drops what it said last. On
> this fixture it cut a 330-token answer to 160 tokens — half of the answer discarded
> — and `plantedFact` stands at the very end of the span, which is where a prefix cut
> takes its loss. The model DID name the fact, twice; the fold stored neither mention.

So the model does its job and the STAGE loses the fact. Whether the run goes red
depends on where the model happens to put the mention in its answer, which is why the
same commit passes and fails.

## Why this must not be silenced

The test asserts the property a fold exists for. Its own comment states it: shrinking
a transcript is the cost a fold pays, and carrying the facts forward is what it is paid
FOR. A fold that shrank the transcript and dropped the fact has not worked.

So do NOT make CI green by relaxing this assertion, marking the test flaky, or
retrying it. It is red because the product loses information, intermittently, in the
feature whose entire purpose is not to.

## What to do

Make the summary bound content-aware instead of a prefix cut, so a fact stated late in
the model's answer survives the bound. The bound exists to cap the stored summary's
size; the defect is the strategy for choosing WHAT to drop, not that it drops.

Investigate first and record the finding before changing anything:

- Where is the bound applied? The comment points at the stage that bounds a
  summarizer's answer.
- What is the current strategy, exactly? Confirm it is a prefix keep.
- What options exist that keep the size cap? Re-prompting for a shorter answer,
  sentence-level selection, or asking the summarizer for a bounded answer in the first
  place, are three shapes. Do not pick one from this list without measuring.

## Acceptance Criteria
- [ ] A fact stated at the END of a folded span survives the fold's stored summary.
- [ ] The stored summary still respects its size bound.
- [ ] The test at CompactionSmokeIntegrationTests.swift:458 passes, unchanged. If it
      must change, say exactly why and what property it asserts afterwards.
- [ ] Run it repeatedly, not once. It passed 2 of 4 runs today, so a single green run
      proves nothing. State how many runs were made.

## Tests
- [ ] A hermetic test of the bound itself, so the property is guarded without a real
      model. The real-model test proves the end-to-end behaviour; a unit test proves
      the strategy and runs on every push.
- [ ] Run `swift test`. All tests pass.
- [ ] CI green, integration job included, over more than one run.

## Note

Found while verifying CI after ^bbbkas1 merged. The investigation that cleared
^bbbkas1 is the evidence above: re-running the predecessor commit is what separated
"my change broke it" from "this test finds a real intermittent defect". #router #compaction #defect #ci #real-model