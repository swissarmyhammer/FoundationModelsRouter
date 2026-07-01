---
comments:
- actor: wballard
  id: 01kwezhbbjwdgkds1yqas728m3
  text: |-
    Picked up (doing). Research done. Plan:
    - Milestone 10a events (TranscriptEvent/Partial) carry NO body text field yet, so `full` vs `metadataOnly` can't differ. Adding `text: String?` (default nil) to TranscriptEvent + Partial + stamped() is in scope; thread prompt/response text through RoutedSession.generate chokepoint and input text through RoutedEmbedder.embed.
    - Gating: new GatingRecorder decorator (Recording/GatingRecorder.swift) wraps any sink; off=drop, metadataOnly=nil the text (keep counts/kinds/provenance), full=keep text applying redact. Router.init wraps its base recorder via a `gated(...)` helper, but ONLY when it would change behavior (skip wrap for verbatim .full + nil redact) so the existing ResolveTests identity invariant (handle.recorder === passed InMemoryRecorder, default full/no-redact) stays green. All event sources honor it automatically since they already call recorder.append.
    - MergedTranscript.merged(under: routerDir): enumerate **/transcript.jsonl, decode, sort by (ts, seq) tuple → totally-ordered [TranscriptEvent].
    - Tests MergedAndRedactionTests.swift (Swift Testing, stub model/no GPU): merged (ts,seq) total order under concurrent appends across session dirs w/ fixed clock (ts ties -> seq tiebreak); GatingRecorder unit tests per level + redact; integration via Router+session+embed for metadataOnly/redact wiring; swallow-under-gating (JSONL pointed at a regular-file blocker => createDirectory throws, swallowed) proving respond+embed still succeed.
  timestamp: 2026-07-01T13:57:44.434910+00:00
- actor: wballard
  id: 01kwf08fjw644mnhrhmxsg3hk3
  text: |-
    Implementation landed, GREEN, left in `doing` for review.

    What was built:
    - Added `text: String?` body field to TranscriptEvent + Partial (threaded through stamped()) plus Partial.mapText helper — 10a events had no body, so full vs metadataOnly could not differ; adding it was required and in scope.
    - New Recording/GatingRecorder.swift: decorator enforcing RecordingLevel + redact. off=drop (no forward, no file), metadataOnly=mapText->nil (keeps counts/kinds/provenance), full=forward (applying redact to body when set). Best-effort preserved: it only reshapes/drops the partial; the inner sink still owns seq/ts and the non-throwing swallow.
    - New Recording/MergedTranscript.swift: `merged(under: routerDirectory)` enumerates **/transcript.jsonl, decodes every line, returns events sorted by the (ts, seq) tuple — the totally-ordered whole-router stream.
    - Router wires gating via Self.gated(base, level, redact); wraps ONLY when level != .full || redact != nil, so verbatim full+no-redact keeps the raw recorder identity and the existing ResolveTests `recorder === passed` invariant stays green. All event sources honor gating automatically because they already append through the router's recorder.
    - RoutedSession.generate now takes prompt and records prompt text on .prompt and response text on .response (streaming accumulates chunks; error path close event is deliberately bodyless). RoutedEmbedder.embed records joined input as the .embedding body — gated identically. Stale "milestone 10b" docs updated.

    Tests: Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift (Swift Testing, stub model, no GPU) — 9 tests: merged (ts,seq) total order under concurrent appends across 4 session dirs with a fixed clock (ts ties -> seq must break them); off writes nothing / no jsonl file; metadataOnly omits body keeps counts+kinds; full verbatim; redact transforms; metadataOnly + redact wired end-to-end through Router across session turns AND embeddings; swallow-under-gating (recordingsDir = regular-file blocker -> createDirectory throws, swallowed) with respond+embed still returning.

    Verification (DEVELOPER_DIR=Xcode-beta): `swift build` clean; `swift test --filter MergedAndRedactionTests` 9/9; full `swift test` 110/110 + gated suite skipped as designed; no warnings.

    Adversarial double-check: PASS, no defects. Advisory (not a defect, logged per contract): the merged test's fixed clock means a comparator that dropped the ts primary key (pure seq) would still pass; harmless given the single-recorder single-seq-space design, would only matter if a future merge served independent seq spaces.

    Ready for /review.
  timestamp: 2026-07-01T14:10:22.428169+00:00
depends_on:
- 01KWC5J8K8C0E2ENKB33V4R8SH
position_column: doing
position_ordinal: '80'
title: 'Transcripts: merged-view helper + redaction/level gating (milestone 10b)'
---
## What
The two cross-cutting recording features layered on the core nesting/events (milestone 10a). Plan "Transcripts & recording".

- `Sources/FoundationModelsRouter/Recording/MergedTranscript.swift`:
  - A helper that merges `**/transcript.jsonl` under `recordings/<routerID>/` by `(ts, seq)` into the "what did this whole Router do" view (ULID-ordered paths already give near-order); returns the totally-ordered event stream.
- `Sources/FoundationModelsRouter/Recording/` (gating):
  - Enforce the `RecordingLevel` (`off` / `metadataOnly` / `full`) and the `redact` hook configured on `Router.init` (the seam added in milestone 4b). `off` writes nothing; `metadataOnly` omits prompt/response bodies but keeps counts (`tokensIn/Out`, `ms`, kinds); `full` writes bodies; the `redact` closure transforms recorded text before it is written (local models still see sensitive prompts).
  - Wire the level/hook through the recorder sinks so all event sources (sessions + `RoutedEmbedder.embed`) honor them.

## Acceptance Criteria
- [ ] The merged view across multiple sessions/forks is totally ordered by `(ts, seq)` even with concurrent generation.
- [ ] Level `off` writes nothing; `metadataOnly` omits bodies but keeps counts/kinds; `full` writes bodies.
- [ ] The `redact` hook transforms recorded prompt/response text before it is written.
- [ ] A forced sink write failure logs but generation/embedding still succeeds (best-effort preserved under gating).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift` (Swift Testing) with `.jsonl` temp dir + `.inMemory`: merged `(ts, seq)` total order under concurrent appends across sessions; each level's body/count behavior; redaction transform applied; swallowed write error.
- [ ] Run `swift test --filter MergedAndRedactionTests` — all pass.

## Workflow
- Use `/tdd` — write failing merge-ordering, level-gating, and redaction tests first.