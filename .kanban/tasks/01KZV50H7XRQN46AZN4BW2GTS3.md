---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzvy2v6zzznhdsd2xwpyg0t2
  text: |-
    Research done. Findings:
    - `RoutedModel.makeLanguageModel(resuming:)` (Sources/FoundationModelsRouter/RoutedLLM.swift) passes `forkedAtEntryCount: restoredTranscript.count` to `makeRecordingLanguageModelHandle`, which has no `forkedAtHistoryOrdinal` parameter.
    - `RecordingLanguageModelState.writeSidecarIfNeeded` (Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift) writes `forkedAtHistoryOrdinal: nil` with a comment that says the handle tracks no raw coordinate.
    - `TranscriptTree.effectiveEntryEvents` cuts with `forkedAtHistoryOrdinal ?? forkedAtEntryCount`, so a compacted resume gets the pre-fold span when only the legacy field is set.
    - Precedent test: Tests/FoundationModelsRouterTests/ForkAfterCompactionRestorationTests.swift (^6z1msg1). It shows the assertion shape: restored ids == checkpoint live-window ids + own recorded entry ids, and disjoint from folded ids.
    - The sidecar writer and `SessionSidecar` already accept the field, so only the handle path must thread it. Schema stays in v2; the v2 registry doc already covers the key.
    Plan: add `forkedAtHistoryOrdinal` to `RecordingLanguageModelState` and `makeRecordingLanguageModelHandle`, compute `tree.effectiveEntryEvents(forSession:).count` in `makeLanguageModel(resuming:)`, write both fields. TDD: new test file ResumeHandleAfterCompactionTests.swift, red first.
  timestamp: 2026-08-12T21:29:33.663951+00:00
- actor: claude-code
  id: 01kzvzpe40sx0fdt3x6mddw1g7
  text: |-
    ### implement — changed
    - evidence: 4 files changed. Sources/FoundationModelsRouter/RoutedLLM.swift — makeLanguageModel(resuming:) computes tree.effectiveEntryEvents(forSession:).count and writes it as forkedAtHistoryOrdinal; makeRecordingLanguageModelHandle threads the new parameter. Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift — RecordingLanguageModelState stores forkedAtHistoryOrdinal and writeSidecarIfNeeded writes it (before, it wrote nil). Sources/FoundationModelsRouter/Recording/SessionSidecar.swift — the forkedAtHistoryOrdinal doc now names the resume-handle writer. Tests/FoundationModelsRouterTests/RecordingHandleResumeTests.swift — two new tests. TDD: the compacted-resume test failed first (newestCompactionCheckpoint gave nil, because the cut selected the pre-fold span), then passed after the change. The old-recording test removes the key from the sidecar JSON and shows the legacy forkedAtEntryCount fallback stays correct. The schema stays in v2: the key is already in the v2 registry entry, and this change adds no new key. Verification: swift build --build-tests clean; one ungated swift test run — 896+27+24 tests passed, 0 failures (the 1 known issue is the pre-existing deliberate one in BoundedWait.swift).
    - next: /review
  timestamp: 2026-08-12T21:57:44.192363+00:00
position_column: doing
position_ordinal: '8180'
title: Record the resume-handle cut in append-only history coordinates
---
## Problem

Task ^6z1msg1 corrected the fork cut for `RoutedSessionActor`: a new fork writes `forkedAtHistoryOrdinal`, the cut in the recorded history's append-only coordinates. The resume-handle path does not write this field. `RoutedModel.makeLanguageModel(resuming:registry:)` (Sources/FoundationModelsRouter/RoutedLLM.swift, the `forkedAtEntryCount: restoredTranscript.count` argument) records the reconstructed transcript count. That count comes from the checkpoint-filtered restore view. When the resumed session was compacted, that count is smaller than the raw effective entry-event count. A reader that applies it as a prefix of the parent's raw events then selects the oldest pre-fold span, the same defect ^6z1msg1 removed for actor forks.

## Proposed solution

1. In `makeLanguageModel(resuming:)`, compute the raw effective entry-event count for the resumed session (`tree.effectiveEntryEvents(forSession:).count`).
2. Add a `forkedAtHistoryOrdinal` parameter to `RecordingLanguageModel` and thread it to `writeSidecarIfNeeded`, which now passes `nil` (see the comment in `RecordingLanguageModel.writeSidecarIfNeeded`).
3. Write both fields, as the actor fork path does.

## Acceptance

- Test: resume a compacted session with `makeLanguageModel(resuming:)`, drive a turn, then reconstruct the handle's effective transcript. Assert the result equals the checkpoint's live window plus the handle's own entries, with no pre-fold span.
- Old recordings without the field keep the current fallback behavior. #transcript