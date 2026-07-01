---
comments:
- actor: wballard
  id: 01kwex1v7c2yzjeqjny9a8rmv3
  text: |-
    Implemented milestone 10a (TDD). Summary of the build:

    NESTING (derived from parentId chain): `RoutedSessionActor.fork` now nests the child's `recordingDirectory` directly UNDER the parent's (`recordingDirectory.appendingPathComponent(childId)`), replacing the old flat sibling layout (`deletingLastPathComponent().appending(childId)`). Root stays `<recordingsDir>/<routerId>/<rootId>/` (from makeSession); fork → `.../<rootId>/<childId>/`; grandfork one deeper. `workingDirectory` override never affects `recordingDirectory`.

    RECORDER ROUTING + GLOBAL SEQ: `TranscriptRecorder.append` gained `to directory: URL?` (with a convenience `append(_:)` extension forwarding `to: nil` so the embedder/existing callers are unchanged). `JSONLRecorder` keeps ONE `seq` counter but a `[path: FileHandle]` map, so it routes each event to that session's own `transcript.jsonl` while producing one globally-monotonic seq. InMemory/None ignore the directory.

    EVENTS AT CHOKEPOINT: `generate` now emits a first-line `.session` meta event once per session (lazy, flag-guarded before the await so reentrancy can't double-emit), routes every append to `recordingDirectory`, and stamps measured `ms` on the `.response` close event. Kinds per turn: `[.session, .prompt, .response]`.

    MANIFEST: new `RouterManifest` (Codable) written by the Router to `<recordingsDir>/<routerId>/manifest.json` on each successful resolve — router config (headroomReserve, maxConcurrentForks, recordingLevel), resolved profiles (name + chosen std/flash/embedding refs), and start (init)/end (write time). Best-effort. `RecordingLevel` is now `String, Codable, Equatable`.

    Updated stale event-kind expectations in SessionChokepoint/GuidedGeneration/GuidedShapes/ToolIntegration tests to include the leading `.session` line (intentional behavior change per this milestone).

    Tests: `Tests/.../TranscriptNestingTests.swift` (5 tests) green. Full `swift test` green (101 tests, 0 failures/warnings). Task left in `doing`.
  timestamp: 2026-07-01T13:14:19.244091+00:00
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
- 01KWC5ECCZYEAH49J635KC9QH5
- 01KWC5H7Y7NVG4771FR9ZKW5M0
position_column: doing
position_ordinal: '80'
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