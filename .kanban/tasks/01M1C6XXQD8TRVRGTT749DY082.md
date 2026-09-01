---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1d627tg9vb817dmjpbqehf1
  text: |-
    ### Investigation — the card's diagnosis is refuted

    I reproduced the failure 6 times of 6 runs. Every run printed identical fold numbers:

    ```
    [compactionSmoke] summarizerCalls=1 ceilings=[617] answerTokens=[586] spanTokens=643
                      summaryTokens=586 tokensBefore=713 tokensAfter=656
                      stages=["ToolOutputElision", "TurnTruncation", "Summarization"]
    ```

    `answerTokens=586` and `summaryTokens=586` are equal. The stored summary IS the
    model's answer, word for word. No cut fired. The condense re-ask did not fire.
    The summary bound is not the cause.

    The real cause is the model's own answer. It degenerated into a repetition loop,
    and the loop copies the compaction prompt's own illustration:

    ```
    1. Intent - The user's request to replace the ingest path for the station archive...
    2. Stated facts - Every concrete fact mentioned in the conversation, with its exact value:
    - The staging database port is 6432.
    - The user stated the staging database port.
    - The staging database port is 6432.
       ... the same line 60 more times
    ```

    "The staging database port is 6432" appears nowhere in the fixture. It is the
    example inside `CompactionPrompt.default`:

    > "The staging database port is 6432" is a kept fact; "the user stated the
    > staging database port" is that fact lost.

    The model wrote BOTH halves of that example, then looped the first half. So the
    answer holds no fact from the span at all, and the fold stored it.

    Two product defects, and both are real:

    1. `CompactionPrompt.default` states "State only facts from the conversation —
       never invent". The next paragraph then hands the model an invented,
       fact-shaped sentence. Section 2 carries a second such pair, the spare-toner
       example. A small model copies them into the summary.
    2. `Summarization` has no guard against a degenerate answer. It checks that the
       answer is not empty, and it checks the answer's size. A summary of 60
       identical lines passes both checks, so the fold reports success and the
       transcript loses everything.

    The failure is deterministic on this box, not intermittent. Sampling is greedy.
    The earlier pass/fail table was measured under a different state.

    ### ^bqj719z is NOT a duplicate

    `^bqj719z` is a turn-cancellation test at `TurnCancellationTests.swift:950`. A
    bounded spin gives up before the tool observes the cancellation. It shares no
    code with the compaction fold. It stays open as its own card.
  timestamp: 2026-09-01T00:31:49.584121+00:00
- actor: claude-code
  id: 01m1d8p3chxjy3xnv112xkrhnp
  text: |-
    ### What I changed, and why

    The card asked for a content-aware summary bound. The bound was not the cause,
    so I fixed what was. Two defects, and both are needed — I measured each alone
    and neither alone makes the test pass.

    **1. `CompactionPrompt.default` quoted example facts.** The instructions said
    "State only facts from the conversation — never invent". The next paragraph
    then handed the model an invented, fact-shaped sentence, and section 2 carried
    a second such pair. The model copied one of them 60 times. The prompt now
    states every rule in the abstract and quotes nothing, and it forbids the copy
    outright: "These instructions state no facts of their own: never copy a phrase
    out of them into the summary, and never write a line you have already written."
    The name goes to `router-default-v4`, because the name exists so a recorded
    fold can be attributed to the prompt that made it.

    Measured alone: the answer stopped naming the invented value, and it still
    looped on a line of its own. Test still red.

    **2. `Summarization` had no guard on answer quality, and no framing.**

    - The assembled prompt ran the instructions and the conversation together
      behind a bare `---`. The model summarized the INSTRUCTIONS: its answer read
      "1. Intent - The user's request to compact an agent conversation into a
      continuation summary", then invented "John Smith, Jane Doe" and
      "agent-123". `contentFramingDirective` now names the content as the
      conversation, and as data rather than instructions.
    - The stage checked only that an answer was not empty and not too large. A
      summary of 60 identical lines passed both. `isRepetitive(_:)` now judges the
      answer, and a loop earns one re-ask that states the question again. A second
      loop is stored with its repeated lines removed, so the repeats occupy none of
      the stored summary's byte budget. The stage never asks a third time.

    Measured alone (framing, no guard): still red. Together: green.

    Lines compare under `normalizedLine(_:)`, which drops a leading list marker.
    The real model's second loop wrote "24. User: …", "25. User: …", so no two
    lines were byte-identical; comparing under the marker is what sees one line
    written fifty times.

    ### The reproduction, and the bar

    Before: `swift test --package-path IntegrationTests --filter
    aPlantedFactLateInTheSpanSurvivesTheFold` failed **6 of 6** runs, with
    identical fold numbers every run. Greedy decoding makes the failure
    deterministic on this box, not intermittent — commit `2e07e98` pinned greedy,
    and greedy is what makes a small model loop.

    After: the smoke suite passed **10 of 10** consecutive runs, and 3 more after
    the final doc edit — 13 of 13. Every run reported the same numbers:

    ```
    summarizerCalls=2 ceilings=[617, 617] answerTokens=[671, 517] spanTokens=643
    summaryTokens=517 tokensBefore=713 tokensAfter=587
    ```

    Two calls: the map call, then the repetition re-ask. The re-asked answer of 517
    tokens sits inside the folded span's byte budget, so no condense call fired and
    no cut fired. The stored summary is the model's answer word for word, and it
    carries `Kestrel`.

    ### The test at :458

    The assertion is unchanged, word for word. Its explanatory comment above it is
    not: it stated the prefix-cut mechanism as fact, and I measured that mechanism
    absent from this failure. The comment now records both mechanisms and which
    task measured each. A comment that states a disproved cause is worse than none.

    The sibling test keeps its `(1...2)` call bound. The ladder now has two
    recovery rungs, so three calls are reachable in general, but this fixture takes
    two, and the tighter bound is the stronger test. Its comment states what a
    third call would now mean.

    ### Also found

    The whole integration package failed one unrelated test — a real-model backend
    test exceeded its 120-second limit after 348 seconds. Raised as ^echfvpm. Every
    compaction suite of that same run passed.

    `HumanWaitGateTests` failed once under full-suite load at
    `BoundedWait.swift:114`, then passed 3 of 3 alone and 4 of 4 in later full
    runs. That file has uncommitted changes from other work in this tree.

    ### Test counts

    `swift test`: 1142 tests in 126 suites passed, 83 tests in 10 suites passed, 2
    known issues. The baseline was 1136; the six added tests are the hermetic guard
    the card asked for.
  timestamp: 2026-09-01T01:17:37.553174+00:00
