---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0851vdj01vhmr11bd7jsgf7
  text: |-
    Sharpened evidence from the same run, and a second finding.

    ## The summary is an empty string, not a missing one

    `CompactionEvalFactRetentionReport.classify(summary:answer:factKeyPhrase:)` reads:

    ```swift
    if answer.localizedCaseInsensitiveContains(factKeyPhrase) { return .retained }
    guard let summary else { return .foldProducedNoSummary }
    return summary.localizedCaseInsensitiveContains(factKeyPhrase)
        ? .answerMissedFactSummaryCarriedIt
        : .summaryLostFact
    ```

    The printer renders a missing summary as a word, not as nothing:

    ```swift
    "  summary=\(finding.diagnostic.summary ?? "<none>")",
    ```

    The log prints `summary=` with nothing after it, never `summary=<none>`. So the summary is `Optional.some("")`. The fold does return a summary. That summary holds no characters.

    This confirms the token-ceiling reading. A refused or failed call would give `nil`. An empty string is what a generation gives when it stops before it writes any answer text.

    ## Second finding — the eval cannot see this fault

    The run counts read:

    ```
    counts: retained=0 answerMissedFactSummaryCarriedIt=0 summaryLostFact=19 foldProducedNoSummary=0 unrecognizedSample=0
    ```

    `foldProducedNoSummary` is 0 while every summary is empty. The `guard let summary` test catches `nil` only. An empty string passes that guard, then `"".localizedCaseInsensitiveContains(phrase)` is false, so the sample lands in `summaryLostFact`.

    The report therefore says the summarizer wrote a summary that forgot the fact. The truth is that the summarizer wrote nothing. The one bucket that names this condition stayed at zero and hid it.

    `factRetention` mean is `0.0`, not merely below the `0.9` threshold.

    ## Extra acceptance criterion

    - [ ] `CompactionEvalFactRetentionReport` puts an empty summary in `foldProducedNoSummary`, or in a case of its own. An empty summary must not be reported as a summary that lost a fact.
  timestamp: 2026-08-17T15:22:14.322477+00:00
