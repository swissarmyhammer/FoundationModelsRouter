---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
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

- [ ] Tests first (all fail before the change): in `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift` rewrite `embedRecordsOneEmbeddingEvent` (line 246) into `embedRecordsNothing` asserting `recorder.events.isEmpty` after `embed(texts: ["a", "b"])`, and delete `embedSwallowsSinkFailure` (line 268), which only exercised the removed path. In `Tests/FoundationModelsRouterTests/ToolSharedProfileTests.swift` `embedToolCallRecordsAnEvent` (line 229): keep the vector assertions, replace lines 243-251 with `#expect(events.isEmpty)`, rename to `embedToolCallRecordsNothing`. In `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift`: `metadataOnlyWiredThroughRouter` (line 601) — replace line 631 with `#expect(!events.contains { $0.kind == .embedding })`; `redactWiredThroughRouter` (line 634) — replace lines 665-667 with `#expect(!events.contains { $0.kind == .embedding })`.
- [ ] Remove the recording block from `RoutedEmbedder.swift` and rewrite its doc comments.
- [ ] Delete `TranscriptRecorder.append(_:)` and fix the `GatingRecorder` / `Kind.embedding` doc comments.
- [ ] Clean build with zero warnings, full `swift test` green.

## Acceptance Criteria

- [ ] `grep -n "recorder" Sources/FoundationModelsRouter/RoutedEmbedder.swift` returns no match.
- [ ] `grep -rn "func append(_ partial: TranscriptEvent.Partial) async" Sources` returns no match.
- [ ] After `profile.embedding.embed(texts: ["a", "b"])` on a router with an `InMemoryRecorder`, `recorder.events` is empty and the call still returns two vectors of `RouterTestFixtures.stubDimension` length.
- [ ] After a session turn plus an embed at `.full` with a redact hook, the recorded events contain no `.embedding` kind and the prompt event is still `"a *** prompt"`.
- [ ] `TranscriptTreeTests` (lines 815-836), which hand-write a `.embedding` event into a recording, still pass: old recordings decode.

## Tests

- [ ] `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift`: `embedRecordsNothing` (rewritten from line 246); `embedSwallowsSinkFailure` (line 268) deleted.
- [ ] `Tests/FoundationModelsRouterTests/ToolSharedProfileTests.swift`: `embedToolCallRecordsNothing` (rewritten from line 229).
- [ ] `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift`: lines 631 and 665-667 replaced with the "no `.embedding` event" assertion.
- [ ] Run `swift build 2>&1` — expected: exit 0, zero warnings (clean build; a cache-hit build hides warnings).
- [ ] Run `swift test` — expected: all tests pass. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#tech-debt #performance #transcript