---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34ngbr62056dhq2yj44f3vk
  text: |-
    ### research and decisions

    - The code-context rename (`get rename_edits`) rejects every argument shape with "missing required parameter 'line'", and sourcekit-lsp is not installed. The identifier rename was done with a whole-word script (`rename.pl`, an explicit table of about 170 identifiers) and verified by the build. No identifier is public, so no external caller exists.
    - Two identifiers use "fold" in the functional sense (a reducer over events), not the compaction sense: `ResponseTextFold` and `TurnOutcomeFold`. They became `ResponseTextReducer` and `TurnOutcomeReducer`, and the file `Session/ResponseTextFold.swift` was renamed with `git mv` to `ResponseTextReducer.swift`. Their prose says "reduce".
    - Other prose uses of "fold" that do not mean compaction were rewritten by meaning: "folded onto" (a copy merged onto a shared helper) became "merged onto"; "folds the result back in" became "merges"; "folds usageIncrement into" became "adds"; "case-fold" became "normalize case".
    - `CompactionFold` (real-model test support) became `TranscriptCompaction`, `CompactionFoldOutcome` became `TranscriptCompactionOutcome`, file renamed with `git mv` to `TranscriptCompaction.swift`. `CompactionFoldFixtures.swift` became `CompactionFixtures.swift`. `FoldSpanObservation.swift` became `CompactionSpanObservation.swift`.
    - The private actor method `fold(prompt:budget:summarizer:summarizerModel:)` became `runCompaction(...)`, because `compact(prompt:budget:)` already exists on the actor.
    - `CompactionEvalProgressStep.fold` became `.compaction`; its raw value is the word a progress line prints, so the eval log now prints `compaction` and `compactions=N`.
    - `unfolded`, `unfoldedDetail` and `unfoldable` all mean "not compacted". They became `uncompacted`, `uncompactedDetail` and `uncompactable`.
    - `CompactionSegment.Content` now has explicit `CodingKeys` with `legacyCompactedEntryIds = "foldedEntryIds"`, a hand-written `init(from:)` that reads either key, and an `encode(to:)` that writes only `compactedEntryIds`. Two new tests in `CompactionSegmentTests` cover the legacy key: one decodes and restores through `init?(schemaName:contentJSON:id:)`, one proves the encoder writes the new key only.
    - The word `foldedEntryIds` remains in exactly two places: the `CodingKeys` raw value and the legacy-key test fixture. That is the one wire-format key the card allows.
    - Discovery: `swift build --package-path IntegrationTests --build-tests` fails at `RealToolTurnComparisonTests.swift:351` ("switch must be exhaustive") because commit 5705477 added `SessionEvent.generationCall`. This task changed one comment word in that file. Recorded as a separate task.
  timestamp: 2026-09-22T13:39:54.758751+00:00
- actor: claude-code
  id: 01m34nj9ws4xcv2v8mej0kvagf
  text: |-
    ### implement — changed
    - evidence: 115 files changed, 2450 insertions, 2303 deletions; 4 files renamed with `git mv` (`CompactionFixtures.swift`, `CompactionSpanObservation.swift`, `TranscriptCompaction.swift`, `ResponseTextReducer.swift`); `CompactionSegment.swift` gained `CodingKeys`, `init(from:)`, `encode(to:)`; `CompactionSegmentTests.swift` gained two legacy-key tests.
    - acceptance: `rg -i '\bfold(s|ed|ing)?\b'` finds nothing; `rg -oI '\b\w*[Ff]old\w*\b'` finds only `scaffolding` 9, `folders` 6, `scaffold` 5, `foldedEntryIds` 4 (the wire-format key: 1 in `CodingKeys`, 3 in the legacy-key tests), `scaffolds` 2, `folder` 1.
    - build: `swift build` and `swift build --build-tests` clean; `swift test` passed 1356 + 1 + 83 tests, 0 failures.
    - next: /test, then /commit, then /review.
  timestamp: 2026-09-22T13:40:58.393409+00:00
