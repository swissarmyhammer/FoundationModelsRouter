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
- actor: claude-code
  id: 01kx4v4xrq3e8vwjyhrv908bzq
  text: |-
    Addressed review finding: renamed `assetIDs` -> `assetIds` in `TranscriptEntryPayload` to match the codebase's established `Id`-suffix convention (`entryId` in the same file; `routerId`/`sessionId`/`parentId` elsewhere).

    Changes:
    - `Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift`: renamed the `assetIDs` property, its doc comment, the `init` parameter/default, the `self.assetIds = assetIds` assignment, the `CodingKeys.assetIds` case, and the `decodeIfPresent(..., forKey: .assetIds)` call.
    - `Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift`: updated both call sites that construct a `TranscriptEntryPayload` with this field (`responseShapeRoundTrips`, `everyFieldPopulatedRoundTrips`).

    Left untouched (out of scope — these are Apple's own SDK naming, not ours):
    - `Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift` — `Transcript.Response(assetIDs: ...)` is Apple's `FoundationModels.Transcript.Response` initializer.
    - `plan.md` — describes Apple's `Transcript.Response{id, assetIDs, segments, metadata}` struct verbatim from the SDK; the one prose mention of our own field name wasn't touched since the task scoped the rename to code/tests only.

    Checked off the review finding checkbox in the task description.

    Verification: `swift build --build-tests` exit 0, `swift test` — 211/211 unit tests pass (gated integration suite correctly skipped, no `FM_ROUTER_INTEGRATION_TESTS`). No other `assetIDs` references remain in Sources or Tests.

    Leaving in `doing` for `/review`.
  timestamp: 2026-07-10T01:44:20.503947+00:00
- actor: claude-code
  id: 01kx4vzrc8pcgh291p62rjk92x
  text: |-
    Addressed the 2026-07-09 20:45 review finding: added a doc comment to `SegmentPayload.encode(to:)` (in Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift) explaining what the hand-written encoding does (writes a `type` discriminator field alongside each case's associated values) and why it's hand-written rather than synthesized — Swift's compiler-generated enum Codable nests each case's payload under a single key named after the case (e.g. `{"text": {...}}`), which doesn't match this format's flat `type` + sibling-keys shape needed for uniform, human-inspectable on-disk JSON across the four segment kinds. The comment cross-references `init(from:)`, which decodes by switching on that same `type` key.

    Checked off the finding in the task description.

    Verification: `swift build --build-tests` exit 0, `swift test` — 211/211 unit tests pass (gated integration/MLX suites correctly skipped, no `FM_ROUTER_INTEGRATION_TESTS`).

    Leaving in `doing` for `/review`.
  timestamp: 2026-07-10T01:58:59.720936+00:00
position_column: doing
position_ordinal: '80'
title: Entry-shaped TranscriptEvent schema v2 with structured payloads
---
## What\n\nExtend the on-disk event schema so one `TranscriptEvent` can faithfully mirror one `FoundationModels.Transcript.Entry` (verified case list in plan.md \"Transcript fidelity\" section: instructions, prompt, toolCalls, toolOutput, response, reasoning; segments: text, structure, attachment, custom). Purely additive — old v1 JSONL lines must still decode.\n\n**Modify** Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:\n- Add `Kind` cases: `instructions`, `toolCalls`, `reasoning`. Keep `toolCall` decodable for old files but mark deprecated in docs (no longer written). Keep `session`, `prompt`, `response`, `toolOutput`, `embedding`.\n- Add `entry: TranscriptEntryPayload?` to `TranscriptEvent` and `TranscriptEvent.Partial` (default `nil`), threaded through `stamped(seq:ts:)` and the text-transform seam.\n\n**New file** Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift — `Codable`, `Sendable`, `Equatable`:\n- `entryId: String` (Apple's `Entry.id`)\n- `contentRemoved: Bool` (default `false`; decodes as `false` when absent) — set by the gating task when `metadataOnly` strips content, so downstream reconstruction can distinguish \"stripped by level\" from \"recorded at full\" and refuse stripped payloads with a typed error\n- `segments: [SegmentPayload]?` — enum with cases `text(id:content:)`, `structure(id:schemaName:contentJSON:)`, `attachment(id:label:url:)`, `custom(id:typeDiscriminator:contentJSON:description:)`. Custom is NOT lossy: `CustomSegment.Content` is protocol-guaranteed `Codable` (verified in the swiftinterface), so the payload carries a type-discriminator string plus the content encoded to JSON — enough to rebuild the real concrete segment via the registry the mapper task defines. `description` is kept as the flattened GUI convenience text alongside, not as the fidelity carrier.\n- `toolDefinitions: [ToolDefinitionPayload]?` (`name`, `description`, `parametersSchemaJSON` — `GenerationSchema` is Codable per the SDK interface)\n- `toolCalls: [ToolCallPayload]?` (`id`, `toolName`, `argumentsJSON` — `GeneratedContent` round-trips via `jsonString`/`init(json:)`)\n- `toolName: String?` (toolOutput), `assetIds: [String]?` (response), `signature: Data?` (reasoning)\n- `options: GenerationOptionsPayload?` (`temperature: Double?`, `maximumResponseTokens: Int?` — the introspectable slice; `sampling` has no public introspection and is documented as dropped)\n- `responseFormatName: String?` and `responseFormatSchemaJSON: String?` (prompt) — the schema JSON is what makes the format *rebuildable*: `Transcript.ResponseFormat` has no `init(name:)`, only `init(schema:)`/`init(type:)` (verified in the swiftinterface), so persisting only a name would make guided-prompt round-trips impossible\n\n## Acceptance Criteria\n- [ ] All new `Kind` cases encode/decode; `toolCall` still decodes\n- [ ] `TranscriptEntryPayload` round-trips through `JSONEncoder`/`JSONDecoder` for every field combination used by the six entry kinds, including `contentRemoved`, `responseFormatSchemaJSON`, and custom-segment `typeDiscriminator`/`contentJSON`\n- [ ] A v1 JSONL line (fixture string with no `entry` field) decodes with `entry == nil`; a payload without `contentRemoved` decodes as `false`\n- [ ] `MergedTranscript.merged(under:)` decodes a directory mixing v1 and v2 lines\n- [ ] `swift build` and `swift test` exit 0\n\n## Tests\n- [ ] Unit in Tests/FoundationModelsRouterTests/RecorderTests.swift (or a new TranscriptEventSchemaTests.swift): per-kind encode/decode round-trips including payloads\n- [ ] Unit: v1 fixture-line decode compatibility, and absent-`contentRemoved` defaulting\n- [ ] Unit: MergedTranscript over mixed v1/v2 files keeps `(ts, seq)` ordering\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.\n\n## Review Findings (2026-07-09 20:00)\n\n- [x] `Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift:50` — Acronym `IDs` is mixed-case (upper) within lowerCamelCase property name. The rule requires acronyms to be uniformly cased — all-upper or all-lower as one unit. In lowerCamelCase context, it should be all-lower. Rename to `assetIds`.\n\n## Review Findings (2026-07-09 20:45)\n\n- [x] `Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift:147` — Public encode(to:) method lacks documentation. This custom Codable conformance implements non-trivial encoding logic with pattern matching across multiple enum cases that requires explanation. Add a documentation comment explaining the custom Codable encoding behavior.\n