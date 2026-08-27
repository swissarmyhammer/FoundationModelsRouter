---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m11w63zhdh7zz9bjbrtnyhsh
  text: |-
    ### Research — picked up

    Every line number on the card is stale. Three commits landed after the card was written (8b9dca1, 916db26, and a merge of upstream work). I found each site by symbol name and checked its current state.

    **One cited edit cannot be made, and it is not a missed step.** The card asks to edit `metadataOnlyWiredThroughRouter` in `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift`. That test no longer exists: the predecessor card ^mp4g7q3 deleted it when it removed `RecordingLevel.metadataOnly`. In that file only `redactWiredThroughRouter` remains, and it still asserts on the embedding event, so it does get the change to `#expect(!events.contains { $0.kind == .embedding })`.

    **The card understates the reach of deleting `TranscriptRecorder.append(_:)`.** The card says "Its only caller was the embedding path". That holds for `Sources`, but twelve test call sites also use the single-argument form:

    - `Tests/FoundationModelsRouterTests/RecorderTests.swift` — 5 sites
    - `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift` — 7 sites

    Each becomes an explicit `to: nil`. The acceptance criterion is written against `Sources` only, so the deletion stands; the test call sites are a mechanical consequence of it.

    **The `RealModelHarness` known issue is unaffected.** `RealModelHarnessTests.embeddingSlotRecordsAnIssueWhenDriven` drives `profile.embedding.container.embed(...)` — the container directly, not `RoutedModel.embed(texts:)`. The recording block sits above the container call, so removing it cannot reach that tripwire. The known issue stays as expected.

    **Kept as the card says.** `TranscriptEvent.Kind.embedding` stays. `TranscriptEntryMapper` and `TranscriptEvent.Kind.isEntryKind` both list it beside `.session`, `.divergence` and `.toolCall`, and `TranscriptTreeTests` hand-writes one into a recording, so old recordings must still decode.
  timestamp: 2026-08-27T15:07:32.209284+00:00
- actor: claude-code
  id: 01m11wj11t5xep8nywh427qa9c
  text: |-
    ### TDD record

    **RED.** I wrote the three test edits first and watched them fail:
    `swift test --filter 'embedRecordsNothing|embedToolCallRecordsNothing|redactWiredThroughRouter'` → `Test run with 3 tests in 3 suites failed ... with 3 issues`. Each failed for the correct cause: the embedding event was still recorded. (A function-name `--filter` does match; only a display-name `--filter` matches nothing.)

    **GREEN.** Then the source change. Full `swift test` passes.

    ### What the diff holds

    Sources:
    - `RoutedEmbedder.swift` — the `started`/`ms` timing and the whole `recorder.append(...)` block are gone; the body is now `try await container.embed(texts: texts)`. Both doc comments are rewritten. `import Foundation` went with the block, because `Date` was the only Foundation use left; the build confirms it.
    - `Recording/TranscriptRecorder.swift` — the single-argument `append(_:)` convenience is deleted. Two DocC links in the protocol's own doc comment named that deleted symbol (``append(_:)``); both now name ``append(_:to:)``, so no link points at a symbol that is gone.
    - `Recording/GatingRecorder.swift` — the doc comment no longer names `RoutedModel/embed(texts:)` as an event source, and no longer says a failure is never surfaced "into generation or embedding".
    - `Recording/TranscriptEvent.swift` — `Kind.embedding` is KEPT. Its doc comment now says it is no longer written and that it stays so recordings made before the change still decode.

    Tests:
    - `ProfileLifecycleTests.swift` — `embedRecordsOneEmbeddingEvent` → `embedRecordsNothing`; `embedSwallowsSinkFailure` deleted.
    - `ToolSharedProfileTests.swift` — `embedToolCallRecordsAnEvent` → `embedToolCallRecordsNothing`.
    - `MergedAndRedactionTests.swift` — `redactWiredThroughRouter` now asserts `#expect(!events.contains { $0.kind == .embedding })`.
    - `RecorderTests.swift` + `MergedAndRedactionTests.swift` — twelve call sites of the deleted single-argument convenience now pass `to: nil`. This is a consequence of the deletion, not a change of scope: the card's own acceptance criterion is written against `Sources` only.

    ### The cited edit that could not be made

    `metadataOnlyWiredThroughRouter` in `MergedAndRedactionTests.swift` no longer exists — the predecessor card ^mp4g7q3 deleted it with `RecordingLevel.metadataOnly`. It is skipped, and this is not a missed step. `redactWiredThroughRouter` is the only test left in that file that asserted on the embedding event, and it did get the change.

    ### Doc statements the change made false, and now corrected

    Each of these claimed the embed path records, so leaving them would be worse than a stale line number:
    - `MergedAndRedactionTests.swift` file doc — no longer says `RoutedModel/embed(texts:)` honors the gate.
    - `redactWiredThroughRouter` display name — "transforms session turn and embedding text" → "transforms session turn text, and an embed records nothing".
    - `sinkFailureSwallowedUnderGating` comment — "both session and embed writes are swallowed" → every session write is swallowed, an embed writes nothing at all. The test itself is unchanged and still passes.
    - `ProfileLifecycleTests.swift` file doc, suite name and one MARK — "recorded embedding" → "embedding access".
    - `ToolSharedProfileTests.swift` file doc — names the generation tool as the one that flows through the recorded chokepoint.

    ### The RealModelHarness known issue

    Unaffected, as researched. `RealModelHarnessTests.embeddingSlotRecordsAnIssueWhenDriven` drives the CONTAINER (`profile.embedding.container.embed(...)`), never `RoutedModel.embed(texts:)`. It still records its one known issue, which is expected.

    ### Verification

    - `swift build --build-tests 2>&1` — exit 0. The only warning is `missing creator for mutated node: ... mlx-swift_Cmlx.bundle`, a pre-existing SwiftPM warning about the vendored MLX bundle, not ours.
    - `swift test` — run three times, each time: `Test run with 1058 tests in 106 suites passed ... with 2 known issues`, plus `Test run with 83 tests in 10 suites passed`. The two known issues are exactly the two documented ones, `RealModelHarness.swift:72` and `BoundedWait.swift:114`. Zero failures.
    - Acceptance greps: `grep -n "recorder" Sources/FoundationModelsRouter/RoutedEmbedder.swift` → no match. `grep -rn "func append(_ partial: TranscriptEvent.Partial) async" Sources` → no match. `case embedding` is still in `TranscriptEvent.swift`.
    - No `ARCHITECTURE.md` in this repo, and no Markdown document describes the embedding recording, so nothing else needs an update.
  timestamp: 2026-08-27T15:14:02.426443+00:00
