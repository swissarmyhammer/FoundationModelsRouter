---
assignees:
- claude-code
depends_on:
- 01KX0ZYTYAV7YM94ZXN39SD1XH
- 01KX0ZZQF8ZHY6R2867RQ92KSK
- 01KX101CBDCFV4EQSPQT0BNK8R
position_column: todo
position_ordinal: '8580'
title: 'Snapshot-diff persistence: chokepoint records real Transcript entries'
---
## What

Replace the synthesized prompt/response string events with persistence of the SDK's real transcript deltas — the core of the plan.md "Transcript fidelity" design. Depends on the gating task so `GatingRecorder` already strips/redacts structured payloads before the chokepoint starts emitting them (no content-leak window on main). Token metering is deliberately NOT in scope here — it is its own follow-up task. In `RoutedSessionActor` (Sources/FoundationModelsRouter/Session/RoutedSession.swift):

- Add actor state `private var persistedEntryCount: Int`, initialized via a new init parameter: `0` for root sessions; for forks, the parent's `backend.transcriptEntries().count` captured in `fork(workingDirectory:)` inside the serial-gate window it already holds (so inherited history is never re-persisted).
- In `generate(prompt:grammar:_:)`, after `body()` — on the success **and** throw paths — read `backend.transcriptEntries()` and take the new suffix **defensively**: `entries[min(persistedEntryCount, entries.count)...]`, never a bare `entries[persistedEntryCount...]`. Do not assume the SDK transcript is strictly append-only: the SDK ships a `TranscriptErrorHandlingPolicy` that could in principle condense or rewrite a transcript (the router does not opt into it today, but nothing guarantees that forever), and an out-of-bounds range here would trap *inside the recording path* — crashing generation and violating the recording-is-best-effort/never-fails-generation contract. A one-`min()` clamp is chosen over a doc-comment-only append-only assumption precisely because the failure mode of the assumption is a process crash in a path contractually forbidden from failing. If a shrink is detected (`entries.count < persistedEntryCount`), log a warning, record nothing for that turn's diff, and reset `persistedEntryCount = entries.count` so subsequent turns diff from reality. Map each new entry through `TranscriptEntryMapper.event(from:)`, append one event per new entry (envelope: routerId/sessionId/parentId/slot/model/grammar as today; `entry` payload + flattened `text` from the mapper; `tokensIn`/`tokensOut` stay `nil` for now), then advance `persistedEntryCount`. This happens inside the existing serial gate, where the bracket already runs.
- Delete the hand-built `.prompt`-open and `.response`-close content events (`makePartialEvent(kind: .prompt, text: prompt)` / `kind: .response, text: response`). Keep: the lazy `session` meta event; the `ms` measurement (stamp it on the turn's final `.response`-kind entry event); and on the throw path a bodyless `response`-kind event with `ms` and no `entry` so every failed turn still leaves a trace alongside whatever entries the SDK durably appended.
- Streaming (`streamGenerating`): same snapshot-diff after the chunk loop completes — no per-chunk events.
- Rewrite affected expectations in Tests/FoundationModelsRouterTests/TranscriptNestingTests.swift (e.g. `[.session, .prompt, .response]` becomes the entry-derived sequence, including `.instructions` when the stub models an instructed session), SessionChokepointTests.swift, MultiTurnSessionTests.swift, and RecorderTests.swift/MergedAndRedactionTests.swift where their chokepoint-driven expectations shift. This test migration is an unavoidable companion of the behavior change and is acknowledged as the bulk of this task's size; the production diff itself is one file.

## Acceptance Criteria
- [ ] Recorded per-turn content events are derived exclusively from `backend.transcriptEntries()` deltas, not from prompt/response strings
- [ ] A fork's transcript.jsonl contains only entries appended after the fork (baseline = parent count at fork time)
- [ ] The snapshot-diff read is clamped: a transcript shorter than `persistedEntryCount` logs a warning, records no entry events for that turn, and resets the counter — it never traps
- [ ] A throwing turn records whatever entries the SDK kept plus one bodyless `response` close with `ms`
- [ ] Every entry event carries the `entry` payload and flattened `text` (pre-gating); `tokensIn`/`tokensOut` remain `nil`
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] Unit (stub-backed): two turns produce entry events in exact stub-transcript order with correct kinds and payloads
- [ ] Unit: fork after turn 1, then a child turn — child's file has only the child's delta; parent's later turns never leak into the child file (and vice versa)
- [ ] Unit: streaming turn records the same entry events as a non-streaming turn
- [ ] Unit: throwing backend records SDK-retained entries + bodyless close
- [ ] Unit: a stub whose transcript *shrinks* below `persistedEntryCount` between turns does not crash — the turn records no entry events, and a subsequent turn diffs correctly from the new (smaller) baseline
- [ ] Gated integration (`FM_ROUTER_INTEGRATION_TESTS`): after one live turn, recorded entry kinds match `session.transcript` kinds one-for-one

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.