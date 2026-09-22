---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
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