- actor: claude-code
  id: 01m11wj7wchw7fp8dzddcpa5kq
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/RoutedEmbedder.swift, Sources/FoundationModelsRouter/Recording/TranscriptRecorder.swift, Sources/FoundationModelsRouter/Recording/GatingRecorder.swift, Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift, Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift, Tests/FoundationModelsRouterTests/ToolSharedProfileTests.swift, Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift, Tests/FoundationModelsRouterTests/RecorderTests.swift. `swift build --build-tests` exit 0, zero warnings of ours. `swift test` x3: 1058 tests / 106 suites passed with the 2 documented known issues, plus 83 tests / 10 suites passed. Zero failures.
    - next: `/review`
  timestamp: 2026-08-27T15:14:09.420024+00:00
- actor: claude-code
  id: 01m11wnwn3dp0kd575xmnwckzy
  text: |-
    ### test — green
    - evidence: `swift build --build-tests 2>&1` — exit 0, no compiler warnings from this package (only the pre-existing vendored `mlx-swift_Cmlx.bundle` build-system warning). `swift test` (full suite, no `--filter`) — exit 0, 1058 tests in 106 suites passed with 2 known issues, plus 83 tests in 10 suites passed. Known-issue locations match the documented pre-existing pair exactly: `RealModelHarness.swift:72` and `BoundedWait.swift:114`. No failures, no skipped tests.
    - next: ready for review.
  timestamp: 2026-08-27T15:16:08.995432+00:00
- actor: claude-code
  id: 01m11ww8z497rpj8yx6dcqfw73
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit a66e1e5) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 8 files reviewed; 2 `.kanban/` files excluded by `.reviewignore`.
    - next: task moved to done. No open findings. The dependent card ^026kke5 moves the embed timing and provenance to OpenTelemetry.
  timestamp: 2026-08-27T15:19:38.212597+00:00
- actor: claude-code
  id: 01m11wwv3cdm9401vxf3n6tq9y
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files (RoutedEmbedder.swift, TranscriptRecorder.swift, GatingRecorder.swift, TranscriptEvent.swift, and 4 test files). Two card statements were wrong because three commits landed after the card was written: the cited test `metadataOnlyWiredThroughRouter` no longer exists (^mp4g7q3 deleted it), and `append(_:)` had 12 test call sites, not only the embed path. Both are recorded on the card.
    - test: green — swift build --build-tests exit 0, zero warnings from this package; swift test 1058 tests/106 suites + 83 tests/10 suites pass, 0 failures, 0 skipped, 2 pre-existing known issues (RealModelHarness.swift:72, BoundedWait.swift:114). The count fell from 1059 to 1058 because embedSwallowsSinkFailure was deliberately deleted.
    - commit: a66e1e5 — 10 files changed, 157 insertions, 141 deletions (local only, no push)
    - review: clean — zero new findings, scope HEAD~1..HEAD, 8 files reviewed, 7 validators, 0 failed
    - next: task is in done. ^026kke5 (OpenTelemetry span for embed) is now unblocked.
  timestamp: 2026-08-27T15:19:56.780268+00:00
position_column: done
position_ordinal: ffff8c80
title: 'Remove embed(texts:) from the transcript: drop the .embedding recording path'
---
## What

