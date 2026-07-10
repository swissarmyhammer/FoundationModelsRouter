---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx4r2w5brv1e76rqgvxv6rv0
  text: |-
    Implemented via TDD.

    **Changes:**
    - `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift`: added `Kind` cases `instructions`, `toolCalls`, `reasoning`; kept `toolCall` decodable (doc-marked deprecated, no longer written) plus `session`/`prompt`/`response`/`toolOutput`/`embedding`. Added `entry: TranscriptEntryPayload?` (default `nil`) to both `TranscriptEvent` and `TranscriptEvent.Partial`, threaded through `Partial.mapText` (passed through unchanged — gating `entry`'s own content is explicitly a downstream task) and `Partial.stamped(seq:ts:)`.
    - New `Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift`: `TranscriptEntryPayload` (Codable/Sendable/Equatable) with `entryId`, `contentRemoved` (custom `init(from:)` defaults to `false` when absent, `encode(to:)` left to synthesis), `segments: [SegmentPayload]?`, `toolDefinitions`, `toolCalls`, `toolName`, `assetIDs`, `signature: Data?`, `options: GenerationOptionsPayload?`, `responseFormatName`, `responseFormatSchemaJSON`. `SegmentPayload` enum with hand-written Codable (`type` discriminator) for `.text`, `.structure(schemaName: non-optional)`, `.attachment(label/url optional)`, `.custom(typeDiscriminator/contentJSON/description optional)`. Plus small `ToolDefinitionPayload`, `ToolCallPayload`, `GenerationOptionsPayload` structs.
    - New `Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift`: 25 tests — new Kind round-trips, legacy `toolCall` decode, v1-no-`entry`-field decode (`entry == nil`), `entry` threading through `mapText`/`stamped`, `contentRemoved` default-false/true round trips, per-entry-kind payload round trips (all six kinds), all four segment shapes incl. nil url/description, a kitchen-sink all-fields round trip, two negative-path decode tests (missing/unknown segment `type` discriminator throws), and `MergedTranscript.merged(under:)` over a directory mixing a hand-written v1 line and a real v2-encoded line.

    **Scope respected:** no mapper (`Transcript.Entry` <-> `TranscriptEntryPayload`), no `CustomSegmentRegistry`, no `RoutedSession` recording changes — confirmed no production `switch` over `TranscriptEvent.Kind` exists anywhere, and `RoutedSession.makePartialEvent`/`RoutedEmbedder` still only stamp the pre-existing kinds with `entry` defaulting to `nil`.

    **Verification:** `swift build` exit 0, `swift build --build-tests` exit 0, `swift test` — 211/211 unit tests pass (209 pre-existing + new schema suite grew from 23 to 25 tests after adding two negative-path decode tests), gated integration suite correctly skipped (no `FM_ROUTER_INTEGRATION_TESTS`). Ran the `double-check` adversarial review (via `really-done`): initial verdict REVISE with one low-severity, non-blocking finding (no negative-path test for malformed `SegmentPayload` JSON) — fixed by adding the two negative-path tests above; re-verified green.

    Leaving in `doing` for `/review`.
  timestamp: 2026-07-10T00:50:47.595823+00:00
position_column: doing
position_ordinal: '80'
title: Entry-shaped TranscriptEvent schema v2 with structured payloads
---
## What

Extend the on-disk event schema so one `TranscriptEvent` can faithfully mirror one `FoundationModels.Transcript.Entry` (verified case list in plan.md "Transcript fidelity" section: instructions, prompt, toolCalls, toolOutput, response, reasoning; segments: text, structure, attachment, custom). Purely additive — old v1 JSONL lines must still decode.

**Modify** Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:
- Add `Kind` cases: `instructions`, `toolCalls`, `reasoning`. Keep `toolCall` decodable for old files but mark deprecated in docs (no longer written). Keep `session`, `prompt`, `response`, `toolOutput`, `embedding`.
- Add `entry: TranscriptEntryPayload?` to `TranscriptEvent` and `TranscriptEvent.Partial` (default `nil`), threaded through `stamped(seq:ts:)` and the text-transform seam.

**New file** Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift — `Codable`, `Sendable`, `Equatable`:
- `entryId: String` (Apple's `Entry.id`)
- `contentRemoved: Bool` (default `false`; decodes as `false` when absent) — set by the gating task when `metadataOnly` strips content, so downstream reconstruction can distinguish "stripped by level" from "recorded at full" and refuse stripped payloads with a typed error
- `segments: [SegmentPayload]?` — enum with cases `text(id:content:)`, `structure(id:schemaName:contentJSON:)`, `attachment(id:label:url:)`, `custom(id:typeDiscriminator:contentJSON:description:)`. Custom is NOT lossy: `CustomSegment.Content` is protocol-guaranteed `Codable` (verified in the swiftinterface), so the payload carries a type-discriminator string plus the content encoded to JSON — enough to rebuild the real concrete segment via the registry the mapper task defines. `description` is kept as the flattened GUI convenience text alongside, not as the fidelity carrier.
- `toolDefinitions: [ToolDefinitionPayload]?` (`name`, `description`, `parametersSchemaJSON` — `GenerationSchema` is Codable per the SDK interface)
- `toolCalls: [ToolCallPayload]?` (`id`, `toolName`, `argumentsJSON` — `GeneratedContent` round-trips via `jsonString`/`init(json:)`)
- `toolName: String?` (toolOutput), `assetIDs: [String]?` (response), `signature: Data?` (reasoning)
- `options: GenerationOptionsPayload?` (`temperature: Double?`, `maximumResponseTokens: Int?` — the introspectable slice; `sampling` has no public introspection and is documented as dropped)
- `responseFormatName: String?` and `responseFormatSchemaJSON: String?` (prompt) — the schema JSON is what makes the format *rebuildable*: `Transcript.ResponseFormat` has no `init(name:)`, only `init(schema:)`/`init(type:)` (verified in the swiftinterface), so persisting only a name would make guided-prompt round-trips impossible

## Acceptance Criteria
- [ ] All new `Kind` cases encode/decode; `toolCall` still decodes
- [ ] `TranscriptEntryPayload` round-trips through `JSONEncoder`/`JSONDecoder` for every field combination used by the six entry kinds, including `contentRemoved`, `responseFormatSchemaJSON`, and custom-segment `typeDiscriminator`/`contentJSON`
- [ ] A v1 JSONL line (fixture string with no `entry` field) decodes with `entry == nil`; a payload without `contentRemoved` decodes as `false`
- [ ] `MergedTranscript.merged(under:)` decodes a directory mixing v1 and v2 lines
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] Unit in Tests/FoundationModelsRouterTests/RecorderTests.swift (or a new TranscriptEventSchemaTests.swift): per-kind encode/decode round-trips including payloads
- [ ] Unit: v1 fixture-line decode compatibility, and absent-`contentRemoved` defaulting
- [ ] Unit: MergedTranscript over mixed v1/v2 files keeps `(ts, seq)` ordering

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.