- actor: claude-code
  id: 01m1d8q44qw9exz9qex4btc5tv
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift, Sources/FoundationModelsRouter/Compaction/Summarization.swift, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift, compaction_plan.md. Reproduction: `swift test --package-path IntegrationTests --filter aPlantedFactLateInTheSpanSurvivesTheFold` failed 6 of 6 before, passed 13 of 13 after. `swift test`: 1142 tests in 126 suites passed, 83 tests in 10 suites passed, 2 known issues.
    - next: /review
  timestamp: 2026-09-01T01:18:11.095966+00:00
- actor: claude-code
  id: 01m1d98b1syfhh3fx5cgbsm6vp
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 380164c). 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. I ran the reproduction myself, 5 times of 5 runs. All 5 passed. Every run printed the same fold line: `summarizerCalls=2 ceilings=[617, 617] answerTokens=[671, 517] spanTokens=643 summaryTokens=517 tokensBefore=713 tokensAfter=587`.
    - next: none. The card moves to `done`.

    ### The refutation holds

    I checked the refutation against the code and the fixture. It is sound.

    - The old numbers gave `answerTokens=586` and `summaryTokens=586`, with one call. Equal counts prove the fold stored the answer word for word.
    - 586 tokens sit under the 643-token span budget. So `resolveOversizedSummary` never ran, and no cut fired.
    - The string `6432` appears nowhere under `IntegrationTests`. The looped line came from the prompt, not the fixture.
    - The v3 prompt did quote that line. The diff removes it from `CompactionPrompt.swift`.

    ### The four checks the review asked for

    1. **The heuristic cannot misfire.** `isRepetitive` needs 4 content lines, and more than half must repeat. The 8-section scaffold writes 8 distinct headers. Even a scaffold that answers "None." in every section reaches 0.44. The test `aShortAnswerThatRepeatsALineIsNotALoop` guards the floor.
    2. **The re-ask cannot loop.** `resolveRepetitiveSummary` calls `summarizer.summarize` directly. It never calls `summarizeOnce`. So each `summarizeOnce` costs 2 model calls at most.
    3. **The name bump is complete.** Only 2 places read the literal name, and both now read `router-default-v4`. Every other place reads `CompactionPrompt.default.name`. A stored recording holds its own prompt name and text. No code compares that name to the default, so an old transcript still loads.
    4. **No test lost strength.** The unit tests deleted 3 code lines: two name literals and one expected-prompt string. All three were updated, not removed. The integration test deleted comments and one message string. The assertion `summary.contains(Self.plantedFactValue)` is unchanged. The `(1...2)` call bound is unchanged. Nobody skipped, disabled, or relaxed a test.

    ### One item stays open

    The acceptance list still holds `- [ ] CI green, integration job included, over more than one run`. That item needs the CI run, not this review.
  timestamp: 2026-09-01T01:27:35.225144+00:00
- actor: claude-code
  id: 01m1d99bwpezvn2ckbp6ch7sqb
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files. The card's own diagnosis was refuted by measurement.
    - test: green — swift test, 1142 tests in 126 suites + 83 tests in 10 suites, exit 0
    - commit: 380164c
    - review: clean — 0 findings, 7 validators, 0 failed. Task moved to done.

    The reproduction, run twice by two agents: the integration test failed 6 of 6
    runs before the change. It passed 13 of 13 for the implementer and 5 of 5 for
    the reviewer, with identical fold numbers on every run.

    Correction for the record. This card said a content-blind prefix cut dropped a
    fact stated late in the span. That is wrong. No cut fired at all: the fold made
    one call and stored the answer word for word, `answerTokens=586` and
    `summaryTokens=586`, both under the 643-token span budget.

    The card also called the failure intermittent. It is not. Commit `2e07e98`
    pinned greedy decoding, which makes the loop deterministic.

    The real cause: the 1B model degenerated into a repetition loop, and the loop
    copied an example fact out of the compaction prompt itself. The prompt told the
    model to state only facts from the conversation, then quoted an invented
    fact-shaped sentence. The model wrote that sentence 60 times. The value appears
    nowhere in the fixture.

    Both defects needed a fix. Neither alone makes the test pass.

    One acceptance item stays open: CI green with the integration job, over more
    than one run. That needs a CI run and cannot be checked from a workstation.
  timestamp: 2026-09-01T01:28:08.854635+00:00