- actor: claude-code
  id: 01m086rvnc5c03rhkd0y7b374z
  text: |-
    Implementation landed. Both parts of the defect are closed.

    ## Part 1 — the summarizer budget now has room to reason

    `Summarization` gains `reasoningTokenHeadroom` (public var, default `4096`), and every call's ceiling is now the SUM of two amounts rather than one:

    ```
    maxTokens = summaryTokenAllowance(condensing: content) + reasoningTokenHeadroom
    ```

    The old `outputTokenCeiling(condensing:)`/`maximumOutputTokens`/`outputTokenCeiling(ingesting:)` are renamed `summaryTokenAllowance(condensing:)`/`maximumSummaryTokens`/`summaryTokenAllowance(ingesting:)`, because that arithmetic now sizes the summary TEXT alone.

    ### Why a sum and not a larger fraction

    The two amounts scale with different things.

    - The summary allowance scales with the content. That is the compression a fold exists for, and `summaryTokenRatio` states it. A quarter of the span is still a quarter of the span.
    - The reasoning does NOT scale with the content. How much a model thinks before it answers is a property of the model. A fraction of a small span leaves a reasoning model no room at all; a fraction of a large span hands it more than it can use.

    So a fixed amount beside the fraction says exactly what is true. Raising the ratio, or raising `maxChunkTokens`, would have paid for the think block out of the summary budget and made a long span buy a long summary — the defect `summaryTokenRatio` was added to close.

    The bound the fold cares about is unchanged in kind: `maximumSummaryTokens` still caps the summary allowance at what a full `maxChunkTokens` earns, so the final summary of a span of ANY length stays bounded by a constant. The headroom is never summary text, and `Compactor.compact` still discards a fold that failed to shrink the transcript.

    `4096` is this repository's own measurement, not a guess: `GatedRealModelBudget.responseTokenCeiling` records that `512` leaves this model's response empty and `4096` does not. A unit test pins `Summarization().reasoningTokenHeadroom >= GatedRealModelBudget.responseTokenCeiling`, so lowering the headroom under the measured value fails the ungated suite.

    `CompactionSummarizer.summarize(_:maxTokens:)`'s contract is restated: `maxTokens` bounds the WHOLE generation, the reasoning and the answer together. A conformer passes the sum straight down.

    ## Part 2 — an empty summary is refused at the source

    New `public enum SummarizationError: Error, Equatable, LocalizedError` with `case emptySummary`.

    `Summarization.summarizeOnce(_:prompt:summarizer:)` now rejects an answer that trims to nothing. That is the ONE method every call of a fold goes through — each map call and each reduce round — so the check covers all of them with no list to keep current.

    Throwing is the right shape and not a new hazard: `RoutedSessionActor.performAutoCompaction(prompt:budget:)` already degrades a throwing summarizer tier to the flash tier, then the own-model tier, then the deterministic pipeline. An empty answer now takes that same path instead of writing a boundary that erases the folded span.

    ## Part 3 — the eval can see it

    `CompactionEvalFactRetentionClass.classify` had `guard let summary else { return .foldProducedNoSummary }`, which an empty string walks straight past. It now reads:

    ```swift
    guard let summary, CompactionEvalFactRetentionReport.carriesText(summary) else {
        return .foldProducedNoSummary
    }
    ```

    The printer wrote the summary text itself, so an empty one rendered as `summary=` with nothing after it — a line that reads as truncated rather than as a measurement. `stanza(for:)` now renders `<empty>` for it, beside the existing `<none>` for a missing one. One shared `carriesText(_:)` answers the question, so the classification and the table can never disagree.

    ## Coverage the stub tier can see

    The card is right that a stub summarizer hides the token-ceiling defect. These are the tests that do NOT depend on any model:

    - an empty summarizer answer makes the fold throw `emptySummary`
    - a whitespace-only answer does too
    - an empty answer from the REDUCE round does too (proves every call is checked, not just the map calls)
    - `Compactor.compact` reports it rather than apply the fold
    - a call's ceiling equals its allowance plus the headroom, and is strictly greater than the allowance
    - a non-default headroom reaches the call
    - the default headroom is at least `GatedRealModelBudget.responseTokenCeiling`
    - an empty summary classifies as `foldProducedNoSummary`, not `summaryLostFact`
    - a whitespace-only summary does too
    - the rendered table states `summary=<empty>`

    ## One existing test changed, and why

    `RoutedSessionCompactTests.compactFoldsWithTheSessionsOwnSummaryTokenRatio` asserted `doubledCeiling == unturnedCeiling * 2`. The ratio now sizes the ALLOWANCE, so the whole ceiling no longer doubles. The assertion reads each allowance back off the ceiling the summarizer was given (both stages carry the default headroom) and holds the same claim about the same knob. Nothing was weakened: the test still separates two live folds and still refuses to read the `minimumSummaryTokens` floor.

    Several assertions in `SummarizationStageTests` moved the same way — `ceiling - stage.reasoningTokenHeadroom < ...` in place of `ceiling < ...` — because the bound they state is on the summary text and the headroom is not summary text.
  timestamp: 2026-08-17T15:52:16.812929+00:00
