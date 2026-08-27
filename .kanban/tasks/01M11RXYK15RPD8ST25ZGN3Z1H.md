---
assignees:
- claude-code
depends_on:
- 01M11RX5BE681ASCKR8MP4G7Q3
position_column: todo
position_ordinal: '8580'
title: Delete the strippingContent() payload machinery left behind by metadataOnly
---
## What

After ^mp4g7q3 removes `RecordingLevel.metadataOnly`, nothing calls the content-stripping family in `Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift`. Delete it and correct the doc comments that still describe the removed level.

Delete (all in `TranscriptEntryPayload.swift`):

- `TranscriptEntryPayload.strippingContent()` (lines 349-362, under the `// MARK: - Gating: metadataOnly stripping and full-level redaction` header at line 345 — rename the MARK to `Gating: full-level redaction`).
- `SegmentPayload.strippingContent()` (line 424).
- `ToolDefinitionPayload.strippingContent()` (line 464).
- `ToolCallPayload.strippingContent()` (line 471).
- The `contentRemoved: true` construction path only these used. Keep the stored property `contentRemoved`, its `CodingKeys` entry, the `decodeIfPresent ... ?? false` decoding (line 92), and the `contentRemoved:` initializer parameter: recordings written before ^mp4g7q3 can carry `"contentRemoved":true`, and the checked-in fixture `Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording/**/transcript.jsonl` carries the key. Keep `redacted(with:)` (line 374-) unchanged.

Doc comments to correct so they describe a pre-existing recording, not a live level:

- `TranscriptEntryPayload.swift:9-10` and `:15-16` — "`contentRemoved` is `true` in recordings written by a former `metadataOnly` level; reconstruction refuses such a payload."
- `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:74-75` — `text` is `nil` when the event carries no body (router-only kinds), not "after `metadataOnly` trims it".
- `Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift:15-16` and the message at `:38-39` — "stripped by a former recording level".
- `Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift:10` — same wording.

Keep the mapper guard at `TranscriptEntryMapper.swift:134-136` and `TranscriptEntryReconstructionError.contentRemoved`: they are what makes an old stripped recording fail honestly (`TranscriptEntryMapperTests.swift:843`, `TranscriptEventSchemaTests.swift:118,196`, and the rewritten `TranscriptReconstructionTests.preExistingContentRemovedPayloadStillThrows` from ^mp4g7q3 all pin this).

Subtasks:

- [ ] Tests first: in `Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift:349-354` delete the `strippingContent()` assertion at line 352, keep the `redacted(with:)` assertion at line 353, and rename the test `unknownSegmentCarrierRedactsItsDescriptionAsContent`. (A deletion cannot fail first; the "red" here is `grep -rn strippingContent Tests` returning a match until this edit lands.)
- [ ] Delete the four `strippingContent()` functions and the MARK wording in `TranscriptEntryPayload.swift`.
- [ ] Correct the five doc-comment sites listed above.
- [ ] Clean build with zero warnings, full `swift test` green.

## Acceptance Criteria

- [ ] `grep -rn "strippingContent" Sources Tests` returns no match.
- [ ] `grep -rn "metadataOnly" Sources Tests --include=*.swift` returns no match (doc comments included).
- [ ] `TranscriptEntryPayload(entryId: "e1", contentRemoved: true)` still round-trips through `Codable` with `contentRemoved == true`, and a payload JSON without the key still decodes with `contentRemoved == false` (`TranscriptEventSchemaTests` lines 118 and 196, unchanged).
- [ ] `TranscriptEntryMapper.entry(from:kind:)` still throws `.contentRemoved(entryId:)` for a `contentRemoved: true` payload (`TranscriptEntryMapperTests.swift:843`, unchanged).
- [ ] `RecordedFixtureRedactionTests` and the compaction recording fixture load stay green.

## Tests

- [ ] `Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift`: `unknownSegmentCarrierRedactsItsDescriptionAsContent` (rewritten from line 349) asserts only `segment.redacted(with: { _ in "[gone]" }) == .unknown(id: "s1", description: "[gone]")`.
- [ ] Run `swift build 2>&1` — expected: exit 0, zero warnings (clean build; a cache-hit build hides warnings).
- [ ] Run `swift test` — expected: all tests pass. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#tech-debt #transcript #cleanup