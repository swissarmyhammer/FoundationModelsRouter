---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzvpy2q79a7ds14rg9c1hcb8
  text: |-
    Research findings (probes against the macOS 27 FoundationModels swiftinterface and small compiled probe programs):

    - `GeneratedContent(json:)` gives a structure ARBITRARY ordered keys (dictionary order, not sorted and not document order), at every depth. The persisted `jsonString` is the only carrier of the true order, so the fix must scan the JSON text for the document key order and rebuild each structure node with `GeneratedContent(kind: .structure(properties:orderedKeys:))`.
    - `GeneratedContent ==` compares more than the kind: a json-parsed structure is NOT equal to a live one even with identical ordered keys. A rebuild through `init(kind:)` restores equality. Scalars and arrays parse to equality directly; only structure nodes (also structure nodes inside arrays) need the rebuild.
    - `GeneratedContent ==` compares the `GenerationID`. A `@Generable` value's `generatedContent` has a nil id, so live tool-output structure content is rebuildable; only tool-call arguments carry a `GenerationID` (permanent loss, as the card says).
    - `Transcript.Response(id:assetIDs:segments:)` stamps `metadata["assetIDs"]` even for an EMPTY array. `Transcript.Response(id:segments:)` (macOS 27, metadata default `[:]`) does not, and the two responses are NOT equal. The fix must branch on empty persisted assetIds.
    - Ripple: every live-side fabricator and test literal that builds a response with `assetIDs: []` carries the stamped key, and full-equality comparisons against a mapper rebuild will break after the fix. The sweep must move all empty-assetIDs `Transcript.Response` constructions (Sources and Tests) to the metadata-less initializer, so both sides of each comparison stay consistent. Non-empty assetIDs sites keep the assetIDs initializer, and the synthesis for the non-empty case stays a pinned contract.
    - Production fabricators that must move with the sweep: the fold-checkpoint entry in Compaction/CompactionSegment.swift and the unknown-kind rebuild in the mapper.
  timestamp: 2026-08-12T19:24:37.479933+00:00
- actor: claude-code
  id: 01kzvwcxmtrwpvbgb5n94nryqm
  text: |-
    Implementation landed (TDD: red observed on the two new tests and the changed pin, then green).

    What changed:
    - NEW Sources/FoundationModelsRouter/Recording/OrderPreservingGeneratedContentDecoder.swift: decodes persisted GeneratedContent JSON with the document's object key order intact. `GeneratedContent(json:)` reports a structure's orderedKeys in arbitrary dictionary order (probed: not sorted, not document order), so a small scanner extracts the document key order at every depth and each structure node is rebuilt through `GeneratedContent(kind:)` — the rebuild is also what restores equality with a live structure. Scalars and arrays with no structure beneath stay as parsed. A failed scan degrades to the plain parse.
    - TranscriptEntryMapper: `decodeGeneratedContent` now goes through the new decoder (structure segments AND tool-call arguments); `rebuildResponse` branches — empty persisted assetIds rebuilds through `Transcript.Response(id:segments:)` (no synthesized `metadata["assetIDs"]` key), non-empty keeps the assetIDs initializer (synthesis stays pinned contract); the unknown-kind rebuild also uses the metadata-less initializer; the type doc's degradation section now states the conditional synthesis, the kept property order, and the permanent GenerationID loss on tool-call arguments.
    - CompactionSegment.boundaryEntry: the fold checkpoint entry now uses the metadata-less initializer, so a restored boundary equals the live one.
    - RestoreFidelityTests.canonicalized(_:) tightened: only `.toolCalls` entries go through the mapper round trip (the GenerationID facet); every other entry is compared RAW against the reconstruction. Docs updated from three facets to one.
    - Tests: new `structuredSegmentKeepsPropertyOrder` (order kept, nested-in-array case included) and `responseWithoutAssetIDsRebuildsWithoutSynthesizedMetadata`; `responseMetadataIsDropped` now asserts an EMPTY rebuilt metadata dictionary; new `responseWithAssetIDsSynthesizesMetadataKey` pins the non-empty case.
    - Sweep: every test/helper construction of `Transcript.Response(assetIDs: [], ...)` moved to the metadata-less initializer (18 test files + StubSessionBackend/TranscriptTestHelpers), so live fabricators match what a real generated response carries and full-equality restore comparisons stay consistent.
    - Fixture correction found during the green step: three pre-existing fixtures built tool-call arguments / structure content with `GeneratedContent(json:)`. A json-parsed GeneratedContent NEVER compares equal to the rebuilt live form (SDK equality has an internal marker beyond kind — probed), so those fixtures moved to `GeneratedContent(properties:)`, the live shape (TranscriptEntryMapperTests x3, CompactionSpikeTests x1).

    What did not work / discoveries:
    - `GeneratedContent(json:)` gives dictionary-order orderedKeys at EVERY depth; only the JSON text carries the true order.
    - `Transcript.Response(assetIDs: [], ...)` stamps `metadata["assetIDs"] = []`; `Transcript.Response(id:segments:)` does not, and the two are not equal.
    - The persisted schema did not change: both fixes are rebuild-side only (v2 additive rule intact).

    Verification: `swift build --build-tests` clean; one full ungated `swift test`: 894 tests in 84 suites passed (1 pre-existing known issue in BoundedWait via withKnownIssue), plus 27 ungated integration-target tests and 24 evals tests, zero failures. No push, no formatter, vendored fork untouched.
  timestamp: 2026-08-12T21:00:06.682137+00:00
- actor: claude-code
  id: 01kzvwd8dy8xx8ndzrqrfd1ywf
  text: |-
    ### implement — changed
    - evidence: 23 files — new Sources/FoundationModelsRouter/Recording/OrderPreservingGeneratedContentDecoder.swift; Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift; Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift; 20 test files (TranscriptEntryMapperTests, RestoreFidelityTests, CompactionSpikeTests, and the empty-assetIDs sweep). One full ungated `swift test`: 894 + 27 + 24 tests passed, 0 failures, 0 skipped-by-change (1 pre-existing withKnownIssue in BoundedWait).
    - next: /review the task; the card stays in doing.
  timestamp: 2026-08-12T21:00:17.726617+00:00
- actor: claude-code
  id: 01kzvxsbhfbpshat1ph2hzbxte
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 5921ebb). The engine gave 7 findings. All 7 findings ask for a refactor of test code that was in the repository before this commit, and no finding is on a line that this commit changed. The written waiver for existing tests drops all 7 findings. Dropped: AutoCompactionTests.swift:487 (assignOnlyProperty lastBackend); ExamplesTests.swift:535 (StubModelLoader duplicate); TranscriptReconstructionTests.swift:201, 208, 214, 280, 357 (shared stub and helper deduplication). Zero findings stay open. The card has no unchecked review items.
    - next: none. The task moved doing → review → done.
  timestamp: 2026-08-12T21:24:22.703986+00:00
- actor: claude-code
  id: 01kzvxt8jk57asynr6s3gyjrhc
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 23 files; new OrderPreservingGeneratedContentDecoder keeps structure key order; empty-assetIds responses rebuild with no synthesized metadata key; GenerationID loss documented as permanent; canonicalized(_:) tightened to .toolCalls only
    - test: green — swift test, 894 + 27 + 24 tests passed, 0 failures (the one implement run is the test evidence)
    - commit: 5921ebb
    - review: clean — 7 findings, all waived (pre-existing tests, no flagged line changed by this commit); task moved to done
  timestamp: 2026-08-12T21:24:52.435756+00:00
position_column: done
position_ordinal: ff9c80
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