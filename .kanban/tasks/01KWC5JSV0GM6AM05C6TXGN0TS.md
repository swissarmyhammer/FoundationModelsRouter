---
comments:
- actor: wballard
  id: 01kwd3mnr9f8n2zm5sy7dgjy38
  text: 'IMPORTANT (discovered during milestone 4b / Router resolve): real model loading is gated behind loader configuration. The `mlx-foundationmodels` fork does NOT bundle a default Hub client — `LiveModelLoader` takes an injected `Downloader` + `TokenizerLoader`, and `Router` defaults to `UnconfiguredModelLoader` which throws `ModelLoaderError.notConfigured`. So THIS integration suite must construct a configured `LiveModelLoader` (real Downloader + TokenizerLoader), which likely requires adding the `swift-huggingface` (HubClient/Downloader) and `swift-transformers` (Tokenizers) SwiftPM deps to Package.swift — they are intentionally NOT in the graph yet. Confirm/scope that dep addition here in milestone 7, not earlier. Live load API used: `loadModelContainer(from:using:configuration:progressHandler:)` (LLM) and `EmbedderModelFactory.shared.loadContainer(...)` (embedder).'
  timestamp: 2026-06-30T20:30:58.825304+00:00
- actor: wballard
  id: 01kwf2v10ze3pvyxsycytj3p48
  text: |-
    Picked up (milestone 7). Research complete on current code + the fork's own IntegrationTesting reference.

    Deps added to Package.swift (only on the IntegrationTests test target): swift-huggingface (from 0.9.0) + swift-transformers (from 1.3.0), matching the fork's IntegrationTesting.xcodeproj pins. `swift package resolve` succeeded (swift-huggingface 0.9.0, swift-transformers 1.3.3; pulls swift-nio/jinja/yyjson/EventSource transitively). `swift build` still green. The MLXHuggingFace `#hubDownloader()`/`#huggingFaceTokenizerLoader()` macros (already in mlxProducts) expand to code referencing HuggingFace.HubClient + Tokenizers.AutoTokenizer — hence the two deps, integration-target-only. Library target injects the loader and imports neither.

    Key design constraint discovered while reading the frozen seams: `LoadedLLMContainer.respond(to:instructions:)` (and the guided/stream variants) take NO cache parameter, and `RoutedSessionActor` stores the session `cache` but only uses it in `fork()` via `cache.copy()` — generation never reads/writes it. So the real MLX ModelContainer path is stateless one-shot per respond (fresh ChatSession per call), matching the existing stub containers. The KV cache seam (makeCache/copy/free) is therefore an object-level contract (real KVCache.copy + ARC free), not generation-threaded prefix reuse; the latter is not expressible through the frozen protocol. Will wire the real object-level cache + document this precisely.
  timestamp: 2026-07-01T14:55:27.263119+00:00
- actor: wballard
  id: 01kwf3sz30r8fj80vw61y4fnh8
  text: |-
    Milestone 7 landed and BOTH paths verified.

    SEAMS WIRED (Sources/.../Resolution/LiveModelLoader.swift):
    - ModelContainer.respond/streamResponse → real ChatSession over MLXLMCommon.
    - ModelContainer.respond(...following:) → real xgrammar: TokenizerVocabExtractor → GrammarTokenizer → GrammarConstraint(jsonSchema/grammar, fastForward) → GuidedGenerationLoop.run.
    - ModelContainer.makeCache() → MLXSessionKVCache([KVCacheSimple()]); copy() calls the real MLX KVCache.copy(). (Note: LoadedLLMContainer.respond carries no cache arg, so this is the object-level fork/copy/free contract, not generation-threaded prefix reuse — a frozen-protocol boundary, documented in code.)
    - Embedding: new LiveEmbeddingContainer wraps EmbedderModelContainer; embed() runs the real MLXEmbedders pool pipeline; dimension is probed once at load (EmbedderModelContainer exposes it only async, so the raw type can't satisfy the synchronous `dimension` accessor).

    DEPS: swift-huggingface 0.9.0 + swift-transformers 1.3.3 added, integration-test-target-only; Package.resolved committed.

    SUITE: Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift — Swift Testing, .serialized + .timeLimit(30m), gated by env var FM_ROUTER_INTEGRATION_TESTS (unset → whole suite skips). macOS-27 availability comes from the package floor (the @available attr conflicts with the @Suite/@Test macros, so it's structural not an attribute). Tiny models: standard+flash = mlx-community/SmolLM-135M-Instruct-4bit (one download, two containers), embedding = mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ. One resolved profile, all three co-resident; asserts progress sizing→downloading→loading→ready (via phase-recording decorators around the real source+loader), non-empty respond, embed dimension + `embedding` transcript event, guided output parses to schema (city/country), fork lineage + free-on-release, merged transcript totally ordered by (ts,seq) + embedding event present.

    RESULTS:
    - SKIP PATH (required): `swift test` → 110 unit tests pass, integration suite SKIPPED, green. `swift build` + `swift build --build-tests` green.
    - REAL PATH: enabled with the env var it runs end to end. `swift test` can't run it because mlx-swift's default.metallib isn't discoverable under the CLI test runner ("Failed to load the default metallib"). Workaround: copy .build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib next to the xctest executable, then `FM_ROUTER_INTEGRATION_TESTS=1 xcrun xctest .build/out/Products/Debug/FoundationModelsRouterIntegrationTests.xctest` → PASSED in 38.8s (all assertions). So the real models download, load, generate, embed, guide, fork, and record for real on this host; the only non-code caveat is the metallib colocation the SwiftPM CLI test runner doesn't do automatically.
  timestamp: 2026-07-01T15:12:21.088890+00:00
- actor: wballard
  id: 01kwf4hjz010q5hmecqjak1hpa
  text: |-
    Adversarial double-check ran → REVISE with 4 findings, all documentation/comment drift (no runtime bugs). All fixed:
    1. GuidedGeneration.swift default guided `respond` doc reworded (live ModelContainer overrides it; default is the stub fallback) + the 3 sibling "notWired over a live container until milestone 7" throws-clauses updated to "any error the model raises during constrained decoding".
    2. ModelLoader.swift LoadedLLMContainer + LoadedEmbeddingContainer protocol docs (and the two inline seam docs) updated to describe the now-wired live paths.
    3. Removed the now-dead `EmbeddingError` enum (only defined, never thrown after embedding was wired; grep-confirmed no references). GenerationError stays — still thrown by the guided default + unit stubs.
    4. IntegrationTests fork section: dropped the lasting `let fork` strong binding so `child = nil` is a genuine release (was retained before); comment now matches.

    Re-verified after fixes: `swift build` green, `swift build --build-tests` green, `swift test` skip-path green (110 unit tests pass, integration suite SKIPPED), and the real gated suite re-run via `FM_ROUTER_INTEGRATION_TESTS=1 xcrun xctest ...` (with default.metallib colocated) PASSED again in 29.4s. Left in `doing` for /review.
  timestamp: 2026-07-01T15:25:15.104368+00:00
depends_on:
- 01KWC5HV9BBARA3HJA26MMV0YC
- 01KWC5H7Y7NVG4771FR9ZKW5M0
- 01KWC606RZSQ521RJY6VK80GA3
position_column: done
position_ordinal: '9380'
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