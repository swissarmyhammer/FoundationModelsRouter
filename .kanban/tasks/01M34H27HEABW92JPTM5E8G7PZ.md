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
- actor: claude-code
  id: 01m34nmcycdjrybc96d3r1hmen
  text: |-
    ### commit — changed
    - evidence: 177a9b4 refactor(compaction): use one word, "compaction", for the operation that shrinks the transcript
    - next: /review 5e8g7pz HEAD~1..HEAD
  timestamp: 2026-09-22T13:42:07.052171+00:00
- actor: claude-code
  id: 01m34qhws8pswfvfer01jaakse
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` — 6 findings, 6 confirmed, 0 refuted, 112 attempted — Examples/CompactionDemo/main.swift:295, Examples/CompactionDemo/main.swift:329, IntegrationTests/.../CompactionContinuityEvalRealSubjectRunner.swift:258, Tests/FoundationModelsRouterTests/CompactionTracingTests.swift:116, Tests/FoundationModelsRouterTests/ExamplesTests.swift:663, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift:1
    - task moved doing -> review; findings appended to the description.
    - next: /implement works the unchecked items.
  timestamp: 2026-09-22T14:15:42.120495+00:00
- actor: claude-code
  id: 01m34qn5pkpbycr0rp1vpv44zd
  text: |-
    ### implement — changed (iteration 2: the review findings)
    - evidence: 4 files — `Examples/CompactionDemo/main.swift` (a `// swiftlint:disable:next no_direct_standard_out_logs` line with its reason before every one of the 13 `print(` calls, not only the two flagged lines), `IntegrationTests/.../CompactionContinuityEvalRealSubjectRunner.swift` (the same before both `print(` calls), `Tests/FoundationModelsRouterTests/ExamplesTests.swift:663` ("to actually compact"), `Tests/FoundationModelsRouterTests/CompactionTracingTests.swift:116` (`compactionSpanCarriesItsOwnTokenCounts`, singular).
    - the sixth finding (`SummarizationStageTests.swift:1`, split the file for the review prompt cap) is released by the written rule that drops findings which ask to refactor tests that already existed: the file existed before this task, and this change only renamed words in it. Flipped with this reason; no edit made to that file.
    - `swift build --build-tests` and `swift build --package-path IntegrationTests --build-tests` clean; `swift test --filter 'ExamplesTests|CompactionTracingTests'` 20 tests passed.
    - next: /test (full run), /commit, /review.
  timestamp: 2026-09-22T14:17:29.555155+00:00
- actor: claude-code
  id: 01m34qnnrqnc7r67pb6203wvwt
  text: |-
    ### test — green (iteration 2)
    - evidence: `swift test` — 1356 tests in 145 suites passed (2 known issues, pre-existing), 1 test in 1 suite passed, 83 tests in 10 suites passed; 0 failures, 0 skipped, 0 Swift warnings. `swift build --package-path IntegrationTests --build-tests` — Build complete.
    - next: /commit, then /review 5e8g7pz HEAD~1..HEAD.
  timestamp: 2026-09-22T14:17:46.007675+00:00
- actor: claude-code
  id: 01m34qnz7m8g18w1g378tjswrd
  text: |-
    ### commit — changed (iteration 2)
    - evidence: bdb12db fix(review): answer the review findings of the compaction rename
    - next: /review 5e8g7pz HEAD~1..HEAD
  timestamp: 2026-09-22T14:17:55.700007+00:00
- actor: claude-code
  id: 01m34qtyp9zjc6sx0q08a40y6v
  text: |-
    ### review — clean (iteration 2)
    - evidence: `review sha HEAD~1..HEAD` — 0 findings, 0 confirmed, 0 refuted, 7 attempted; 4 files reviewed. Every prior finding is checked.
    - task moved review -> done.
  timestamp: 2026-09-22T14:20:38.985859+00:00
