---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m711k8ffxqtfk3t096p6tme5
  text: |-
    Input from FoundationModelsLlamaCpp (header probes of real Hub files):
    - Some DFlash GGUFs on the Hub do not load in mainline llama.cpp b12229. They fall back with drafterNotLoaded: the output stays correct, but there is no speedup. Two cases:
      - arch `dflash-draft` (fork converters, e.g. jcuypers/Qwen3.6-35B-A3B-DFlash-GGUF)
      - arch `dflash` with no `dflash.target_layers` key (old converter, e.g. lym00/Qwen3-4B-DFlash-GGUF-Test)
    - Sizing already reads the drafter's GGUF header, so it can check at no extra cost. A drafter that is meant to be DFlash must have the architecture exactly `dflash` and the key `dflash.target_layers`. Decide whether to warn, or to size such a drafter as 0 bytes, since it won't load.
    - Unsloth's regular GGUFs drop the MTP layers (nextnLayerCount == 0). Their `-MTP-GGUF` repos, and ggml-org conversions, keep them. GGUFHeader.nextnLayerCount shows this before download.
  timestamp: 2026-11-09T20:57:02.191697+00:00
- actor: claude-code
  id: 01m7125yvqvka8jvkc9p4ctk50
  text: |-
    Picked up. Research:
    - GGUFHeader (LlamaCpp a082eff) exposes architecture, blockCount, trainingContextSize, keyValueBytesPerToken/keyValueBytes(contextSize:cacheType:) (pads to 256), recurrentStateBytes(sequenceCount:snapshotCount:). It does NOT expose `dflash.target_layers` (only kept arrays are head_count_kv and sliding_window_pattern), so the "dflash with no target_layers" check is skipped; only the `dflash-draft` architecture is checkable.
    - For f16, keyValueBytes(contextSize) == pad256(contextSize) × keyValueBytesPerToken(.float16) exactly (the width is an integer count, × 2 bytes), so the router can cache the per-cell bytes and recompute at any context.
    - Extras eb0f0d7: GGUFFileSet.select(from:under:) is public; GGUFSource.cachedFiles(of:) is public and selects a local .gguf file / local folder exactly as the loader does, and GGUFModelFiles.byteCount() is public — reused for local refs. HubSource.paths(_:under:) / relativePaths are internal.
    - The HF tree listing the router fetches is already `?recursive=true`, so files under ref.path are visible.
    - LocalModelPath.resolved(_:) rebuilds ModelRef(repo:revision:drafter:) and DROPS ref.path: a Hub GGUF ref `org/repo/Q4_K_M` loses its quant folder before sizing and loading. Fixing it here (needed for "two quants in one repo").
    - The LlamaCpp footprint uses Options.defaultMaxLiveSequences (4) for the recurrent state; the router's live loader uses default options, so sizing uses that count.
    - The qwen35 vocab fixture is arch `qwen2` (dense), 5.9 MB of metadata: good real bytes for the "needs a second, larger range" case. Hybrid/recurrent headers are synthesized in the tests.
  timestamp: 2026-11-09T21:07:14.935784+00:00
- actor: claude-code
  id: 01m713evb0sx8rs0xq02p67hx7
  text: |-
    Implementation landed (not committed, task left in doing).
    - New: Sizing/GGUFCacheSizing.swift (per-cell KV bytes + recurrent state from GGUFHeader, Codable so it rides the metadata cache; dflash-draft detection), Sizing/GGUFRepoMetadata.swift (RepoMetadata.init(ggufHeader:weightBytes:name:), ggufFileSet(in:under:name:) over the tree scoped to ref.path, ggufWeightBytes, init(localGGUF:) via Extras GGUFSource.cachedFiles, draftContextBytes, GGUFHeaderPrefix growing range reader).
    - Footprint now holds `cache: .attention(layers:kvHeads:headDim:) | .gguf(GGUFCacheSizing)`; MLX/Core ML math unchanged. Two existing RepoMetadataTests that read `footprint.kvHeads`/`.headDim` now compare `footprint.cache`.
    - RepoMetadataReader: Hub GGUF path reads the header with `MetadataSource.fetchFileBytes`; local refs go through `RepoMetadata(localLocation:)` (a .gguf file, a GGUF folder detected over all depths, else the old MLX/Core ML folder path). Cache key is now (repo, path, revision): RepoMetadataCache.load/save/fileURL take the ModelRef.
    - HuggingFaceMetadataSource.fetchFileBytes: Range GET on `<endpoint>/<repo>/resolve/<rev>/<path>` with the same token.
    - Router: drafterWeightBytes -> drafterBytes(of:context:) (weights + GGUF draft context); sizeCandidates warns for a dflash-draft drafter.
    - Not changed, worth a look later: `Router.sessionBytes`/`chosenSessionBytes` charge a resident GGUF model one `kvBytes(context)` per new hold, though llama.cpp allocates its unified KV once at load. That predates this task (^z27872m residency design).
    - Verification: mutation checks confirmed the two-quant cache test fails without the path in the key, and the local GGUF folder tests fail without the GGUF branch.
  timestamp: 2026-11-09T21:29:34.816128+00:00
