---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0ea72jbqp3n8zh6xf0x5rth
  text: |-
    Picked up. Research findings:

    - `Summarization.cut(_:toCharacters:)` cuts the summary text to `summaryRetentionRatio` (0.8) of the call's content, floored at `minimumSummaryTokens` (128 tokens = 512 bytes at `Compactor.charsPerTokenEstimate` 4.0). On a small span the floor binds, and the default prompt's eight-section output regularly exceeds 512 bytes, so the cut is the routine path.
    - After ^64f3hnv the cut lands on a sentence or line boundary (`lastSentenceBoundary(in:)`), with a word-boundary and a whole-budget fallback. A sentence boundary inside section 3 still stores a scaffold that stops mid-section: the reader sees a numbered structure that promises eight sections and holds three and a half. That is the residual defect.
    - Decision: option 2 of the card — cut at a SECTION boundary when the text carries the scaffold. Option 1 (state the budget to the model) is refuted by the ^azd033m measurement recorded in the code. Option 3 (scale the section count) changes the prompt for every fold and does not remove the cut path.
    - Design: a flush-left line that opens with ASCII digits, a period, and a space is a section header. When the summary holds two or more such headers, the cut keeps the longest prefix of WHOLE sections whose byte count fits the limit, and it trims only trailing whitespace so the stored text stays a prefix of the model's answer. When not even the first section fits — possible only when one section alone exceeds the whole bound — the cut falls back to the sentence boundary as before, and the doc comment records that trade.
    - The change is one method plus two private helpers in Sources/FoundationModelsRouter/Compaction/Summarization.swift. Callers of `cut` are `summarizeOnce` and `boundaryBoundedSummary`, both in the same file; no signature changes.
    - Hermetic tests go in Tests/FoundationModelsRouterTests/SummarizationStageTests.swift, which already drives the cut through `foldOutcome` with a `ScriptedSummarizer` — no model.
  timestamp: 2026-08-20T00:47:54.955621+00:00
- actor: claude-code
  id: 01m0earpz46m33872sj87926w8
  text: |-
    Implementation landed, option 2 of the card: the cut now prefers a SECTION boundary.

    What changed:

    - `Sources/FoundationModelsRouter/Compaction/Summarization.swift`: `cut(_:toCharacters:)` gained a first fallback step. `sectionAlignedPrefix(of:withinBytes:)` keeps the longest prefix of WHOLE numbered sections that fits the byte limit; `sectionHeaderStarts(in:)` and `lineOpensSection(_:)` read a flush-left `N. ` line as a section header. Only trailing whitespace is trimmed, so the stored summary stays a prefix of the model's answer. Fewer than two headers, or a first section larger than the whole bound, answers `nil` and the sentence-boundary cut takes over — the doc comment records that trade with the 512-byte floor measurement. Both callers of `cut` (`summarizeOnce`, `boundaryBoundedSummary`) get the behavior with no signature change; the `limit <= 0` path of `boundaryBoundedSummary` is unchanged, because a non-empty prefix never fits a non-positive limit.
    - `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift`: two hermetic tests through the scripted summarizer, no model. `aSectionedSummaryIsCutAtASectionBoundary` was written first and WATCHED FAIL (the sentence cut stored a mid-section scaffold), then passed after the change; it pins the stored summary to exactly the whole sections that fit, with sanity assertions on both sides of the section count. `anOversizedFirstSectionFallsBackToTheSentenceBoundary` pins the fallback edge: it passes because the fallback is the pre-change behavior, and it fails against an implementation that empties or over-cuts on that edge. Shared helper `expectedRetainedCharacters` added beside `expectedSummaryCharacters`, both now one-line delegations to `characters(forExpectedTokens:)`.

    Verification:

    - RED: `Scripts/swift-test.sh --filter aSectionedSummaryIsCutAtASectionBoundary` failed on `summary == kept` before the change.
    - GREEN: same filter passed; whole `SummarizationStageTests` suite 45/45.
    - `swift build --build-tests -Xswiftc -warnings-as-errors`: clean.
    - `Scripts/swift-test.sh --skip IntegrationTests`: 1023 tests in 96 suites passed (baseline 1021 + the 2 new) and 77 tests in 9 suites passed. The 1 known issue is the pre-existing `withKnownIssue` in BoundedWaitTests.
    - Fast tier run once, because the change alters the cut it exercises: `Scripts/swift-test.sh --filter CompactionSmokeIntegrationTests` — 2/2 passed in ~10 s, with the documented fold numbers unchanged (summaryTokens=330, tokensAfter=400), so the smoke fixture's answer stays under the retention bound and takes no cut.

    Not done, on purpose: no change to `CompactionPrompt.default` (option 3) and no length directive in the prompt (option 1, refuted by ^azd033m). Acceptance criterion checked in the description.
  timestamp: 2026-08-20T00:57:32.900482+00:00
- actor: claude-code
  id: 01m0eas065g0qgdga1wd1ymnka
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Compaction/Summarization.swift, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift; `Scripts/swift-test.sh --skip IntegrationTests` green (1023 + 77 passed, 1 pre-existing known issue); `swift build --build-tests -Xswiftc -warnings-as-errors` clean; `--filter CompactionSmokeIntegrationTests` 2/2 passed once
    - next: review
  timestamp: 2026-08-20T00:57:42.341520+00:00
position_column: doing
position_ordinal: '8580'
title: The retention cut truncates the default CompactionPrompt's sectioned summary mid-section on small spans, and the truncated scaffold derails the next turn
---
Found on 2026-08-19 while task ^nwe0qt1 rebuilt the CompactionDemo.

## What was measured

A fold over a span of about 630 estimated tokens, summarized by `mlx-community/GLM-4-9B-0414-4bit` with `CompactionPrompt.default` (the eight-section scaffold): the model wrote a faithful sectioned summary, but the sectioned form is long, so `Summarization.cut(_:toCharacters:)` truncated it in the middle of section 3 ("index is rebuilt from"). The stored summary therefore ends mid-sentence inside a numbered scaffold.

The session model (`Llama-3.2-1B-Instruct-4bit`, greedy) then read the truncated scaffold as its context and degenerated on its next turn: the reply was "Nightjar Nightjar Nightjar ..." repeated to the token ceiling. The same fold with a one-paragraph prompt (`compactionPrompt:` override) fit inside the cut and the next turn stayed coherent.

## Why this matters

`cut(_:toCharacters:)` is documented as a safety bound. On a SMALL span the retention allowance (0.8 of the span) is small, and the default prompt's sectioned output regularly exceeds it, so the cut becomes the routine path rather than the safety net. A cut that ends mid-list is worse context than a shorter summary the model finished.

## What to decide

1. State the summary budget to the model in a way it can honor without the `^azd033m` failure mode, or
2. Cut at a SECTION boundary rather than a sentence boundary when the text carries the scaffold, or
3. Scale the prompt's section count down for small spans.

## Acceptance criteria

- [x] A fold's stored summary never ends inside an unfinished section or sentence, or the trade is documented with a measurement #compaction