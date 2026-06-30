---
comments:
- actor: wballard
  id: 01kwd3mnr9f8n2zm5sy7dgjy38
  text: 'IMPORTANT (discovered during milestone 4b / Router resolve): real model loading is gated behind loader configuration. The `mlx-foundationmodels` fork does NOT bundle a default Hub client — `LiveModelLoader` takes an injected `Downloader` + `TokenizerLoader`, and `Router` defaults to `UnconfiguredModelLoader` which throws `ModelLoaderError.notConfigured`. So THIS integration suite must construct a configured `LiveModelLoader` (real Downloader + TokenizerLoader), which likely requires adding the `swift-huggingface` (HubClient/Downloader) and `swift-transformers` (Tokenizers) SwiftPM deps to Package.swift — they are intentionally NOT in the graph yet. Confirm/scope that dep addition here in milestone 7, not earlier. Live load API used: `loadModelContainer(from:using:configuration:progressHandler:)` (LLM) and `EmbedderModelFactory.shared.loadContainer(...)` (embedder).'
  timestamp: 2026-06-30T20:30:58.825304+00:00
depends_on:
- 01KWC5HV9BBARA3HJA26MMV0YC
- 01KWC5H7Y7NVG4771FR9ZKW5M0
- 01KWC606RZSQ521RJY6VK80GA3
position_column: todo
position_ordinal: '9080'
title: Gated integration suite with tiny real models (milestone 7)
---
## What
Prove the real path end-to-end with deliberately tiny `mlx-community` models, co-resident, behind gates so it never fires on a CI box without network/GPU. Plan "Testing" + milestone 7. Lands last because it asserts resolution, access, guided gen, fork, and recording together.

- `Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift` (Swift Testing, `import Testing`):
  - A small 4-bit generation model + a small embedding model from `mlx-community` (pick the smallest viable; document the repo ids).
  - **Gated:** `@available(macOS 27, *)` and an opt-in env var so it only runs with network/GPU (`.enabled(if: ProcessInfo…environment[...] != nil)`).
  - **`.serialized`** suite + a `.timeLimit` — loads real models under the budget; must not run concurrently.
  - Define a tiny `ProfileDefinition` whose three slots co-fit a small budget.
- Assertions, in one resolved profile (all three co-resident):
  - progress advances `sizing → downloading → loading → ready`;
  - a `profile.standard` session `respond(to:)` returns non-empty text;
  - `profile.embedding.embed([...])` returns vectors of the expected `dimension`, and the call writes an `embedding` event to the recordings tree;
  - a guided session honors its grammar (output parses against the schema);
  - a `fork()` reuses the prefix and frees its cache on release;
  - recording: a fork's `transcript.jsonl` is nested under its parent's directory and the merged log (milestone 10b helper) is totally ordered by `(ts, seq)`.

## Acceptance Criteria
- [ ] With the opt-in env var set on a macOS 27 + GPU host, the suite resolves the tiny profile and all assertions above pass.
- [ ] Without the env var (or on unsupported OS), the suite is skipped — `swift test` on a network/GPU-less box stays green.
- [ ] The suite is `.serialized` with a `.timeLimit`; downloads are cached on disk and reused across runs.
- [ ] The embedding call's `embedding` transcript event is present in the recordings tree.

## Tests
- [ ] The suite IS the test. Run `swift test` (skipped path) — green. Run with the opt-in env var on a capable host — all assertions pass.

## Workflow
- Use `/tdd` — stand up the gated/serialized harness and skip-path first, then add assertions as each real capability comes online.