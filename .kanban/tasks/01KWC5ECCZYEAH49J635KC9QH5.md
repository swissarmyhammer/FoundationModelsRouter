---
depends_on:
- 01KWC5BTMHH3K50437WBVFG9NT
position_column: todo
position_ordinal: '8880'
title: 'Recording substrate: TranscriptRecorder protocol + sinks + event model'
---
## What
The recording plumbing that sessions are *born holding* (plan "Transcripts & recording"). Built early so the access layer (milestone 5) can take a non-optional recorder with no public way to skip it. Full event emission + lineage nesting come later (milestone 10) — this task is the protocol, sinks, and event type.

- `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift`:
  - `struct TranscriptEvent: Sendable, Codable` with provenance fields: `routerId, sessionId, parentId?, slot?, model?, seq, ts, kind, grammar?, tokensIn?, tokensOut?, ms?` and `enum Kind { session, prompt, response, toolCall, toolOutput, embedding }`.
- `Sources/FoundationModelsRouter/Recording/TranscriptRecorder.swift`:
  - `protocol TranscriptRecorder: Sendable` — the recorder is an actor that **assigns `seq` + `ts` at append** so concurrent forks produce a totally-ordered log. `func append(_ partial: …) async` (the recorder stamps seq/ts).
  - Static factory members `.jsonl`, `.inMemory`, `.none` (a no-op sink) — "off" is a sink, not `nil`.
- `Sources/FoundationModelsRouter/Recording/Sinks.swift`:
  - `JSONLRecorder` (appends `transcript.jsonl` lines; best-effort — a write failure logs, never throws to the caller), `InMemoryRecorder` (collects events for tests), `NoneRecorder` (no-op).
  - `seq` is assigned monotonically by the recorder actor; `ts` from the clock.

## Acceptance Criteria
- [ ] `InMemoryRecorder` records appended events in `seq` order with monotonically increasing `seq` even under concurrent appends from multiple tasks.
- [ ] `JSONLRecorder` writes one JSON object per line to a file; a forced write error is swallowed (logged) and does not throw.
- [ ] `NoneRecorder.append` is a no-op (records nothing) yet shares the identical call path.
- [ ] `TranscriptEvent` round-trips through `Codable` preserving all provenance fields.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/RecorderTests.swift` (Swift Testing): inMemory total ordering under concurrent appends; jsonl line-per-event in a temp dir + swallowed write error; none = empty; event Codable round-trip.
- [ ] Run `swift test --filter RecorderTests` — all pass.

## Workflow
- Use `/tdd` — write failing ordering + sink tests first.