- actor: claude-code
  id: 01m713eyyvfkqax1zfw42792ad
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` clean (only the pre-existing mlx-swift_Cmlx.bundle "missing creator" notice); `swift test` 2504 + 38 + 19 = 2561 passed, 0 failed (was 2525); `swift build --build-tests --package-path IntegrationTests` complete. Files: Sources/FoundationModelsRouter/{Core/LocalModelPath.swift, Router.swift, Sizing/Footprint.swift, Sizing/LocalRepoMetadata.swift, Sizing/RepoMetadata.swift, Sizing/GGUFCacheSizing.swift (new), Sizing/GGUFRepoMetadata.swift (new)}; Tests: FootprintTests, HuggingFaceMetadataSourceTests, LocalModelPathTests, LocalRepoMetadataTests, RepoMetadataTests, GGUFRepoMetadataTests (new), GGUFResolveTests (new), Helpers/FileServingMetadataSource (new), Helpers/GGUFHeaderFixtures (new).
    - next: /review
  timestamp: 2026-11-09T21:29:38.523876+00:00
- actor: claude-code
  id: 01m713vj1grj9ztdcz2hstsws2
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (f6e9d57b) — 1 finding (1 confirmed, 3 refuted): Tests/FoundationModelsRouterTests/Helpers/FileServingMetadataSource.swift:57 (reuse/reuse)
    - next: implement the open finding in the 2026-11-09 15:31 Review Findings section, then re-review
  timestamp: 2026-11-09T21:36:31.280132+00:00
- actor: claude-code
  id: 01m713w89r09m8xjsgbhkdrxq8
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 16 files
    - test: green — swift test 2561 passed, IntegrationTests builds
    - commit: f6e9d57b
    - review: findings — Tests/FoundationModelsRouterTests/Helpers/FileServingMetadataSource.swift:57 (reuse/reuse)
  timestamp: 2026-11-09T21:36:54.072892+00:00
- actor: claude-code
  id: 01m71486fm2p97knbdbvztgama
  text: |-
    Fixed the reuse/reuse finding (FileServingMetadataSource.swift:57) across the whole FoundationModelsRouterTests target.
    - New Helpers/HubTreeListing.swift: `HubTreeListing.json(_ entries: [Entry])` with `.file(path, size:)`, `.lfsFile(path, size:, pointerSize: = 135)`, `.directory(path)`, plus `HubTreeListing.shards(_ sizes:)` (the ResolveTests `tree` helper, moved). HubTreeListingTests (4 tests) parse built listings through `RepoMetadata`.
    - Removed `treeFile`/`tree` from FileServingMetadataSource, the forwarding wrappers in GGUFRepoMetadataTests, and ResolveTests' private `tree`. GGUFResolveTests' `mlxTree` uses the builder.
    - Every other inline listing literal was folded (script-driven JSON parse -> builder call, values preserved exactly incl. the recorded CoreML pointer sizes 134/33_385_008/625_086): RepoMetadataTests (8 listings), ResolveTests window/huge listings, and 30 per-file copies of the one-10 MB-model.safetensors listing, which now alias `RouterTestFixtures.treeJSON` (itself built with HubTreeListing).
    - Discovery: the reader sizes only top-level `*.safetensors`; a nested `sub/model.safetensors` is not a weight (my first directory test failed on that, test fixed).
    - Not touched: Tests/FoundationModelsRouterPublicSurfaceTests/ResolutionProgressPublicSurfaceTests.swift has one more copy of the listing literal, but it is a separate target (public API only, no @testable), so it cannot see this helper; out of the requested test-target scope.
  timestamp: 2026-11-09T21:43:25.428946+00:00
- actor: claude-code
  id: 01m71489k379xynxm2cyvj9w14
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` clean (only the known mlx-swift_Cmlx.bundle "missing creator" notice); `swift test` 2508 + 38 + 19 = 2565 passed, 0 failed (2561 + 4 new HubTreeListingTests); `swift build --build-tests --package-path IntegrationTests` complete. Files: new Tests/FoundationModelsRouterTests/Helpers/HubTreeListing.swift, Tests/FoundationModelsRouterTests/HubTreeListingTests.swift; edited Helpers/FileServingMetadataSource.swift, Helpers/RouterTestFixtures.swift, GGUFRepoMetadataTests, GGUFResolveTests, ResolveTests, RepoMetadataTests, ExamplesTests, AnswerCancellationFixtures, and 24 other test files whose treeJSON now aliases RouterTestFixtures.treeJSON. Finding flipped to [x].
    - next: /review
  timestamp: 2026-11-09T21:43:28.611667+00:00
