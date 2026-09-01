---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1esf8zy3n8yxf7vjdggy9rv
  text: |
    ### Research — the cause of the three calls

    I found the cause. The fold is not reproducible from one day to the next.

    **The prompt carries today's date.**

    The chat template of `mlx-community/Llama-3.2-1B-Instruct-4bit` writes the
    date into the system header of every summarizer call:

    ```
    {%- if not date_string is defined %}
        {%- if strftime_now is defined %}
            {%- set date_string = strftime_now("%d %b %Y") %}
    ...
    {{- "Today Date: " + date_string + "\n\n" }}
    ```

    File: `~/.cache/huggingface/hub/models--mlx-community--Llama-3.2-1B-Instruct-4bit/snapshots/08231374.../tokenizer_config.json`

    `swift-jinja` supplies `strftime_now`. It reads the clock and the local zone:

    ```
    IntegrationTests/.build/checkouts/swift-jinja/Sources/Jinja/Globals.swift
        "strftime_now": .function(strftimeNow),
        let date = Date()
        let formatter = DateFormatter()
    ```

    The summary prompt therefore changes each day. Greedy decoding pins the
    sampling. It does not pin the prompt.

    **The measurement that proves it**

    I ran the same binary twice, minutes apart. I changed only the time zone,
    so I changed only the calendar date the template stamps.

    ```
    $ swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests
    [compactionSmoke] summarizerCalls=3 ceilings=[617, 617, 628] answerTokens=[703, 789, 810] ...

    $ TZ=Pacific/Kiritimati swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests
    [compactionSmoke] summarizerCalls=3 ceilings=[617, 617, 628] answerTokens=[703, 836, 840] ...
    ```

    `TZ=Pacific/Kiritimati` makes the local date 02 Sep 2026. The answers change.
    Nothing else changed.

    **What I refuted**

    - The filtered run is NOT different from the whole-package run. Both print
      `summarizerCalls=3 ceilings=[617, 617, 628] answerTokens=[703, 789, 810]`.
      The package context is not the variable.
    - The weights did not change. The cache holds one snapshot, `08231374`,
      written 2026-07-13. That date is before the green runs.
    - The code did not change. `git log 6be2294..HEAD -- Sources/ Package.swift
      Package.resolved IntegrationTests/ Tests/FoundationModelsRouterRealModelSupport/
      Tests/FoundationModelsRouterTestSupport/` lists no commit.
    - The fork did not change. Both checkouts sit at `41e9f41`, and mlx-swift
      sits at `0bb916c`. Neither checkout is dirty.
    - The Metal library did not change. `default.metallib` is dated Aug 31 18:47,
      before the green runs of that evening.
  timestamp: 2026-09-01T15:30:14.142303+00:00
- actor: claude-code
  id: 01m1esfnh8znbqj1zjghfp1b8z
  text: |
    ### The two failures are ONE defect, not two

    I dumped every call answer and the stored summary of today's fold.

    | item | bytes | holds `Kestrel` |
    |---|---|---|
    | call 0, the map call, ceiling 617 | 2811 | no |
    | call 1, the repetition re-ask, ceiling 617 | 3153 | yes, at byte 2789 |
    | call 2, the condense re-ask, ceiling 628 | 3238 | no |
    | the stored summary | 2033 | no |

    The span holds 2569 to 2572 bytes. `Summarization.summaryByteBudget`
    subtracts the 4-byte margin. The storage budget is therefore 2565 to 2568
    bytes.

    **The chain**

    1. The map call writes a repetition loop. `isRepetitive` fires correctly.
    2. The repetition re-ask answers 3153 bytes. It DOES carry `Kestrel`.
       3153 bytes overrun the 2568-byte budget by 585 bytes.
    3. The overrun starts the condense rung. That is the THIRD call.
    4. The condense answer is 3238 bytes. It is LARGER than its own input, and
       it is a pure repetition loop. The fold discards it.
    5. `cut` keeps a section-aligned prefix of 2033 bytes. `Kestrel` sits at
       byte 2789, so the cut drops it.

    So one root cause makes both tests red: the answer is bigger than the fold
    can store. Without the overrun there is no third call, no cut and no lost
    fact.

    **Three calls is a defect, not correct behaviour**

    The third call bought nothing. It returned a longer text than the text it
    had to shorten, and the fold threw it away. Two further defects sit under
    that, and each is worth its own card:

    - `condense` sizes its ceiling at 628 tokens. The answer it must shorten was
      written under a ceiling of 617. A condense call may therefore write MORE
      than its input.
    - `condense` never checks its answer for a repetition loop. `summarizeOnce`
      checks every other call.

    The `(1...2)` bound is right, and it caught exactly what its comment says it
    guards: both recovery rungs fired.
  timestamp: 2026-09-01T15:30:26.984191+00:00
