---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m11sp58xa0a2rakq22syasmh
  text: |-
    Implementation record (TDD):

    1. RED: Added `recordingLevelHasNoMetadataOnlyCase` and rewrote `preExistingContentRemovedPayloadStillThrows`. The build failed as expected: "type 'RecordingLevel' has no member 'allCases'".
    2. GREEN: Removed `case metadataOnly` from `RecordingLevel`, added `CaseIterable`, and removed the `.metadataOnly` branch from `GatingRecorder.append`. The `.off` and `.full` branches did not change. Deleted the seven tests the card lists. Corrected the stale doc comments and code comments in Router.swift, GatingRecorder.swift, TranscriptReconstruction.swift, TranscriptEvent.swift, TranscriptEntryPayload.swift, and in three test files. Changed `SessionSidecarTests.sampleSidecar` to use `.full` because `.metadataOnly` is gone; the sample tests do not assert on that value.
    3. Verification: full `swift test` — 1052 tests in 104 suites passed plus 83 eval tests, with 2 known issues (the pre-existing `withKnownIssue` markers in RealModelHarness.swift and BoundedWait.swift, files not touched). After `swift package clean`, `swift build --build-tests` completed with zero warnings from this package (the only warnings come from the vendored mlx-swift Metal headers).

    Note on the grep acceptance criterion: `grep -rn "metadataOnly" Sources Tests` finds only the guard test the card itself mandates — its function name and the literal in `RecordingLevel(rawValue: "metadataOnly") == nil`. No usage of the removed case remains. `strippingContent()` stays, as the card orders; the follow-up card removes it.

    Environment note: the first builds failed because a Zed sourcekit-lsp process ran an index build inside `.build/checkouts/mlx-swift-lm` and blocked SwiftPM from replacing that stale checkout. I moved the stale checkout to the session scratchpad and let SwiftPM re-fetch it. This was a build-environment problem, not a code problem.
  timestamp: 2026-08-27T14:23:52.093930+00:00
- actor: claude-code
  id: 01m11spbt3p36qa5q2egbdxz3b
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Recording/GatingRecorder.swift, Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift, Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift, Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift, Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift, Tests/FoundationModelsRouterTests/TranscriptReconstructionTests.swift, Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift, Tests/FoundationModelsRouterTests/SessionSidecarTests.swift; `swift build --build-tests` after `swift package clean` exit 0 with zero package warnings; `swift test` 1052+83 tests passed, 0 failures, 2 pre-existing known issues
    - next: /review
  timestamp: 2026-08-27T14:23:58.787267+00:00
- actor: claude-code
  id: 01m11swfc8djfgczafz9kddyc0
  text: |-
    ### test — green
    - evidence: `swift build --build-tests 2>&1` (full recompile after touching all Sources/Tests) — exit 0, 0 warnings from this package (only pre-existing mlx-swift bundle warning). `swift test` run 3 times — 1052 tests in 104 suites + 83 tests in 10 suites, all pass; each run shows exactly 2 known issues (RealModelHarness.swift:72, BoundedWait.swift:114), matching the documented pre-existing known issues. No skipped/disabled tests.
    - `grep -rn "metadataOnly" Sources Tests --include=*.swift` returns only the one permitted exception: the guard test name and its `rawValue: "metadataOnly"` assertion in MergedAndRedactionTests.swift.
    - next: ready for review.
  timestamp: 2026-08-27T14:27:19.048852+00:00
- actor: claude-code
  id: 01m11t4604c5vmx1s76vwzxe1v
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 8b9dca1); counts: 0 findings, 0 confirmed, 0 refuted; 9 files reviewed; 14 files not reviewed (`.kanban/` — .reviewignore rule)
    - next: task moved to done; the removal of `strippingContent()` continues in ^zgn3z1h
  timestamp: 2026-08-27T14:31:31.588115+00:00
- actor: claude-code
  id: 01m11t4swbt0b0j5w3hn4zbwd0
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 9 files (Router.swift, GatingRecorder.swift, TranscriptReconstruction.swift, TranscriptEvent.swift, TranscriptEntryPayload.swift, and 4 test files)
    - test: green — swift build --build-tests exit 0 with zero warnings from this package; swift test x3, 1052 tests/104 suites + 83 tests/10 suites pass, 2 pre-existing known issues (RealModelHarness.swift:72, BoundedWait.swift:114)
    - commit: 8b9dca1 — 23 files changed, 480 insertions, 361 deletions (local only, no push)
    - review: clean — zero new findings, scope HEAD~1..HEAD, 9 files reviewed
    - next: task is in done. Continue to ^zgn3z1h.
  timestamp: 2026-08-27T14:31:51.947403+00:00
position_column: done
position_ordinal: ffff8a80
title: 'Remove RecordingLevel.metadataOnly: a transcript is full content or off'
---
## What

