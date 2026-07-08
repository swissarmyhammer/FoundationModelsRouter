---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
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