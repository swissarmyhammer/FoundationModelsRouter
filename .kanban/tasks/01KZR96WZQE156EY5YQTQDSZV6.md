---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: Carry full tool output segments in ToolCallEntry
---
## Problem

`SessionProjection.ToolCallEntry.summary` holds flattened text only — the `summary` string from `SessionEvent.toolStatus(id:status:summary:)`. The `.toolOutput` entry's real segments are lost on the way: `.structure` (schema-named JSON), `.attachment`, and `.custom` segments never reach the projection. A UI cannot render a structured tool result, show an attachment, or display a custom segment. It can only show a flat string.

## Proposed solution

1. Add an output field to `ToolCallEntry`, for example `output: [SegmentPayload]?`. `SegmentPayload` (Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift:155) is already `Sendable`, `Codable`, and `Equatable`, and covers all four segment kinds. Populate it when the call completes. Keep `summary` as the flat-text convenience.
2. Extend the event vocabulary so the segments can travel: let `SessionEvent.toolStatus` carry the segments (or add a payload case). Keep the current cases decodable and the current consumers working.
3. Make the cold-seed path (task ^5aky6xr, "Seed SessionProjection from a cold Transcript") fill the same field from the `.toolOutput` entry's segments, so live and seeded rows carry equal data.

## Acceptance

- A completed tool call with a `.structure` segment must surface that segment in the projection row, with its schema name and content JSON intact.
- `summary` must stay equal to the flattened text it carries today.
- Tests must cover text, structure, and custom segment outputs on both the live path and the seeded path. #projection