---
assignees:
- claude-code
depends_on:
- 01KZRB8W3SADG2MHP3B2GTD3DM
position_column: todo
position_ordinal: '9880'
title: Replace the mapper's fatalError arms with typed degradation for unknown SDK cases
---
## Problem

Both `@unknown default` arms in the entry mapper call `fatalError` — one for a future `Transcript.Entry` case (Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift:145-152) and one for a future `Transcript.Segment` case (:365-368). The mapping is complete for the macOS 27 SDK only. The day the SDK adds a seventh entry case or a fifth segment case, the router does not degrade — it crashes the host process at record time, in the middle of a user's turn. A recording library must never turn an SDK addition into a crash.

## Proposed solution

1. Add an explicit unknown-carrier to the payload schema: for segments, an `unknown` case that stores the segment's `id` and a best-effort text rendering (the SDK segment's `description`); for entries, an `unknown` payload kind that stores the entry's `id` and flattened text. Both are additive schema changes, mirroring the v1-to-v2 additive rule the schema already follows.
2. At record time, map an unknown case into that carrier and log a warning naming the unrecognized case — the turn completes, the recording keeps its shape, the content is preserved as text.
3. At rebuild time, an unknown carrier becomes a `.text` segment (or a text-only entry) — degraded, visible, and never a crash. Reconstruction stays total.
4. Document the degradation in the mapper doc and in plan.md's fidelity section: unknown future cases record as text, with their exact structure lost until the mapper learns the new case.

## Acceptance

- No `fatalError` remains in the mapper.
- A test simulates an unknown segment (via the carrier's own decode path, since a real unknown SDK case cannot be constructed) and asserts: recorded without crash, rebuilt as the documented text degradation, warning logged.
- Old recordings still decode (additive schema rule holds). #transcript