- actor: claude-code
  id: 01m1esgat4prqxeb8f5dvc0vaw
  text: |
    ### Blocker — I cannot meet the second and third acceptance criteria

    Criterion 1 is done. Criteria 2 and 3 need a decision from you.

    **Why**

    The suite asserts the exact arithmetic of one fold of a 1B model. The
    prompt of that fold carries today's date, so the arithmetic is a new sample
    every day. Three samples so far:

    | date the template stamped | answerTokens | result |
    |---|---|---|
    | 31 Aug 2026 | `[671, 517]` | green, 13 of 13 runs |
    | 01 Sep 2026 | `[703, 789, 810]` | red |
    | 02 Sep 2026 (`TZ=Pacific/Kiritimati`) | `[703, 836, 840]` | red |

    Today the model writes 3153 bytes and puts `Kestrel` at byte 2789. The fold
    can store 2568 bytes. To keep `Kestrel` AND stay inside two calls, I must
    remove 585 bytes that stand before it, and remove them without a
    generation.

    **The repairs I measured, and why each one fails**

    - Drop repeated lines before the budget test. Measured: 3153 bytes fall to
      2606 bytes, and `Kestrel` moves to byte 2345, inside the budget. The text
      is still 38 bytes over, so the condense rung still fires. Three calls
      remain.
    - Lower the generation ceiling to the storage budget. The model runs to its
      ceiling on all three calls. A lower ceiling cuts the answer sooner, and
      the span states the planted fact last. The fact dies sooner, not later.
    - Pin `date_string` so the prompt stops moving. The router builds the
      prompt through Apple's `LanguageModelSession`. `MLXLanguageModel` fills
      `additionalContext` from its reasoning strategy alone. No caller can add
      a template variable. This repair needs a change in the `mlx-swift-lm`
      fork.
    - Lower the suite's `reasoningTokenHeadroom`. This tunes the suite to one
      day of model output. The same tuning passed 13 of 13 on 2026-08-31 and
      fails today. I will not repeat it.

    **The one question**

    Which do you want?

    1. I raise a fork card: let a caller pin `date_string`, then pin it in the
       suite. The suite becomes reproducible, and both assertions stand as
       written.
    2. I keep both assertions and accept that the suite goes red on some days.
    3. You give me another repair to measure.

    Command and output that stand behind this:

    ```
    $ swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests
    [compactionSmoke] summarizerCalls=3 ceilings=[617, 617, 628] answerTokens=[703, 789, 810] spanTokens=643 summaryTokens=509 tokensBefore=713 tokensAfter=579
    ✘ Test run with 2 tests in 1 suite failed after 26.5 seconds with 2 issues.
    ```
  timestamp: 2026-09-01T15:30:48.772778+00:00
- actor: claude-code
  id: 01m1esh5tgdfnpgmfebw2dfbf2
  text: |
    ### implement — stuck
    - evidence: no product file changed. The fold's prompt carries today's date, through the Llama 3.2 chat template and `strftime_now`. Proof: `TZ=Pacific/Kiritimati swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests` prints `answerTokens=[703, 836, 840]` where the same binary prints `[703, 789, 810]`. The filtered run matches the whole-package run exactly, so the package context is not the variable. One root cause makes both tests red: the re-ask answer holds 3153 bytes against a 2568-byte storage budget, and it states `Kestrel` at byte 2789. `swift test` stays green: 1159 tests in 128 suites plus 83 in 10, exit 0, 2 known issues.
    - next: the user picks one of the three options in the blocker comment. No file was changed.
  timestamp: 2026-09-01T15:31:16.432055+00:00