- actor: claude-code
  id: 01m714h5y1wa00a7zxva3mrny0
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (dc245f42): 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift:172 `code-hygiene/magic-numbers-swift`. Prior finding FileServingMetadataSource.swift:57 `reuse/reuse` is checked and was not raised again.
    - next: replace the magic numbers in RouterTestFixtures.swift with named constants, across the whole file, then re-review.
  timestamp: 2026-11-09T21:48:19.777636+00:00
- actor: claude-code
  id: 01m714hkf8bz37b8y6yka9jbtj
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 36 files (HubTreeListing builder)
    - test: green — swift test 2565 passed, IntegrationTests builds
    - commit: dc245f42
    - review: findings — Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift:172 (code-hygiene/magic-numbers-swift); prior reuse finding resolved
  timestamp: 2026-11-09T21:48:33.640885+00:00
- actor: claude-code
  id: 01m714rcpke6sxx97n7e40k00z
  text: |-
    Fixed `code-hygiene/magic-numbers-swift` (RouterTestFixtures.swift:172) across the whole file, plus the same cause in HubTreeListingTests.swift. No values changed.
    - RouterTestFixtures: new documented constants `layerCount` (2), `attentionHeadCount` (8), `keyValueHeadCount` (2), `headDimension` (16), `hiddenSize` (128), interpolated into `configJSON`; `weightFileBytes` (10_000_000) for the `treeJSON` weight file; `gibibyteShift` (30), `stubTotalRAM` (64 << 30), `stubWorkingSet` (48 << 30) for `stubProbe`.
    - HubTreeListingTests: `nativeContext` (8192), `plainFileBytes` (700), `lfsObjectBytes` (9_000), `firstShardBytes` (300), `secondShardBytes` (400); the shard test now expects `firstShardBytes + secondShardBytes`.
    - HubTreeListing.swift: no change needed. Its only literals are `135` (already the named `lfsPointerSize`) and a `0` directory size in the JSON, which is an allowed value.
    - Check: swiftlint `no_magic_numbers` with the rule's config (`allowed_numbers: [0, 1, -1, 100]`) reported line 172 before the fix and nothing after, over all three files. Swiftlint flagged only line 172 to begin with. The other literals were named because the brief asked for every magic number.
    - Out of scope, not touched: ResolveTests.embeddingSlotFootprint, GGUFResolveTests.smallBytes and ResidencyStubs (embeddingModelFootprint, generationWeightsBytes) each spell out 10_000_000 again. That number is the same weight size as `RouterTestFixtures.weightFileBytes`, and these files could alias it.
  timestamp: 2026-11-09T21:52:16.083062+00:00
- actor: claude-code
  id: 01m714rezg9gmxe523medagkmc
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift, Tests/FoundationModelsRouterTests/HubTreeListingTests.swift. `swift build --build-tests` clean (only the known mlx-swift_Cmlx.bundle "missing creator" notice); `swift test` 2508 + 38 + 19 = 2565 passed, 0 failed; `swift build --build-tests --package-path IntegrationTests` complete. Finding flipped to [x].
    - next: /review
  timestamp: 2026-11-09T21:52:18.416029+00:00
depends_on:
- 01M70TB3W99163V7F38SFR7SPN
position_column: doing
position_ordinal: '80'
title: 'GGUF: size a GGUF candidate (and its drafter) before download'
---
## Problem
Resolution sizes each candidate before download (`RepoMetadata`, `HuggingFaceMetadataSource.fetchRawMetadata(repo:revision:)`, `LocalRepoMetadata`, `Footprint`, JointFit). It reads `config.json` (layers, heads, head dim, native context) and the `*.safetensors` sizes from the tree. A GGUF repo has neither: the hyperparameters live in the GGUF header. Sizing also ignores `ModelRef.path` today, and a local reference may now be a single `.gguf` file.