- actor: claude-code
  id: 01m34nks059zav4amtg4024ywm
  text: |-
    ### test — green
    - evidence: `swift test` — 1356 tests in 145 suites passed (2 known issues, pre-existing `withKnownIssue`), 1 test in 1 suite passed, 83 tests in 10 suites passed; 0 failures, 0 skipped, 0 Swift warnings. `swift build --package-path IntegrationTests --build-tests` — Build complete. The integration targets are gated on a resident real model and were built, not run; CI runs them.
    - fix made in this step: `IntegrationTests/.../RealToolTurnComparisonTests.swift:365` — added `.generationCall` to the catch-all arm of the `switch event`, the case commit 5705477 added to `SessionEvent`. The package did not compile before this fix. The separate card written for it was deleted, because this task now carries the fix.
    - next: /commit, then /review.
  timestamp: 2026-09-22T13:41:46.629601+00:00
position_column: doing
position_ordinal: '80'
title: Replace "fold" with "compact" in code, comments, tests and docs
---
## Decision (from the owner, 2026-09-22)

One word for the operation that shrinks the live transcript: "compact" / "compaction". The word "fold" must not appear in code, comments, tests or docs.

## Inventory (measured with `rg -oI '\b\w*[Ff]old\w*\b'`)

About 2,300 occurrences in 110 files.

- Prose in comments and docs: `fold` 1,242, `folded` 340, `folds` 192, `folding` 47. This is most of the work, and it is text only.
- Identifiers: about 170 distinct names. None is `public`. Most are test names and test helpers. The shared ones in `Sources` are `foldedEntryIds`, `foldCount`, `foldOutcome`, `preFoldTokens`, `foldable`, `deterministicFoldBudget`, `foldingOld`, `foldBudget`, `summarizingFoldBudget`, `preFoldEntries`, `ResponseTextFold`, `postFoldFill`, `foldProducedNoSummary`, `foldOccurred`, `FoldSummarizerTier`, `TurnOutcomeFold`, `CompactionFoldOutcome`, `foldedUsage`, `foldDiscarded`, `noteAbandonedFold`, `abandonFoldIfCancelled`, `FoldOccurred`.
- Files to rename with `git mv`: `Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift`, `Tests/FoundationModelsRouterTests/Helpers/FoldSpanObservation.swift`, `Tests/FoundationModelsRouterRealModelSupport/CompactionFold.swift`.
- Docs: `compaction_plan.md`, `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/SessionProjection.md`, `Examples/CompactionDemo/README.md`, `Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording/README.md`.
- User-visible strings: `Compaction/Summarization.swift:24` ("the fold has no summary to store"), `Compaction/CompactionSegment.swift:89` ("entries folded into a").

## The one wire-format hit

`CompactionSegment.Content` (`Compaction/CompactionSegment.swift:29`) is `Codable` with synthesized keys. Its `foldedEntryIds` is a JSON key inside every recorded checkpoint on disk. Rename the property to `compactedEntryIds` and add `CodingKeys` so a checkpoint written with `foldedEntryIds` still decodes. Write the new key. Add a test that decodes a checkpoint with the old key.

## Not the word

Leave these alone: `folder`, `folders`, `scaffold`, `scaffolding`, `scaffolds`. Check `unfolded`, `unfoldedDetail` and `unfoldable` by meaning before you change them. If they mean "not compacted", rename them. If they mean "expanded", they stay.

## Do this

1. Rename the identifiers in `Sources` first, with the code-context rename, so every call site follows. Build.
2. Rename the test identifiers and the three files. Build and run the tests.
3. Rewrite the prose in comments and docs. Keep each comment's meaning. "fold" becomes "compact" or "compaction"; "folded" becomes "compacted"; "a fold" becomes "a compaction".
4. Rewrite the two user-visible strings.
5. Run `rg -i '\bfold(s|ed|ing)?\b'` and `rg -oI '\b\w*[Ff]old\w*\b'` across the repo. Only `folder`, `scaffold` and their forms may remain.

## Acceptance

- The two `rg` commands above find only `folder`, `scaffold` and their forms.
- All tests pass.
- A recorded checkpoint with the key `foldedEntryIds` decodes and restores.
- The three helper files are renamed with `git mv`, so history follows them.

## Order

Land this before ^9ddjkjm and ^46bz58k. They edit `RoutedSessionActorCompaction.swift` and `RoutedSessionActorTurnExecution.swift`, and a rename in flight makes their diffs hard to read. #compaction