- actor: claude-code
  id: 01m0882nbjxt3p0wb1p2f2cks8
  text: |-
    Gated verification — run ONCE, targeted, not repeated.

    ```
    FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests
    ```

    ## The defect this card names is GONE

    Zero samples produced an empty summary. Not one `summary=<empty>` line, and:

    ```
    counts: retained=9 answerMissedFactSummaryCarriedIt=0 summaryLostFact=0 foldProducedNoSummary=0 unrecognizedSample=0
    ```

    Against the run this card was written from — `summaryLostFact=19`, `factRetention` mean `0.0`, `summary=` empty on 19 of 19 — every completed sample now retains the fact. `factRetention` is `1.0` on all 9 samples that ran.

    The one sample whose fold was APPLIED proves the whole path end to end:

    ```
    - seed=codename class=retained factInSummary=true folded=true summarizerCalls=1 stages=ToolOutputElision,TurnTruncation,Summarization
      summary=2. Stated facts
    - the internal codename for the new feature is "Project Longbow".
    ```

    Real summary text, carrying the planted fact, from a summarizer call that used to come back empty.

    ## What the run did NOT establish, and why

    Two acceptance criteria on this card are not met by this run, and neither can be met inside this card's scope. Both are recorded as their own tasks rather than decided here.

    ### 8 of 9 folds were discarded — `^vjf3mdm`

    ```
    - seed=allergy class=retained factInSummary=false folded=false summarizerCalls=1 stages=
      summary=<none>
    ```

    `summarizerCalls=1` beside an EMPTY `stages` list is `Compactor.compact`'s shortfall exit: the summarizer ran and answered, and the fold was then discarded because `tokensAfter >= tokensBefore`.

    The guard is right. The seeds are what changed meaning. A fold trades one or two old turns for a summary entry that also carries a `CompactionSegment` of ids and counts, and on a seed this small the recency window is most of the transcript — so the margin was always thin. It only ever cleared because the stored summary held ZERO characters. Fixing the summary made the arithmetic honest.

    So `retained=9` is a pass for the wrong reason on 8 of them: the transcript came back unchanged and the resumed session answered from the original turns. `factInSummary=true` on 1 of 9, not the large majority the card asks for — because there is no summary on the other 8 to look in.

    Resizing the seeds, or teaching the eval to name a discarded fold, is a decision this card records nothing about. Filed as `^vjf3mdm`.

    ### The suite hit its 20-minute time limit at 9 of ~20 samples — `^fz49qds`

    ```
    ✘ Test "Compaction retains pre-fold facts" recorded an issue at CompactionEvaluationTests.swift:458:6: Time limit was exceeded: 1200.000 seconds
    ```

    The old ceiling is what made the suite fit, and it fit because it produced nothing: a generation that stops at 500 tokens is fast. Real reasoning plus a real answer costs real time, twice per sample. The limit did not become wrong; what it bounded became honest. Raising it, or shrinking the gated tier, is filed as `^fz49qds`.

    ### `CompactionRoundTripIntegrationTests` recall of CRIMSON-77

    Not run. The dispatching instruction narrowed gated verification to the fact-retention eval, once, and forbade the full suite. That criterion is unverified rather than failed.

    ## Blocker

    The implementation on this card is complete and green in the ungated suite. The card's last acceptance criterion — `factInSummary=true` on the large majority of seeds — cannot be reached without `^vjf3mdm`, and the dataset cannot be measured whole without `^fz49qds`. A person decides those; I am not choosing seed sizes or a time budget on this card's behalf.
  timestamp: 2026-08-17T16:15:06.610028+00:00
- actor: claude-code
  id: 01m0882zxnnj3bsqbn8rm95y6k
  text: |-
    ### implement — stuck
    - evidence: 6 files — Sources/FoundationModelsRouter/Compaction/Summarization.swift, Sources/FoundationModelsRouter/Compaction/Compactor.swift, Tests/FoundationModelsRouterEvals/CompactionEvalFactRetentionReport.swift, Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift, Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift. `swift build` complete; `swift build --build-tests -Xswiftc -warnings-as-errors` exit 0, zero errors, zero warnings; `swift test` 973 + 27 + 27 tests passed, 0 failures (1 pre-existing `withKnownIssue` in BoundedWait). 10 new ungated tests, all passing. Gated `--filter CompactionEvaluationIntegrationTests` run once: empty summaries gone (`foldProducedNoSummary=0`, `summaryLostFact=0`, no `summary=<empty>`), `factRetention` 1.0 on all 9 completed samples against 0.0 before.
    - blocker: two acceptance criteria are unreachable inside this card. `factInSummary=true` on the large majority of seeds needs `^vjf3mdm` — 8 of 9 folds are now discarded by `Compactor.compact`'s did-not-shrink guard, because the seeds are too small for a REAL summary to shrink them, and they only ever shrank because the summary was empty. Measuring the whole dataset needs `^fz49qds` — the suite hit its 20-minute limit at 9 of ~20 samples now that generations are real. `CompactionRoundTripIntegrationTests` recall of CRIMSON-77 is unverified: the dispatching instruction limited gated verification to the fact-retention eval, once.
    - next: a person decides the seed sizing (`^vjf3mdm`) and the gated time budget (`^fz49qds`); this card's own code is complete and green.
  timestamp: 2026-08-17T16:15:17.429972+00:00
