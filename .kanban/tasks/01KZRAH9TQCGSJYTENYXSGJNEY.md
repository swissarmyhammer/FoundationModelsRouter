---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kztn789av0vz41mddzmr5wq2
  text: |-
    Research done. SDK facts from the macOS 27.0 swiftinterface (FoundationModels.framework):

    1. toolCallingMode: `GenerationOptions.toolCallingMode: ToolCallingMode?` is public (macOS 27+). `ToolCallingMode.kind: Kind` is public with three cases: allowed, required, disallowed. `Kind` is Equatable. The initializer `GenerationOptions(samplingMode:temperature:maximumResponseTokens:toolCallingMode:)` is public (macOS 27+). The package targets macOS 27.0. Decision: persist the mode as a new optional `toolCallingMode` field on `GenerationOptionsPayload` (a three-case string enum) and rebuild it. This is additive in schema v2, the same rule as the ^ne5g9jn envelope. A future `Kind` case records as absent, with a warning log. This is a new documented degradation.

    2. responseFormatName: `Transcript.ResponseFormat` has only `init(type:)` and `init(schema:)`. Its `name` is a get-only computed property. No initializer accepts a name. Deletion of the field is not possible: the field is a public stored property and a public initializer parameter, and the standing constraints forbid public API breaks. Decision: keep the field and give the rebuilder a real read of it. When a payload has a name but no schema JSON (the shape a future ResponseFormat.Kind case records), rebuild logs a warning that names the lost format and rebuilds the prompt without a response format. Tests pin this, and pin that a rebuilt format's `name` equals the persisted `responseFormatName`.

    3. custom segment description: `CustomSegment.description` is a computed property of the conforming type. `PersistableCustomSegment.init(id:content:)` accepts no description. Decision: the conforming type's own `description` is authoritative at rebuild. The persisted description is a reader convenience only. Document this and pin it with a test that gives the payload a different description.

    4. response metadata synthesis: on macOS 27, `Transcript.Response.metadata` reads `_metadata`, and `init(assetIDs:segments:)` synthesizes a `metadata["assetIDs"]` key. Decision: state this as contract in the mapper doc and extend the existing metadata test to assert the synthesized key is present.

    5. jsonString: change `jsonString(for:)` to `jsonString(for:context:)` which throws a typed internal error, `TranscriptEntryEncodingError.encodingFailed(context:underlying:)`. `event(from:)` and `segmentPayload(_:)` stay non-throwing because all callers (TranscriptDiffer, RoutedSessionActorRecording, RoutedSessionActorRunJournal, Compactor) are best-effort record paths. At the seam, a catch logs at fault level with the context and the typed error, and the field persists the empty-string sentinel. The empty string is the safe sentinel: it can never decode as valid content, so restore always refuses it instead of rebuilding wrong content. The mapper doc states this. A test covers the typed throw directly, and a test covers the sentinel plus the fault log through a custom segment whose content holds Double.infinity.
  timestamp: 2026-08-12T09:35:26.506165+00:00
