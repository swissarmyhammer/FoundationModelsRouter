---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7mn15jzy2pbqmvkjpjd7r2q
  text: 'Sizing note: `Footprint.kvBytes(context:)` (Sizing/Footprint.swift) hard-codes fp16 (`cacheElementBytes = 2`) for MLX. GGUF uses `GGUFCacheSizing.bytes(context:)`. Router.swift sizes candidates from metadata, not from the loader, so the router must learn the setting too. Plan: add a `ModelLoader` requirement `kvCacheQuantization` (default nil) that `LiveModelLoader` reports, and that Router.swift''s sizing passes into `kvBytes(context:quantization:)`. The bytes per element become 1 for 8-bit and 0.5 for 4-bit, plus the per-group scale and bias (2 fp16 per 64 elements for MLX affine; q8_0 is 34 bytes per 32 elements and q4_0 is 18 bytes per 32). Peers messaged on 2026-11-17: mlx-swift-lm-fb (MLXLanguageModel kvCache), foundationmodelsextras-2b (MLXModelLoader kvCache), foundationmodelsacpagent-10 (profile.kvBits).'
  timestamp: 2026-11-17T11:42:15.135894+00:00
- actor: claude-code
  id: 01m7mn1j16yd1hz08jyd2h0a1d
  text: |-
    mlx-swift-lm reply (2026-11-17), carded as their ^4zv2rdx:
    - **Constructor:** `KVCacheConfiguration(strategy: .affine(try AffineKVCacheConfiguration(bits: 8, groupSize: 64)))`. It throws on unsupported widths; 2/3/4/5/6/8 are supported.
    - **Prompt cache:** the KV configuration goes into the prompt-cache key or compatibility check.
    - **Speed:** KV8 on Qwen3.8 (head dim 256) is slow today: plain decode is 12–18% slower at 32k–64k, MTP 2.6–3.5× slower. MLX falls back to its unfused quantized attention, and a fused kernel is in progress (their ^6xcb05k).
    - **Output:** KV8 top-1 agreement with bf16 is about 99.5%; it differs on near-ties only.
    - **Order:** they start ^4zv2rdx after ^6xcb05k and will message the stable SHA.
  timestamp: 2026-11-17T11:42:27.878437+00:00
- actor: claude-code
  id: 01m7mn1p1rd3bftktvj3n0ezt1
  text: |-
    Extras reply (2026-11-17), carded as their ^cbhcf4v:
    - `MLXModelLoader.init` and `HubModelLoader.init` both gain `kvCache: KVCacheConfiguration? = nil`, and HubModelLoader forwards it. LiveModelLoader builds a HubModelLoader, so pass it there.
    - No KV sizing lives in Extras. The pool's KV bytes are the `sessionBytes:` the router passes to `ModelPool.acquire(_:footprintBytes:sessionBytes:loader:)`, so the scaling for kvBits is all on the router side (Footprint.kvBytes).
    - LlamaCppModelLoader needs nothing.
    - Extras is waiting on the mlx-swift-lm stable SHA.
  timestamp: 2026-11-17T11:42:31.992278+00:00
- actor: claude-code
  id: 01m7mndsw35n6v2gvnp1k9g1vp
  text: |-
    ACPAgent (2026-11-17): part 1 is pushed to main as 7d66b77.
    - `ProfileConfiguration.kvBits: Int?` (nil by default; values other than 8 or 4 are rejected), plus README and `config show`.
    - Part 2 is their ^kcxqh6t. It maps 8 to `.bits8`, 4 to `.bits4` and nil to nil, passed as `kvCacheQuantization:` in `ComposedAgent.makeLiveModelLoader`.
    - It waits for the Router SHA. Keep the Router API names exactly: `KVCacheQuantization.bits8/.bits4` and `LiveModelLoader.init(..., kvCacheQuantization:)`.
  timestamp: 2026-11-17T11:49:09.123979+00:00
- actor: claude-code
  id: 01m7mpnd0ft2m38235z2fr23qz
  text: |-
    ### implement — changed
    - **Commit:** f81ab2a2, local only and NOT pushed. The router would budget MLX at 8-bit while the MLX cache is still fp16 until the Extras and MLX parts land.
    - **Done:**
      - `KVCacheQuantization` (`.bits8`/`.bits4`) and `LiveModelLoader(kvCacheQuantization:)`, mapped to the llama.cpp `kvCacheType`.
      - `ModelLoader.kvCacheQuantization` (default nil).
      - `Footprint.quantizingKVCache` (MLX affine bytes; llama.cpp Q8_0/Q4_0 block bytes; recurrent state unchanged), threaded through Router `footprintBytes`/`sessionBytes`.
    - **Tests:** KVCacheQuantizationTests has 8 tests; the full suite has 2740 passing; the integration package builds.
    - **Next:**
      1. When Extras ^cbhcf4v pushes, pass `kvCache: kvCacheQuantization.map { KVCacheConfiguration(strategy: .affine(try AffineKVCacheConfiguration(bits:, groupSize: 64))) }` to HubModelLoader, with a test that reads it back.
      2. Bump both Package.resolved files.
      3. Push and send the SHA to ACPAgent ^kcxqh6t.
      4. Run the gated real-model check on Qwen 3.8 under bits8.
  timestamp: 2026-11-17T12:10:46.671809+00:00
position_column: todo
position_ordinal: '80'
title: 'Quantized KV cache: one LiveModelLoader option for every model (kvBits 8 / 4)'
---
The user wants to set the KV-cache bits, as in `GenerateParameters(kvBits: 8)`, in the ACPAgent config file and have it apply to every model. This needs a change in each of four repos:

1. **mlx-swift-lm:** `MLXLanguageModel.init(..., kvCache: KVCacheConfiguration? = nil)`, applied in `Executor.makeParameters` and the warm-up parameters. The executor prompt cache must not reuse a cache across different settings.
2. **FoundationModelsExtras:** `MLXModelLoader` takes `kvCache: KVCacheConfiguration?` and passes it to the `MLXLanguageModel` it builds. `LlamaCppModelLoader` already takes `LlamaLanguageModel.Options` (`kvCacheType`).
3. **Router (this card):**
   - A public `enum KVCacheQuantization: Sendable, Hashable { case bits8, bits4 }`, and `LiveModelLoader.init(..., kvCacheQuantization: KVCacheQuantization? = nil)`. `nil` means fp16, as today.
   - It maps to the MLX affine `KVCacheConfiguration` (8 or 4 bits, group size 64), and to llama.cpp `.quantized8` / `.quantized4` in the `LlamaLanguageModel.Options` the loader builds.
   - The pool's KV sizing counts the smaller cache.
4. **ACPAgent:** a config key `profile.kvBits` (8 or 4; absent means unquantized), read in `ComposedAgent.makeLiveModelLoader`.

Tests (TDD):
- An unset option leaves both engines as today.
- `.bits8` reaches the `MLXModelLoader` and the llama options.
- Sizing shrinks.

The gated real-model check is that Qwen 3.8 mxfp4 answers, and that the prompt cache reuses a prefix under 8-bit KV. Only its 16 full-attention layers have a KV cache, and whether `PromptCacheCheckpoint` handles quantized caches is not yet verified.

Blocked until the mlx-swift-lm and Extras changes are pushed. #feature