## What
- Pick the files with Extras' `GGUFFileSet.select(from:under:)` over the tree listing scoped to `ref.path` (or over the local folder or file).
- Weight bytes: the sum of the shard sizes in the tree, plus the projector.
- KV and native context: read the GGUF header of the first shard. On the Hub, fetch only the header bytes with an HTTP Range request; don't download the model. Parse block_count, head_count_kv, key/value length, the full-attention layers of hybrid models, and `<arch>.context_length`. FoundationModelsLlamaCpp's `GGUFMetadataReader` already parses these (`hyperparameters(of:)`, `trainingContextSize(of:)`), but it is internal and reads only from a file URL. Ask the LlamaCpp session (foundationmodelsllamacpp-f1) for a public parse that works on header bytes, rather than writing a second GGUF parser here.
- Drafter: size a GGUF drafter the same way. `Router.drafterWeightBytes` already adds a drafter's weights.
- The metadata cache key has to include the path, so two quants in one repo don't collide.

## Acceptance
- [x] Hermetic tests from a recorded tree listing and header bytes: a single file, a split set, a projector, and a hybrid model.
- [x] A local `.gguf` file and a local folder are both sized.
- [x] JointFit picks between an MLX candidate and a GGUF candidate on fit alone. #gguf

## Decisions
- **DFlash drafters that won't load:** a GGUF drafter whose header architecture is `dflash-draft` (fork converters) is still sized and charged (the router cannot know before the load that the model will fall back), and the router logs a warning through its logger (`RepoMetadataReader` category, `modelRef` metadata = the drafter) saying llama.cpp does not load it as DFlash and the model decodes with no drafter. Tested in `GGUFResolveTests`.
- **`dflash` with no `dflash.target_layers`: not checked.** `GGUFHeader` (LlamaCpp a082eff) keeps only the `head_count_kv` and `sliding_window_pattern` arrays and does not expose `dflash.target_layers`, so that check is skipped rather than writing a second GGUF parser here.
- **KV model for GGUF:** `Footprint.kvBytes(context:)` for a GGUF candidate = `GGUFHeader.keyValueBytes(contextSize:cacheType: .float16)` (pad to 256 cells, unified cache, does not scale with sequences) + `recurrentStateBytes(sequenceCount: LlamaLanguageModel.Options.defaultMaxLiveSequences)` with no rollback snapshot. Compute buffers are not modeled (as MLX overhead is not). The router caches per-cell bytes (`GGUFCacheSizing`); for f16 `pad256(ctx) × keyValueBytesPerToken == keyValueBytes(ctx)` exactly.
- **GGUF drafter context:** a GGUF drafter is charged its weights plus its context (KV + recurrent) at the target's working context, as `footprintBytes` does. An MLX drafter is still charged its weights only (unchanged).
- **Header read:** first range 1 MiB; on `needsMoreBytes(atLeast:)` the next range fetches only the bytes past the prefix, up to `max(atLeast, 2 × prefix)`. A 200 (range ignored) is cut to the range; 416 gives no bytes; other statuses throw. An empty read before the header ends is an error, not a loop.
- **Path scoping:** a Hub ref with a path whose files are not GGUF is a sizing error, mirroring the Extras loader's `pathNeedsGGUF`.
- **`MetadataSource.fetchFileBytes(repo:revision:path:range:)`** is a new requirement with a default implementation that throws, so sources that only serve MLX/Core ML metadata (the many test stubs) are unchanged.
- **`LocalModelPath.resolved` kept dropping `ref.path`** (latent bug): it now keeps it, so `org/repo/Q4_K_M` reaches sizing and loading intact.
- **One tree-listing builder for tests:** `Tests/FoundationModelsRouterTests/Helpers/HubTreeListing.swift` (`HubTreeListing.json(_:)` over `.file`/`.lfsFile`/`.directory` entries, and `HubTreeListing.shards(_:)`, the former ResolveTests `tree`) is the only place the test target writes the Hub tree-listing JSON shape. Every listing that was `{"type": "file", ...}` JSON is built with it; the 30 per-file copies of the one-10 MB-`model.safetensors` listing now alias `RouterTestFixtures.treeJSON`.

## Review Findings (2026-11-09 15:31)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 16 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsRouterTests/Helpers/FileServingMetadataSource.swift:57` `reuse/reuse` — The new `treeFile` helper rebuilds the Hub tree-listing JSON for one file, which an existing unchanged helper in ResolveTests already builds. Two copies of the same listing shape will drift apart as the Hub format is handled. Reuse the existing ResolveTests `tree` helper, or move it into this shared helper and have ResolveTests call `FileServingMetadataSource.treeFile`/`tree`, so there is one canonical tree-listing builder.

## Review Findings (2026-11-09 15:44)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 37 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift:172` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
