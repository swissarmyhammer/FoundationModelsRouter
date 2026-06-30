---
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
- 01KWC5ECCZYEAH49J635KC9QH5
- 01KWC5H7Y7NVG4771FR9ZKW5M0
position_column: todo
position_ordinal: 8f80
title: 'Transcripts: lineage-nested dirs + events + manifest (milestone 10a)'
---
## What
The core recording behavior over the substrate (milestone 5b chokepoint + the recorder protocol/sinks): rich provenance events and on-disk lineage nesting that mirrors the fork tree, plus the router manifest. The merged-view helper and redaction/level gating are milestone 10b. Plan "Transcripts & recording".

- `Sources/FoundationModelsRouter/Recording/` + `Session/`:
  - **Lineage-nested directories (not caller-controllable):** a session's `recordingDirectory` is computed from the `parentID` chain inside the session — `recordings/<routerID>/<rootSession>/<child>/<grandchild>/`. A fork's transcript always lands under its parent regardless of `workingDirectory`. Each session writes its own `transcript.jsonl` (siblings = separate files, no write contention).
  - **Event emission at the chokepoint:** the bracketed `generate` writes `session` (first line, meta), `prompt`, `response`, and (for tool loops) `toolCall`/`toolOutput` events with full provenance `{routerId, sessionId, parentId, slot, model, seq, ts, grammar?, tokensIn, tokensOut, ms}`. (The `embedding` kind is emitted by `RoutedEmbedder.embed` — milestone 5a.) The single recorder actor assigns `seq` + `ts` at append so it produces a globally monotonic `seq` (the basis the milestone 10b merged view reassembles across files); building the cross-file merged view itself is milestone 10b, NOT here.
  - **Manifest:** `recordings/<routerID>/manifest.json` — router config, profiles resolved, start/end. Written by the Router.
  - Appends stay off the hot path + best-effort (a sink failure logs, never fails generation).

## Acceptance Criteria
- [ ] A fork's `transcript.jsonl` is physically nested under its parent's directory; depth mirrors the fork lineage; overriding `workingDirectory` does NOT move the transcript.
- [ ] Each turn emits the correct event `kind` with full provenance; a session's first line is the `session` meta event.
- [ ] Within a single recorder, `seq` is monotonic across concurrent appends from multiple sessions/forks.
- [ ] `manifest.json` records router config + resolved profiles + start/end.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/TranscriptNestingTests.swift` (Swift Testing) with `.jsonl` in a temp dir + `.inMemory`: build root → fork → grandfork, assert directory nesting + parentID chain; assert event kinds + first-line `session` meta; assert monotonic `seq` under concurrent appends; assert manifest contents.
- [ ] Run `swift test --filter TranscriptNestingTests` — all pass.

## Workflow
- Use `/tdd` — write failing nesting, event-kind, seq-monotonic, and manifest tests first.