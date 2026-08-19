---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0bsersjcv5gnh7qhejdk48h
  text: |-
    ## Research — the figures, verified from source

    `Summarization.minimumSummaryTokens` is `128` (`Sources/FoundationModelsRouter/Compaction/Summarization.swift`). `compactionEvalMeasuredBytesPerToken` is `4.81`. `128 * 4.81` is `615.68`.

    `RealisticSummaryLengthSummarizer.summarize(_:maxTokens:)` rounds that product UP — `(Double(summaryTokens) * compactionEvalMeasuredBytesPerToken).rounded(.up)` — so the answer it really writes is exactly 616 bytes. 616 is therefore the product this target produces, and it is what every site should state.

    Swept the whole repository for `627`, `615` and `616` in Swift files. Three sites carry the product, and only three:

    - `Tests/FoundationModelsRouterEvals/CompactionEvalDataset.swift` — "roughly 627 bytes"; wrong.
    - `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift`, in `everySeedsFoldableSpanOutweighsARealSummary` — "roughly 615 bytes"; rounded the wrong way.
    - The same file, in `RealisticSummaryLengthSummarizer`'s own documentation — "about 616 bytes"; correct, and hedged with a word the other two do not use.

    All three become "616 bytes", each naming `compactionEvalMeasuredBytesPerToken` as the rate.
  timestamp: 2026-08-19T01:16:32.434051+00:00
- actor: claude-code
  id: 01m0bt09qwrvf63xafnebk9sn3
  text: |-
    ## Landed

    Three sites now state the same product the same way, and each names the rate it comes from.

    - `CompactionEvalDataset.swift` — "a floor of 128 tokens, which is 616 bytes of prose at ``compactionEvalMeasuredBytesPerToken``". Was "roughly 627 bytes".
    - `CompactionEvaluationTests.swift`, `everySeedsFoldableSpanOutweighsARealSummary` — "a 128-token floor that is 616 bytes at `compactionEvalMeasuredBytesPerToken`". Was "roughly 615 bytes".
    - `CompactionEvaluationTests.swift`, `RealisticSummaryLengthSummarizer` — "616 bytes". Was "about 616 bytes"; the hedge went, so no site rounds the product a second way.

    `swift test` is green. This card carries no acceptance checkboxes of its own, so none were checked.
  timestamp: 2026-08-19T01:26:06.844889+00:00
- actor: claude-code
  id: 01m0bt1ag2hx77bmmadgqc01te
  text: |-
    ### implement — changed
    - evidence: 2 files — /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterEvals/CompactionEvalDataset.swift. `swift test`: 995 + 32 + 58 = 1085 tests in 114 suites, 0 failures, 1 pre-existing known issue in `BoundedWait`. Cards `^9cw5g6n` and `^a2x0ksj`.
    - next: /review.
  timestamp: 2026-08-19T01:26:40.386835+00:00
position_column: doing
position_ordinal: '8480'
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