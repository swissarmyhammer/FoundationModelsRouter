---
assignees:
- claude-code
depends_on:
- 01KX0ZZ77H2DJAQJV4PW7DC1ZW
position_column: todo
position_ordinal: '8680'
title: Gate and redact structured entry payloads in GatingRecorder
---
## What

The recording level and redact hook currently only touch the flat `text: String?` (`TranscriptEvent.Partial.mapText`, applied by `GatingRecorder` in Sources/FoundationModelsRouter/Recording/GatingRecorder.swift). With structured `entry` payloads, content now also lives in segments, tool-call arguments, and tool definitions — gating must cover all of it or `metadataOnly`/redaction silently leak content. **This task deliberately lands before the chokepoint starts emitting payloads** (the chokepoint task depends on this one), so there is never a window on main where structured content bypasses the gate.

- Replace `Partial.mapText` (Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift) with a `mapBody(_:)` seam that transforms both `text` and the `entry` payload.
- `RecordingLevel.metadataOnly`: nil out `text` AND strip payload content — text segment `content`, structure `contentJSON`, custom-segment `contentJSON` and `description`, tool-call `argumentsJSON`, tool-definition `description`/`parametersSchemaJSON`, response-format schema JSON, attachment `label`/`url`, reasoning `signature` — while keeping shape: `entryId`, segment ids and case tags, custom-segment `typeDiscriminator`, `toolName`s, `assetIDs` count, and per-kind counts. Stripping sets the payload's `contentRemoved = true` marker (schema task defines it) so reconstruction can *refuse* stripped payloads with a typed error instead of silently rebuilding empty entries. This preserves "shape without content" for GUI structure rendering, per plan.md "Honest fidelity scope".
- `RecordingLevel.full` + redact hook: apply the hook to every textual content site — flattened `text`, text segment `content`, structure `contentJSON` (as an opaque string), custom-segment `contentJSON` (as an opaque string) and `description`, tool-call `argumentsJSON` (as an opaque string), toolOutput segment content, attachment `label`. The custom-segment content JSON gets the same treatment as every other text body — it is user-authored content, not metadata. Document that JSON-valued sites are redacted as whole strings (a hook that must keep JSON valid is the caller's responsibility, consistent with the existing "redact is applied verbatim" tests).
- `RecordingLevel.off` behavior unchanged (drop everything).
- Tests here fabricate `TranscriptEvent.Partial` values directly — no chokepoint involvement needed. Update Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift for the new sites.

## Acceptance Criteria
- [ ] `metadataOnly` events carry no content in `text` or any payload field (including custom-segment `contentJSON`/`description`), keep kinds/ids/tool names/discriminators/counts, and have `contentRemoved == true`
- [ ] The redact hook transforms every textual site listed above at `full`, including custom-segment `contentJSON`; `full` payloads keep `contentRemoved == false`
- [ ] `off` still writes nothing
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] Unit: `metadataOnly` on a fabricated event with segments + tool calls yields shape-only payload with `contentRemoved == true` (assert each stripped field is nil/empty and each kept field survives — including that a custom segment keeps `typeDiscriminator` but loses `contentJSON`)
- [ ] Unit: redact hook replaces a secret appearing in a text segment, a structure contentJSON, a custom-segment contentJSON, and a tool-call argumentsJSON
- [ ] Unit: existing text-only redaction tests still pass unchanged (v1-shape events without payloads)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.