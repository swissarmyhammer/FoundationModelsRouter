---
assignees:
- claude-code
position_column: todo
position_ordinal: a580
title: 'Mapper fidelity: keep GeneratedContent property order and stop synthesizing assetIDs metadata on rebuild'
---
## Problem

Task ^810gdjj's restore-fidelity tests compared a live tool turn's transcript (real MLXFoundationModelsSessionBackend) with the transcript reconstructed from disk, entry for entry. Three facets of a live entry do not survive TranscriptEntryMapper's round trip today:

1. **GeneratedContent property order is dropped.** A live `.structure` segment's `GeneratedContent` carries `order: ["marker"]`; the mapper persists `content.jsonString` and rebuilds with `GeneratedContent(json:)`, which reports `order: nil`. `Transcript.StructuredSegment` equality compares the order, so the rebuilt segment is not equal to the live one. The SDK CAN represent this: `GeneratedContent(kind: .structure(properties:orderedKeys:), id:)` accepts ordered keys, so the mapper can rebuild with the order the persisted JSON already carries.
2. **A rebuilt `.response` entry synthesizes a `metadata["assetIDs"]` key.** The mapper rebuilds every response through the `assetIDs:`-based initializer, which stamps `metadata["assetIDs"]` — a key a live generated response with no asset ids never carries (`_metadata: 0 pairs`). When the persisted `assetIds` is empty, the mapper can rebuild through an initializer that does not synthesize the key. `TranscriptEntryMapperTests.responseMetadataIsDropped` pins the current synthesis and must change with the fix.
3. **Tool-call arguments lose their `GenerationID` — NOT fixable.** A live `Transcript.ToolCall.arguments` carries `id: GenerationID(value: <call id>)`. `GenerationID`'s only public constructor is `init()` (random), and it is not Codable, so no persisted form can rebuild the same id. Document this as a known, unrepresentable degradation next to the sampling/metadata degradations; do not attempt a fix.

## Proposed solution

- Rebuild structured `GeneratedContent` with its persisted key order through `GeneratedContent(kind: .structure(properties:orderedKeys:))` (item 1).
- Rebuild a `.response` whose persisted `assetIds` is empty through the non-synthesizing initializer (item 2).
- Document item 3 as a permanent degradation.
- Then strengthen `RestoreFidelityTests.richToolTurnRestoresFromDiskEqualToLiveTranscript`: after items 1 and 2, the only remaining live-vs-restored difference is the `GenerationID`, so the canonical-form comparison can tighten accordingly.

## Acceptance

- A live `.structure` segment round-trips to an equal `Transcript.StructuredSegment` (order kept).
- A rebuilt `.response` with empty persisted `assetIds` carries no synthesized `metadata["assetIDs"]` key and equals a live text response entry.
- The `GenerationID` degradation is documented where the mapper documents its other degradations. #transcript