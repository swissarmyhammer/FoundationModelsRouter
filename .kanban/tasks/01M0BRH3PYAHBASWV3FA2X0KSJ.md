---
assignees:
- claude-code
position_column: todo
position_ordinal: '9280'
title: CompactionEvalDataset says the 128-token floor costs 627 bytes; the dataset's own measured rate makes it 616
---
`Tests/FoundationModelsRouterEvals/CompactionEvalDataset.swift` states that ``Summarization/minimumSummaryTokens`` — "a floor of 128 tokens" — is what "a real model spends on roughly 627 bytes of prose".

627 does not come from any constant this target holds. The dataset's own measured rate is `compactionEvalMeasuredBytesPerToken` = `4.81`, so `128 * 4.81` is 615.68, which is 616 bytes. 627 implies a rate of 4.898.

Two other sites in the same target already use the correct rate:

- `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift`, in the body of `everySeedsFoldableSpanOutweighsARealSummary`, says "a 128-token floor a real model spends roughly 615 bytes on".
- `RealisticSummaryLengthSummarizer` computes the same product in code and its documentation states "about 616 bytes".

So one file of the target disagrees with the other two about the same number. 627 is most probably a rate measured before `compactionEvalMeasuredBytesPerToken` was fixed at 4.81.

## What to do

Read `compactionEvalMeasuredBytesPerToken` and correct the figure in `CompactionEvalDataset.swift` to agree with it. Check whether "615" and "616" should also be stated the same way, since they are the same product rounded two ways.

## Related

- `^hx1smew` — the card that found this while correcting the target's worst-case-summary documentation. It left the figure alone because it names no length directive and no bound the model was told, so it sits outside that card's sweep.
#compaction #eval #docs