`Sources/FoundationModelsRouter/RoutedEmbedder.swift:30-51`, `RoutedModel.embed(texts:)` (the `RoutedEmbedder` surface), appends one `TranscriptEvent` of kind `.embedding` per call through `recorder.append(_:)` (line 35). The event does NOT carry the vectors; it carries the **input texts** as its body (line 44, `text: texts.joined(separator: "\n")`) plus the duration. At the default `RecordingLevel.full` every string a caller embeds is copied into `transcript.jsonl` under a fresh random `sessionId`, in the router's root directory.

Decision (owner, 2026-08-27): an embed call is not part of any session's conversation, so it does not belong in the transcript at all. Timing and provenance for embeds move to OpenTelemetry in the follow-up card that depends on this one. This card removes the recording path.

Why it is waste: nothing reads the event back. `Kind.embedding` is not an entry kind (`Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:50`), `TranscriptEntryMapper` refuses it (`Recording/TranscriptEntryMapper.swift:167`), and `TranscriptTree.effectiveEntryEvents` drops it (`Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift:834`). Meanwhile `texts.joined` builds a batch-sized string on every call, the redact hook scans it, and the sink serializes it.

Change:

- `Sources/FoundationModelsRouter/RoutedEmbedder.swift`: delete `started`/`ms` and the whole `recorder.append(...)` block (lines 31-48). The body becomes `try await container.embed(texts: texts)`. Rewrite the doc comments at lines 3-10 and 15-29: `embed` computes through the resident container and records nothing to the transcript; failures propagate.
- `Sources/FoundationModelsRouter/Recording/TranscriptRecorder.swift:47-58`: delete the single-argument `append(_:)` convenience. Its only caller was the embedding path (its own doc comment says so). Every other caller passes `to:` explicitly (`RecordingLanguageModel.swift:372,393`, `RoutedSessionActorRecording.swift:330`, `GatingRecorder.swift:76`).
- `Sources/FoundationModelsRouter/Recording/GatingRecorder.swift:8-9` and `:35`: the doc comment names `RoutedModel/embed(texts:)` as an event source and says failures are never surfaced "into generation or embedding"; remove the embed mentions.
- Keep `TranscriptEvent.Kind.embedding` so recordings written before this change still decode (same reason `Kind.toolCall` is kept, `TranscriptEvent.swift:36-38`). Update its doc comment at line 30 to say it is no longer written.
- Do not change `Router`, `RoutedModel` storage, or any sink.

Subtasks:

- [x] Tests first (all fail before the change): in `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift` rewrite `embedRecordsOneEmbeddingEvent` (line 246) into `embedRecordsNothing` asserting `recorder.events.isEmpty` after `embed(texts: ["a", "b"])`, and delete `embedSwallowsSinkFailure` (line 268), which only exercised the removed path. In `Tests/FoundationModelsRouterTests/ToolSharedProfileTests.swift` `embedToolCallRecordsAnEvent` (line 229): keep the vector assertions, replace lines 243-251 with `#expect(events.isEmpty)`, rename to `embedToolCallRecordsNothing`. In `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift`: `metadataOnlyWiredThroughRouter` (line 601) — replace line 631 with `#expect(!events.contains { $0.kind == .embedding })`; `redactWiredThroughRouter` (line 634) — replace lines 665-667 with `#expect(!events.contains { $0.kind == .embedding })`.
- [x] Remove the recording block from `RoutedEmbedder.swift` and rewrite its doc comments.
- [x] Delete `TranscriptRecorder.append(_:)` and fix the `GatingRecorder` / `Kind.embedding` doc comments.
- [x] Clean build with zero warnings, full `swift test` green.

## Acceptance Criteria

- [x] `grep -n "recorder" Sources/FoundationModelsRouter/RoutedEmbedder.swift` returns no match.
- [x] `grep -rn "func append(_ partial: TranscriptEvent.Partial) async" Sources` returns no match.
- [x] After `profile.embedding.embed(texts: ["a", "b"])` on a router with an `InMemoryRecorder`, `recorder.events` is empty and the call still returns two vectors of `RouterTestFixtures.stubDimension` length.
- [x] After a session turn plus an embed at `.full` with a redact hook, the recorded events contain no `.embedding` kind and the prompt event is still `"a *** prompt"`.
- [x] `TranscriptTreeTests` (lines 815-836), which hand-write a `.embedding` event into a recording, still pass: old recordings decode.

## Tests

- [x] `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift`: `embedRecordsNothing` (rewritten from line 246); `embedSwallowsSinkFailure` (line 268) deleted.
- [x] `Tests/FoundationModelsRouterTests/ToolSharedProfileTests.swift`: `embedToolCallRecordsNothing` (rewritten from line 229).
- [x] `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift`: lines 631 and 665-667 replaced with the "no `.embedding` event" assertion.
- [x] Run `swift build 2>&1` — expected: exit 0, zero warnings (clean build; a cache-hit build hides warnings).
- [x] Run `swift test` — expected: all tests pass. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#tech-debt #performance #transcript