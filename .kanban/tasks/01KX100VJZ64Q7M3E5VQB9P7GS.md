---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx5h9dd1d84m9ntk7e5r88ta
  text: |-
    Implemented. Production diff is entirely in Sources/FoundationModelsRouter/Session/RoutedSession.swift (plus a one-line persistedEntryCount:0 in RoutedLLM.swift's root-session construction):

    - Added `persistedEntryCount: Int` actor state, threaded through the init (new required param, no default) and set to 0 for root sessions (RoutedLLM.swift) / captured as `backend.transcriptEntries().count` inside the existing serial-gate hold in `fork(workingDirectory:)`, immediately before `makeFork()`, so the read and the fork snapshot can't race.
    - Replaced the hand-built `.prompt`-open/`.response`-close events in `generate(grammar:_:)` with `recordTranscriptDelta(grammar:since:)`: reads `backend.transcriptEntries()`, clamps defensively via `entries[min(persistedEntryCount, entries.count)...]` (never a bare `entries[persistedEntryCount...]`), detects shrink (`entries.count < persistedEntryCount`) and on shrink logs a warning, records nothing, and resets the baseline. Otherwise maps every new entry through `TranscriptEntryMapper.event(from:)` and appends one event per entry (entry payload + flattened text; tokensIn/tokensOut stay nil), stamping `ms` only on the diff's last `.response`-kind event.
    - Streaming (`streamGenerating`) reuses the same `generate` chokepoint, so the diff runs once after the chunk loop completes — no per-chunk events.
    - Throw path: `recordTranscriptDelta` runs with `since: started` on both success and throw; the synthetic bodyless `.response` close is only appended when the diff did *not* already include a `.response`-kind entry, so a turn that fails after the SDK already durably appended a real `.response` (e.g. a post-generation validation/guardrail failure) never gets two `.response` events for one turn.

    Test migration: TranscriptNestingTests.swift gained an instructed-session test proving `.instructions` now appears in the entry-derived sequence (previously silently dropped by the hand-built bracket). SessionChokepointTests.swift's three chokepoint tests gained entry/text/ms assertions. New file TranscriptFidelityTests.swift covers: two-turn entry order+payload, fork-baseline delta (child file has only its own turns, no parent/child leakage either direction), streaming-matches-non-streaming, the shrink-clamp (a `VariableTranscriptBackend` whose `entries` a test drives directly, forcing a mid-session shrink — proven not to crash and to recover cleanly next turn), and the duplicate-`.response` regression the adversarial review caught (see below). Gated integration test added to LanguageModelSessionBackendTests.swift comparing recorded entry kinds to the real `session.transcript` kinds one-for-one against a live tiny model (built by constructing `RoutedSessionActor`/`LanguageModelProfile` directly via their internal/public initializers, bypassing `Router.resolve()`) — could not be executed in this environment (no network/GPU) but builds clean; gated behind `FM_ROUTER_INTEGRATION_TESTS`.

    Adversarial double-check (via really-done) caught one real bug on the first pass: the throwing path unconditionally appended a synthetic bodyless `.response` close even when the SDK's own diff already contained a real `.response` entry, producing two `.response` events for one failed turn. Fixed by having `recordTranscriptDelta` return whether it persisted a `.response`-kind entry this call, and only synthesizing the close when it didn't. Added a regression test (`throwingTurnWithRealResponseEntryRecordsExactlyOneResponseEvent`) that fails against the pre-fix code (would see 4 events instead of 3). Also fixed a stale class-level doc comment describing the old "exactly one open and one close" bracket invariant. Re-verified: build + build-tests + full test suite green (253/253 unit tests, gated suites correctly skipped).

    swift build: exit 0. swift build --build-tests: exit 0. swift test: 253 tests in 28 suites passed + 9 gated tests skipped (0 failures).
  timestamp: 2026-07-10T08:11:16.257925+00:00
depends_on:
- 01KX0ZYTYAV7YM94ZXN39SD1XH
- 01KX0ZZQF8ZHY6R2867RQ92KSK
- 01KX101CBDCFV4EQSPQT0BNK8R
position_column: doing
position_ordinal: '80'
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