- actor: claude-code
  id: 01m34qvgn33qs52k9v7q866fz2
  text: |-
    ### finish iteration 1 — review clean, task in done
    - implement: changed — 115 files renamed or rewritten, 4 files moved with `git mv`, `CompactionSegment.Content` gained explicit `CodingKeys` and a legacy-key decode path with two tests; second pass answered 5 review findings and released 1 by the written rule on tests that already existed
    - test: green — `swift test`: 1356 tests in 145 suites, 1 test in 1 suite, 83 tests in 10 suites, all passed, 0 failures, 0 skipped, 0 Swift warnings; `swift build --package-path IntegrationTests --build-tests`: Build complete
    - commit: 177a9b4, bdb12db
    - review: clean — `review sha HEAD~1..HEAD` 0 findings after bdb12db; the earlier pass on 177a9b4 had 6 findings at Examples/CompactionDemo/main.swift:295, Examples/CompactionDemo/main.swift:329, IntegrationTests/.../CompactionContinuityEvalRealSubjectRunner.swift:258, Tests/FoundationModelsRouterTests/CompactionTracingTests.swift:116, Tests/FoundationModelsRouterTests/ExamplesTests.swift:663, Tests/FoundationModelsRouterTests/SummarizationStageTests.swift:1, all checked
    - acceptance: `rg -i '\bfold(s|ed|ing)?\b'` finds nothing; `rg -oI '\b\w*[Ff]old\w*\b'` finds only scaffolding 9, folders 6, scaffold 5, foldedEntryIds 4 (the wire-format key), scaffolds 2, folder 1
  timestamp: 2026-09-22T14:20:57.379131+00:00
position_column: done
position_ordinal: ffffdd80
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

## Review Findings (2026-09-22 08:42)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 111 file(s) reviewed, 11 not reviewed.

> 1 file(s) not reviewed — the rendered prompt would exceed the agent's prompt cap:
> - `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift` — 330666 rendered bytes, over the 262144-byte per-file cap; not reviewed by: duplication (split the file)

> 6 file(s) not reviewed — excluded by an ignore rule: `.kanban/ (from .reviewignore)` — 6 file(s)

> 4 file(s) not reviewed — no validator matched: `Examples/CompactionDemo/README.md`, `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/SessionProjection.md`, `Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording/README.md`, `compaction_plan.md`.

> The tool rules `disallowed-constructs-swift`, `function-length-swift`, `idioms-swift`, `magic-numbers-swift` and `missing-docs-swift` each declined the four renamed-away paths (`ResponseTextFold.swift`, `CompactionFold.swift`, `CompactionFoldFixtures.swift`, `FoldSpanObservation.swift`): the file no longer exists at that path, so its content is unread there.

- [x] `Examples/CompactionDemo/main.swift:295` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Examples/CompactionDemo/main.swift:329` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `IntegrationTests/Tests/FoundationModelsRouterEvalIntegrationTests/Support/CompactionContinuityEvalRealSubjectRunner.swift:258` `code-hygiene/disallowed-constructs-swift` — no_direct_standard_out_logs: Do not commit print(…), debugPrint(…), dump(…) or _printChanges(), which write to standard out in release. Log to a dedicated logging system, or silence one debug-only line with // swiftlint:disable:next no_direct_standard_out_logs and the reason after it.
- [x] `Tests/FoundationModelsRouterTests/CompactionTracingTests.swift:116` `swift/naming-clarity` — The function name uses plural 'Compactions' when the corresponding test description and semantic meaning require singular 'Compaction'. The test name states 'the compaction's own' (singular possessive), but the function name appears to use 'Compactions' (plural), creating inconsistency and confusion. Rename the function to use singular form: 'compactionSpanCarriesTheCompactionOwnTokenCounts' or simplify to 'compactionSpanCarriesTokenCounts' (omitting needless words per naming-clarity rule).
- [x] `Tests/FoundationModelsRouterTests/ExamplesTests.swift:663` `swift/naming-clarity` — The word 'compaction' is used as a verb when 'compact' should be used. The phrase 'had anything left to actually compaction' is grammatically incorrect and unclear. Replace 'compaction' with 'compact' on line 663: '// compact (that mechanics, and a real non-empty-stagesApplied compaction, is'.
- [x] `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift:1` `review-engine/prompt-cap` — This file exceeds the review prompt cap — 330666 rendered bytes against the 262144-byte per-file cap — so these validators could not review it: duplication. Split the file into smaller modules that fit the review prompt cap.