- actor: claude-code
  id: 01m1evthvjdfdev2wjc1xazkz0
  text: |
    ### The five defects found, and the numbers behind each

    I measured the fold byte by byte before I changed anything.

    ```
    [probe] spanBytes=2569 budgetBytes=2565 answerBytes=3153 dedupedBytes=2606
    ```

    The fold can store 2565 bytes. The re-asked answer holds 3153 bytes. It
    repeats 547 bytes of lines it had already written. It states `Kestrel` at
    byte 2789.

    **Defect 1 — the condense call can be sized above its own input.**
    The condense rung asked for a ceiling of 628. Its input was written under a
    ceiling of 617. A model writes up to its ceiling, so the call was free to
    answer with more text than it was given. It did: 3238 bytes out, 3153 in.

    **Defect 2 — the condense rung never tests its answer for a loop.**
    Every other rung does. The answer was a pure repetition loop.

    **Defect 3 — a repeated line occupies the stored summary's byte budget.**
    The stage already states this rule, but only on the discard path. The
    answer the fold carried forward held 547 bytes of repeated lines.

    **Defect 4 — the recovery ladder spends two generations.**
    The repetition rung re-asked, and then the condense rung re-asked again
    about the same material. The second ask returned a loop longer than its
    input, and the fold discarded it. Three calls, and the third bought
    nothing.

    **Defect 5 — the cut drops a whole final section to shed a few bytes.**
    After the free repair the text held 2606 bytes against a 2565-byte budget,
    41 bytes over. The section-aligned cut shed 906 bytes to align, because it
    can only stop at a section header. `Kestrel` stood after the last header,
    so it went with them.

    ### What I changed

    - A summarizer answer now carries the ceiling it ran under, and whether a
      recovery re-ask paid for it.
    - A condense call is never sized above the call that wrote its input.
    - A condense call tests its answer for a loop, and discards a loop.
    - The oversize ladder drops repeated lines first. A free repair comes
      before a paid one.
    - A fold spends ONE recovery generation, whichever rung spends it.
    - A section-aligned cut that runs up to the LAST section header no longer
      drops that section whole. No later section can be truncated there, so
      the boundary cut is taken when it stores more.

    Each change has a unit test. I proved each test red against the old code
    with `git stash`, then green against the new code.
  timestamp: 2026-09-01T16:11:20.818356+00:00
- actor: claude-code
  id: 01m1evvaaj7tmmc40q8mjqqyrp
  text: |
    ### implement — changed

    - evidence: 2 files — `Sources/FoundationModelsRouter/Compaction/Summarization.swift`, `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift`. Fold before, on 01 Sep: `summarizerCalls=3 ceilings=[617, 617, 628] answerTokens=[703, 789, 810] summaryTokens=509 tokensAfter=579`, both tests red. Fold after, on 01 Sep: `summarizerCalls=2 ceilings=[617, 617] answerTokens=[703, 789] summaryTokens=624 tokensAfter=694`, both tests green. `swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests` passed twice on 01 Sep, under the default zone and under `TZ=Pacific/Midway`. Under `TZ=Pacific/Kiritimati` the date is 02 Sep: the call-budget test passes at `summarizerCalls=2 ceilings=[617, 617] answerTokens=[703, 836] summaryTokens=615`, where the old code made 3 calls; the planted-fact test fails, because the model's own answer of 3344 bytes never states `Kestrel` — `grep -ic kestrel` reports 0, and the answer copies the user prompt back instead. No fold can store a fact the model never wrote. `swift test` exit 0, 1164 tests in 128 suites plus 83 in 10, 2 known issues. `swift build --package-path IntegrationTests --build-tests` exit 0.
    - next: review. The date pinning is still needed, and it is carded as ^f0k3aah. It needs a change in the `mlx-swift-lm` fork, so it stays out of this card.
  timestamp: 2026-09-01T16:11:45.874079+00:00