- actor: claude-code
  id: 01kzts0ytht0892m6cqznyg266
  text: |-
    Implementation done, TDD. The RED phase was confirmed by compile diagnostics against the new API (`ToolCallingModePayload`, `TranscriptEntryEncodingError`, `jsonString(for:context:)` did not exist). Then the GREEN phase made all tests pass.

    What landed:

    1. toolCallingMode round-trips. `GenerationOptionsPayload` gains the optional `toolCallingMode` field (new public enum `ToolCallingModePayload`: allowed, required, disallowed). Encode maps `GenerationOptions.toolCallingMode.kind`; an unknown future `kind` records as nil with a warning log. Rebuild uses `GenerationOptions(samplingMode:temperature:maximumResponseTokens:toolCallingMode:)`. Additive within schema v2; the v2 doc in RecordingSchemaVersion.swift records it. Tests: `toolCallingModePersistsAndRebuilds` (all three modes, payload value and rebuilt value) and `promptRoundTrips` now includes `.required`.

    2. responseFormatName is no longer write-only. The rebuilder reads it: a payload with a name but no schema JSON rebuilds without a response format, and the rebuild logs a warning that names the lost format. The mapper doc states the contract: the schema JSON is the fidelity carrier; the persisted name is the reader-facing copy that survives metadataOnly stripping. Tests: `nameOnlyResponseFormatDegradesToNilAndWarns` (new) and `typeBuiltResponseFormatRebuildsInSchemaForm` now asserts the rebuilt format name equals `payload.responseFormatName`.

    3. Custom-segment description authority is documented and pinned. The rebuild arm has a comment, the mapper doc states the contract, and the new test `customSegmentRebuildsWithTheTypesOwnDescription` gives the payload a doctored description and asserts the rebuilt segment carries the type's own description.

    4. Response metadata synthesis is contract. The mapper doc states that `Response(id:assetIDs:segments:)` synthesizes `metadata["assetIDs"]`, and `responseMetadataIsDropped` now asserts the synthesized key is present, not only the original key's absence.

    5. Encode failure is loud and typed. New internal error `TranscriptEntryEncodingError.encodingFailed(context:underlying:)`. `jsonString(for:context:)` throws it at the cause. The non-throwing seam `jsonStringOrSentinel(for:context:)` catches it, logs at fault level, and persists the empty-string sentinel; `event(from:)` and `segmentPayload(_:)` stay non-throwing for the best-effort record path (TranscriptDiffer, RoutedSessionActorRecording, RoutedSessionActorRunJournal, Compactor). All three encode sites route through the seam. Tests: `jsonStringThrowsATypedEncodeError` (Double.infinity) and `unencodableCustomContentRecordsSentinelAndLogs` (sentinel plus fault log through OSLogStore).

    plan.md "Honest fidelity scope" now lists every one of these: the metadata["assetIDs"] synthesis, the name-only format degradation, the toolCallingMode round-trip and its future-kind degradation, the description authority, and the encode-failure sentinel. Test helper `assertWarningLogged` was renamed to `assertLogged` because it now also proves fault entries.

    Files: Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift, Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift, Sources/FoundationModelsRouter/Recording/RecordingSchemaVersion.swift, Tests/FoundationModelsRouterTests/TranscriptEntryMapperTests.swift, plan.md.

    Verification: one full ungated `swift test` — 926 tests passed (875 + 27 + 24 across the three targets), zero failures. The one known issue is the accepted BoundedWait item; the mlx "missing creator" warning is the accepted noise.
  timestamp: 2026-08-12T10:41:54.513377+00:00
- actor: claude-code
  id: 01kzts1d51cy96j7wxh98a8ejd
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift, Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift, Sources/FoundationModelsRouter/Recording/RecordingSchemaVersion.swift, Tests/FoundationModelsRouterTests/TranscriptEntryMapperTests.swift, plan.md; `swift test` passed 926 tests with zero failures (875 + 27 + 24)
    - next: review
  timestamp: 2026-08-12T10:42:09.185565+00:00
depends_on:
- 01KZRB8W3SADG2MHP3B2GTD3DM
position_column: doing
position_ordinal: '8180'
title: Close the undocumented field gaps in the transcript entry mapping
---
## Problem

The entry mapper covers every entry kind and segment kind, and it documents most of its deliberate losses. Four field-level gaps sit outside that documented ledger, with no doc claim and no test:

1. **`GenerationOptions.toolCallingMode` vanishes silently.** plan.md names it as public SDK surface, but `GenerationOptionsPayload` has no field for it (Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift:313-336), it is absent from the deliberate-loss list, and no test mentions it. It affects how a recorded turn behaved, so losing it silently is worse than the documented losses.
2. **`responseFormatName` is write-only.** It is persisted at encode (Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift:106) and never read by any rebuilder.
3. **A `.custom` segment's persisted `description` is discarded at rebuild** (the `_` at TranscriptEntryMapper.swift:415).
4. **`.response` rebuild can ADD metadata**: the `assetIDs:` initializer synthesizes a `metadata["assetIDs"]` key the original entry may not have had. A test comment acknowledges this (TranscriptEntryMapperTests.swift:305-309); nothing states it as contract.

One related silent hazard in the same file: `jsonString(for:)` returns `""` on encode failure (TranscriptEntryMapper.swift:503-508). The empty string persists without error and surfaces at restore as an `invalidJSON` throw, far from the cause.

## Proposed solution

1. `toolCallingMode`: persist it in `GenerationOptionsPayload` and rebuild it — or, if its type cannot round-trip, add it to plan.md's deliberate-loss list, the mapper doc, and a pinning test. Decide, then do one.
2. `responseFormatName`: use it at rebuild if it has a purpose; delete the field if it has none. Do not keep a write-only field.
3. `.custom` `description`: pass the persisted description through to the rebuilt segment, or document that the conforming type's own `description` is authoritative and add a test.
4. `.response` metadata synthesis: document the behavior as contract in the mapper doc comment and pin it with an explicit test (assert the synthesized key's presence, not only the original key's absence).
5. `jsonString(for:)`: throw a typed encode error instead of returning `""`, so the failure surfaces at record time, at the cause.

## Acceptance

- No undocumented field loss remains: every dropped field appears in plan.md's loss list, the mapper doc, and a pinning test.
- No write-only persisted field remains.
- An encode failure fails loudly at record time with a typed error, covered by a test. #transcript