- actor: claude-code
  id: 01m1dggvmfk5gktr4zatfekp16
  text: |-
    ### CI is green, and the last acceptance item is closed

    The remaining criterion asked for CI green with the integration job, over
    more than one run. Two runs now satisfy it:

    - `387a553` — completed, success.
    - `6be2294` — completed, success. Both jobs passed:
      `ci / Build & test` and
      `ci / Integration (opt-in, real dependencies)`.

    Note on the run between them. `587cfe7` reports `cancelled`, not `failure`.
    Its `Build & test` job passed in 3 minutes 43 seconds. The concurrency group
    stopped its integration job when the next push arrived. A cancelled run is
    not a failed run.

    Before this fix the branch failed on `5a0a732`, `5a8075b` and `b4e8dcb`.
  timestamp: 2026-09-01T03:34:34.383151+00:00
position_column: done
position_ordinal: ffffb080
title: A compaction fold drops a fact stated late in the span, because the summarizer answer degenerates and the stage stores it
---
## What

CI is red on `main`. The failing test is real-model, and it is finding a real product
defect rather than flaking:

```
IntegrationTests/.../CompactionSmokeIntegrationTests.swift:458
Test "a fact planted at the very end of the folded span is still in the summary the fold stores"
Expectation failed: summary.contains(Self.plantedFactValue)
```

## The mechanism the card assumed, and what measurement found instead

The card was written from failure evidence, not from the fold implementation. It
named a content-blind prefix cut as the cause. Measurement refuted that. The whole
finding is in the first comment. In short:

- The fold made ONE call and stored that answer word for word. No cut fired.
- The answer was a repetition loop: 60 copies of one line, and the line was a
  quoted example out of `CompactionPrompt.default` itself.
- The failure is deterministic on this box, not intermittent. Commit `2e07e98`
  pinned greedy decoding, and greedy is what makes a small model loop.

The card's instinct about POSITION was right. A fold loses the end of a span first,
whichever way it loses it, because a model writes about a span in the order the span
states it. The mechanism was the loop, not the bound.

## Why this must not be silenced

The test asserts the property a fold exists for. Shrinking a transcript is the cost a
fold pays, and carrying the facts forward is what it is paid FOR. A fold that shrank
the transcript and dropped the fact has not worked.

So do NOT make CI green by relaxing this assertion, marking the test flaky, or
retrying it.

## What was done

Two defects, and both are needed. Each was measured alone, and neither alone makes
the test pass.

1. `CompactionPrompt.default` quoted example facts, in two places, while telling the
   model to state only facts of the conversation. It now states every rule in the
   abstract, quotes nothing, and forbids the copy outright. The name goes to
   `router-default-v4`.
2. `Summarization` framed nothing and guarded nothing. The assembled prompt ran the
   instructions and the conversation together behind a bare separator, and the model
   summarized the instructions. The stage checked only that an answer was not empty
   and not too large, so a loop passed both. It now frames the content as the
   conversation, judges an answer for repetition, and re-asks once.

## Acceptance Criteria
- [x] A fact stated at the END of a folded span survives the fold's stored summary.
- [x] The stored summary still respects its size bound. It sits inside the folded
      span's byte budget with no cut, at 517 tokens against a 643-token span.
- [x] The test at CompactionSmokeIntegrationTests.swift:458 passes. The assertion is
      unchanged, word for word. Its explanatory comment changed, because it stated
      the prefix cut as the cause and that cause was measured absent. The comment now
      records both mechanisms and which task measured each.
- [x] Run it repeatedly, not once. It failed 6 of 6 runs before the fix and passed 13
      of 13 after it.

## Tests
- [x] A hermetic test of the strategy, so the property is guarded without a real
      model. Six tests were added to `SummarizationStageTests`: a loop earns one
      re-ask, a renumbered loop is still caught, a second loop is stored without its
      repeats, a clean answer costs no second call, a two-line answer is not a loop,
      and the assembled prompt frames its content.
- [x] Run `swift test`. All tests pass: 1142 tests in 126 suites, 83 tests in 10
      suites, 2 known issues.
- [ ] CI green, integration job included, over more than one run.

## Note

Found while verifying CI after ^bbbkas1 merged. `^bqj719z` is NOT a duplicate of this
card: it is a turn-cancellation bounded wait, and it shares no code with the fold.
`^echfvpm` was raised from the same run for an unrelated real-model timeout.
#router #compaction #defect #ci #real-model