`RecordingLevel` (`Sources/FoundationModelsRouter/Router.swift:11-18`) has three cases: `off`, `metadataOnly`, `full`. Owner decision (2026-08-27): `metadataOnly` goes. A transcript exists to reload and replay a session, which needs full content; a stripped transcript cannot be reconstructed (`TranscriptEntryMapper.swift:134-136` refuses it with `contentRemoved`), so it serves only as a log — and logging/metrics are OpenTelemetry's job (see ^026kke5), not the transcript's.

Remove the case and the one place that acts on it:

- `Sources/FoundationModelsRouter/Router.swift:14-15`: delete `case metadataOnly` and its doc line. Update the doc at line 10 to "Whether a session's activity is recorded: `off` or `full`." Update the comment at line 193 (`Any trimming (.metadataOnly, .off) or redaction...`) to name only `.off`.
- `Sources/FoundationModelsRouter/Recording/GatingRecorder.swift:69-73`: delete the `.metadataOnly` branch. Rewrite the doc comment at lines 14-30 so it lists two levels (`off` drops; `full` keeps and redacts) and no longer says a text-only gate "would let `metadataOnly` ... leak". Leave `.off` and `.full` behavior byte-for-byte unchanged.
- Do NOT touch `TranscriptEntryPayload.contentRemoved`, its decoding, or the mapper guard: recordings written before this change can carry `"contentRemoved":true` and must still decode and still be refused honestly. Removing the now-unused `strippingContent()` family is the follow-up card that depends on this one.

This is a public API change (an enum case disappears). `RecordingLevel` is `Codable` by raw value, so a stored `"metadataOnly"` config string now fails to decode — that is the intended signal.

Subtasks:

- [x] Tests first: add `recordingLevelHasNoMetadataOnlyCase` to `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift` asserting `RecordingLevel(rawValue: "metadataOnly") == nil` and `Set(RecordingLevel.allCases) == [.off, .full]` (add `CaseIterable` to the enum). Rewrite `TranscriptReconstructionTests.metadataOnlyContentRemovedThrows` (`Tests/FoundationModelsRouterTests/TranscriptReconstructionTests.swift:508-543`) so it no longer builds a `.metadataOnly` router: hand-write one v2 JSONL line whose `entry` is `{"entryId":"e1","contentRemoved":true}` with `kind: "prompt"` into a session directory, the way `TranscriptEventSchemaTests.swift:358-372` hand-writes lines, load with `TranscriptTree.load(under:)`, and keep the two assertions at lines 536-542. Rename it `preExistingContentRemovedPayloadStillThrows`.
- [x] Delete the tests that exist only to exercise the removed level: `MergedAndRedactionTests.swift` lines 176 (`levelMetadataOnlyOmitsBody`), 286 (`metadataOnlyStripsEntryPayloadContent`), 424 (`metadataOnlyWithNilEntryPayload`), 447 (`metadataOnlyEntryPayloadSurvivesJSONLRoundTrip`), 601 (`metadataOnlyWiredThroughRouter`); `RecordingLanguageModelTests.swift:561` (`levelMetadataOnlyStripsBodies`); `SessionSidecarTests.swift:876` (`metadataOnlyStillWritesSidecars`).
- [x] Remove the case from `Router.swift` and the branch from `GatingRecorder.swift`; fix both doc comments.
- [x] Clean build with zero warnings, full `swift test` green.

## Acceptance Criteria

- [x] `grep -rn "metadataOnly" Sources Tests --include=*.swift` returns no match. (One exception: the guard test this card mandates carries the string in its own name and in its `rawValue:` assertion. No usage of the case remains. See the comments.)
- [x] `RecordingLevel.allCases == [.off, .full]` and `RecordingLevel(rawValue: "metadataOnly") == nil`.
- [x] `GatingRecorder.append` at `.off` still forwards nothing and at `.full` with a redact hook still yields `"a *** prompt"` (`MergedAndRedactionTests.redactWiredThroughRouter`, line 634, unchanged and green).
- [x] A hand-written recording line with `"contentRemoved":true` still decodes, and `TranscriptTree.effectiveTranscript(forSession:)` still throws `TranscriptReconstructionError.contentRemoved` for it.
- [x] The checked-in fixture `Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording/**/transcript.jsonl` (which carries `contentRemoved` keys) still loads: `RecordedFixtureRedactionTests` stays green.

## Tests

- [x] `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift`: new `recordingLevelHasNoMetadataOnlyCase`; five `metadataOnly` tests deleted (lines 176, 286, 424, 447, 601).
- [x] `Tests/FoundationModelsRouterTests/TranscriptReconstructionTests.swift`: `preExistingContentRemovedPayloadStillThrows` (rewritten from line 508).
- [x] `Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift:561` and `Tests/FoundationModelsRouterTests/SessionSidecarTests.swift:876` deleted.
- [x] Run `swift build 2>&1` — expected: exit 0, zero warnings (clean build; a cache-hit build hides warnings).
- [x] Run `swift test` — expected: all tests pass. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

Sizing note: six files, but four of the test-file edits are deletions of whole tests; one concern.
#tech-debt #transcript #api