position_column: doing
position_ordinal: '8180'
title: The compaction smoke fold fails again, deterministically, on code CI passed twice
---
## What

Two tests of `CompactionSmokeIntegrationTests` fail on every run:

```
✘ "a fact planted at the very end of the folded span is still in the summary
   the fold stores" — CompactionSmokeIntegrationTests.swift:481:9
   Expectation failed: summary.contains(Self.plantedFactValue)

✘ "one fold against a real model: the summarizer answers within the fold's
   call budget, and the fold is applied rather than discarded"
   — CompactionSmokeIntegrationTests.swift:418:9
   Expectation failed: (1...2).contains(ceilings.count)
```

Both fail 3 of 3 whole-package runs, and the planted-fact test also fails
alone under `--filter aPlantedFactLateInTheSpanSurvivesTheFold`.

## The numbers repeat exactly

Every run prints the same fold line:

```
[compactionSmoke] summarizerCalls=3 ceilings=[617, 617, 628]
                  answerTokens=[703, 789, 810] spanTokens=643
                  summaryTokens=509 tokensBefore=713 tokensAfter=579
```

Decoding is greedy, so the fold is deterministic. This is not a flaky test.

## Why this is new

Task ^49dy082 fixed this same pair on 2026-08-31. It measured the fold at
`summarizerCalls=2 ceilings=[617, 617] answerTokens=[671, 517]
summaryTokens=517`, and it passed 13 of 13 runs. A reviewer then passed 5 of 5.
CI passed the integration job twice, on `387a553` and on `6be2294`.

Since `6be2294` no product file changed. The commits are `44af734` (kanban),
`2a3e0c0` (kanban plus `TurnCancellationTests.swift`) and `11760eb` (README).

So the same product code now folds differently. The summarizer takes 3 calls
where it took 2, and each answer is larger.

## The answer, measured 2026-09-01

The fold is NOT deterministic from one day to the next. The chat template of
`mlx-community/Llama-3.2-1B-Instruct-4bit` writes `Today Date: <today>` into
the system header of every summarizer call, through `strftime_now`, which
`swift-jinja` supplies from `Date()`. Greedy decoding pins the sampling. It
does not pin the prompt.

Proof: the same binary, minutes apart, with only the time zone changed.

```
$ swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests
[compactionSmoke] summarizerCalls=3 ceilings=[617, 617, 628] answerTokens=[703, 789, 810] ...

$ TZ=Pacific/Kiritimati swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests
[compactionSmoke] summarizerCalls=3 ceilings=[617, 617, 628] answerTokens=[703, 836, 840] ...
```

The filtered run and the whole-package run print the same numbers, so the
package context is not the variable. See the comments for the byte-level
measurement and for what the research refuted.

## Blocker — a decision is needed

Today the repetition re-ask writes 3153 bytes and states `Kestrel` at byte
2789. The fold can store 2568 bytes. Both assertions can hold only if 585
bytes before that point go away without a further generation. The comments
list the four repairs measured, and why each one fails.

Pick one:

1. Raise a fork card: let a caller pin `date_string`, then pin it here.
2. Keep both assertions and accept red runs on some days.
3. Name another repair to measure.

## Acceptance Criteria
- [x] The reason the fold now takes 3 calls is stated, with a measurement.
- [ ] Both tests pass. The assertions do not change.
- [ ] The whole integration package passes three times in a row.

## Tests
- [ ] `swift test --package-path IntegrationTests` three times.

## Note

Found while working ^echfvpm. That card is a real-model time limit and shares
no code with the fold. The failure blocks ^echfvpm's second acceptance
criterion, which asks for three green package runs. #router #compaction
#defect #real-model #ci