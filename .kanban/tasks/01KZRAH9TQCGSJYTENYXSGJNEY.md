---
assignees:
- claude-code
depends_on:
- 01KZRB8W3SADG2MHP3B2GTD3DM
position_column: todo
position_ordinal: '9780'
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