---
depends_on:
- 01KWC5J8K8C0E2ENKB33V4R8SH
position_column: todo
position_ordinal: '9280'
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