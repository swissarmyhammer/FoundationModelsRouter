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