- actor: claude-code
  id: 01m088nksfmh4hamrspty4gm47
  text: |-
    ### review — stuck
    - evidence: `review sha bbba644~1..bbba644` — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. Zero new findings on the code.
    - next: the code change is sound. Two acceptance criteria are not demonstrated — the `CRIMSON-77` real-model round-trip recall, and the gated eval `factRetention >= 0.9` over the seed set (9 of 19 samples completed; 8 of those 9 folds discarded by `Compactor.compact`'s did-not-shrink guard). Follow-ups `^vjf3mdm` and `^fz49qds` cover the measurement. A person must decide whether this card closes with the measurement deferred. Task stays in `review`.
  timestamp: 2026-08-17T16:25:27.599661+00:00
- actor: claude-code
  id: 01m088q586aaq1jmqyk8yvp49w
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 6 files. `reasoningTokenHeadroom` added beside the summary allowance; `SummarizationError.emptySummary` thrown from `summarizeOnce`; the eval's classifier and report corrected.
    - test: green — swift test 973 + 27 + 27, 0 failures, 10 new ungated tests
    - commit: bbba644 (breaking)
    - review: stuck — ZERO code findings over 7 validators; two acceptance criteria not demonstrated

    **The code is sound and the fix is proven.** The targeted gated run gives `foldProducedNoSummary=0`, `summaryLostFact=0`, and factRetention 1.0 on 9 of 9 completed samples, against 0.0 before. The one applied fold produced real text carrying its planted fact. The review confirmed the two properties that mattered: the summary text is still bounded by a constant regardless of span length (the `min(maximumSummaryTokens, ...)` clamp survives the rename intact), and every caller degrades safely on the new error.

    **Why the card stays open.** Two criteria are not demonstrated:

    1. `CompactionRoundTripIntegrationTests` recall of `CRIMSON-77` against the real model — no result recorded. The gated verification was deliberately limited to the fact-retention eval, once.
    2. `factInSummary=true` on the large majority of seeds, with `factRetention >= 0.9`. The run completed 9 of 19 samples, and 8 of those 9 folds were discarded by the did-not-shrink guard.

    **The reason for point 2 is the interesting part, and it is not a regression.** Fixing the empty summary made the fold arithmetic honest. Those seeds only ever "shrank" because the stored summary held zero characters — a boundary carrying nothing is smaller than the span it replaces. With a real summary, `tokensAfter >= tokensBefore` and `Compactor.compact` correctly discards the fold. The guard is right; the seeds are too small to benefit from folding. That is `^vjf3mdm`.

    The eval was measuring a fold that only appeared to work because it was broken.

    **Also worth carrying**, recorded by the review as an assessment rather than a finding: the ceiling is a hard stop on the whole generation, so a summarizer that emits no reasoning may spend the headroom on summary text — worst-case summary text goes from 500 tokens to 4596. The doc comment states it, and the did-not-shrink guard already exists for that case.

    Two follow-ups carry the rest: `^vjf3mdm` (seed sizing) and `^fz49qds` (the gated eval time limit). Whether this card closes with that measurement deferred to them is a person's decision, not one the loop should make.
  timestamp: 2026-08-17T16:26:18.246439+00:00
- actor: claude-code
  id: 01m08b5eqagzczd1x0h1ha9cgb
  text: |-
    Acceptance criterion 4 is now demonstrated. One of the two open criteria is closed.

    ## `CompactionRoundTripIntegrationTests` recall of `CRIMSON-77` passes against the real model

    The gated run made for `^wnj3ka3` covers it:

    ```
    FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter compactionRoundTrip
    [compactionRoundTrip] tokensBefore=2767 tokensAfter=2612 saved=155
    ✔ Test "contextFill climbs, compact() folds at the 0.80 trigger preserving identity,
       a post-compact turn recalls the folded fact, restore yields the checkpointed window,
       and a further turn succeeds" passed after 425.010 seconds.
    ```

    The recall assertion is `CompactionRoundTripIntegrationTests.swift:529`:

    ```swift
    #expect(recall.contains("CRIMSON-77"))
    ```

    It is inside the test that passed, so the post-fold turn did recall the folded fact from a real summary.

    Two facts qualify this evidence, and neither weakens it:

    - The fixture grew during `^wnj3ka3` (8 scripted turns, up from 6), because the old fixture measured 1633 real tokens and sat below its own 0.80 trigger. The pass is therefore against the current fixture, not the one this card was written from. It is the state of the product now.
    - `saved=155` is a small margin. The fold DID apply here — this is not the shortfall exit that discards 8 of 9 eval folds — but the margin confirms the reading on `^vjf3mdm`: a real summary shrinks a small transcript only slightly.

    ## What stays open

    Criterion 5 only: `factInSummary=true` on the large majority of seeds, with `factRetention >= 0.9`. It cannot be measured until `^vjf3mdm` (seed sizing) and `^fz49qds` (the gated time limit) are settled. That is unchanged and still needs a person.
  timestamp: 2026-08-17T17:09:03.850501+00:00
- actor: claude-code
  id: 01m0abgbh7d02vq41gjbxwtxt7
  text: |-
    Acceptance criterion 5 is **NOT met**, and this run could not test it.

    The sanctioned gated run of 2026-08-18 06:16 local, made to verify `^fm5ddk9`'s length directive, gave no measurement at all:

    ```
    FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests
    ```

    - HEAD `35a1fad`, tree clean, `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` NOT set.
    - 1800.146 s, which is the tier's own 30-minute limit. The limit was exceeded.
    - `FactRetention per-sample evidence — 0 of 7 seeds measured`
    - `unreached: 7 of 7 seeds never ran`
    - Mean `FactRetention` = `-1.0` against the `0.9` floor. `-1.0` is the value an empty sample set gives.
    - The suite FAILED with 2 issues.

    ## What that means for criterion 5

    Criterion 5 asks for `factInSummary=true` on the large majority of seeds, with `factRetention >= 0.9`.

    - `factInSummary` has no value on any seed. No sample completed, so the table printed no seed line.
    - `factRetention` is `-1.0`, which is `>= 0.9` false, but it is not a measurement of the product. It is the sentinel for zero samples.

    So the criterion is **open**, and it is open for a new reason. Before this run it was open because every fold was discarded (`^fm5ddk9`, 7 of 7 seeds at `folded=false`). Now it is open because the tier measured nothing.

    **Nothing on this card is flipped.** Criterion 5 stays unchecked. Criterion 4 (`CRIMSON-77` recall) stays as it was recorded on 2026-08-17 17:09, and this run does not touch it.

    ## The new blocker for the measurement

    `^h2xxsse` holds it: the subset tier prints nothing until it ends, so a run that hits its limit cannot say if the time went to the model load, to a summarizer call, or to an answering turn. The two runs before this one measured 7 of 7 seeds in 1644.7 s and 1685.9 s, about 235 to 240 s for each sample. This run did not finish one sample in about 7 times that time. The model was cached in full and nothing was downloaded, and the machine had 512 GB RAM with no swap in use.

    Criterion 5 cannot be judged until a gated run measures at least one seed.
  timestamp: 2026-08-18T11:53:29.895154+00:00
position_column: review
position_ordinal: '80'
title: Compaction writes an empty summary against an always-reasoning model — the summarizer budget has no room for the think block
---
Found by the gated real-model run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test` against `aff8b1b`, recorded on `^z6xdyqn`.

## What happens

Compaction folds correctly and then stores an empty summary. The gated evals show it on every seed:

```
- seed=<name> class=summaryLostFact factInSummary=false folded=true summarizerCalls=1 stages=ToolOutputElision,TurnTruncation,Summarization
  summary=
```

- 19 seeds. `folded=true` on all 19. `summarizerCalls=1` on all 19.
- `factInSummary=false` on 19 of 19.
- `summary=` is empty on 19 of 19.

The fold works. The summarizer runs. The summary holds no text.

## Why

The gated model always reasons. It writes a `<think>` block first and the answer after it. `Tests/FoundationModelsRouterTestSupport/GatedRealModelBudget.swift` measured this and records it:

> A ceiling with space for the answer alone is not sufficient. The `<think>` block uses all of it, generation stops in the middle of the reasoning, and the turn records an empty response.
> `PropagationProbeIntegrationTests` fails with `512`: its `responseContent` is empty. The same test passes with `4096`.

`Summarization` does not use that ceiling. It computes its own in `Sources/FoundationModelsRouter/Compaction/Summarization.swift`:

- `outputTokenCeiling(ingesting:)` = `max(minimumSummaryTokens, ceil(tokens * summaryTokenRatio))`
- `minimumSummaryTokens` = `128`
- `summaryTokenRatio` default `0.25`, `maxChunkTokens` default `2000`
- `maximumOutputTokens` = `outputTokenCeiling(ingesting: maxChunkTokens)` = **500**

So each summarizer call gets 500 output tokens at most, and 128 at least. The repository already measured 512 as too small for this model. The largest budget the summarizer can ask for is below the value that is known to fail.

The stub suite cannot see this. A stub summarizer returns text whatever the ceiling is.

## Scope

The budget arithmetic keeps a summary short on purpose. Do not simply delete the ceiling. The summary must stay bounded, and the model must still get room to reason. The fix must separate the two amounts: the tokens the answer may occupy, and the tokens the model spends before the answer starts.

## Acceptance Criteria

- [ ] The summarizer gives a reasoning model room for its `<think>` block and still bounds the summary text
- [ ] `Summarization` does not silently accept an empty summary — an empty summarizer answer is reported, not stored as a fold result
- [ ] A unit test covers an empty summarizer answer, so the stub tier can see this class of fault
- [ ] `CompactionRoundTripIntegrationTests` recall of `CRIMSON-77` passes against the real model
- [ ] The gated evals report `factInSummary=true` on the large majority of seeds, and `factRetention >= 0.9` passes

## Review Findings (2026-08-17 11:19)

> Scope: `review sha bbba644~1..bbba644` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 8 not reviewed.

> 8 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 8 file(s)

The engine reported zero findings. No checklist item is open against the code.

### Assessment of the code

The three points the review examined:

1. The summary text stays bounded by a constant. `outputTokenCeiling(condensing:)` is now `summaryTokenAllowance(condensing:) + reasoningTokenHeadroom`. The allowance keeps its `min(maximumSummaryTokens, ...)` clamp, so it stays at or below 500 tokens, and the headroom is a constant 4096. Every call's ceiling is therefore at or below 4596 tokens, whatever the length of the span, at every recursion depth. The bound does not grow with the span, which is the property `summaryTokenRatio` exists to hold. That property is not weakened.

2. A note on the size of that constant, not a finding. The ceiling is a hard stop on the whole generation, so a model that writes no reasoning may spend the headroom on summary text. For such a model the worst-case summary text grows from 500 tokens to 4596 tokens. The behaviour is stated in the doc comment of `reasoningTokenHeadroom`, and `Compactor.compact` discards any fold that failed to shrink the transcript, which catches the case where the larger text would do damage.

3. Every caller degrades safely. `RoutedSessionActor.performAutoCompaction(prompt:budget:)` catches an untyped `error` at the flash tier and at the own-model tier, then folds with `summarizer: nil`, which makes no model call and cannot raise this error. `SummarizationError.emptySummary` therefore degrades exactly as a summarizer that throws. The caller-driven `RoutedSessionActor.compact(prompt:budget:)` reports the error to its caller, which is what acceptance criterion 2 asks for. `Compactor.compact` throws before it applies the fold, so the session transcript and the backend are unchanged and no partial state is left.

### Acceptance criteria not yet met

The code change is sound. Two criteria are not demonstrated:

- `CompactionRoundTripIntegrationTests` recall of `CRIMSON-77` against the real model. No result for this test is recorded.
- The gated evals report `factInSummary=true` on the large majority of seeds, and `factRetention >= 0.9` passes. The targeted run completed 9 of 19 samples, and `Compactor.compact` discarded 8 of those 9 folds with its did-not-shrink guard. The seed set does not yet measure what this criterion asks for.

Follow-ups `^vjf3mdm` (seed sizing) and `^fz49qds` (eval time limit) are filed against the measurement. A person must decide whether this card closes on the code fix with the measurement deferred to those two cards. #compaction #defect #real-model