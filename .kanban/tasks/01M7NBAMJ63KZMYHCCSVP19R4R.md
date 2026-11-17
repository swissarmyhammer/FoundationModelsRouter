---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7ncx4nc6k5xcyqmnt8a4r6z
  text: |-
    ### implement — changed
    - Extras 1c69b4f (pushed): `ModelPoolKey.kvCache: KVCacheQuantization?`. MLX and GGUF loaders read it from the key, and the loader-level `kvCache` is removed.
    - Router changes:
      - `ProfileDefinition.kvCacheQuantization` is coded as `kvBits` (8/4/absent, any other value throws).
      - Sizing and each pool key (ModelSlot.poolKey, JointFit allocatedKeys, SlotPricing, acquire, SlotPoolLoader) carry it.
      - `ModelLoader.loadLLM` gains `kvCache:`.
      - Removed `LiveModelLoader(kvCacheQuantization:)` and `ModelLoader.kvCacheQuantization`.
      - `KVCacheQuantization` is an alias of the Extras type.
      - `resolvingLocalModelPaths` now copies the profile instead of rebuilding it, so new fields survive.
    - Tests:
      - ProfileKVBitsTests (decode 8/4/absent; reject 6, 16, 0 and "8"; encode).
      - EstimateFit prices a bits8 profile lower.
      - The live loader keys the kvCache.
      - A resolve loads LLMs with .bits8.
      - A resident fp16 model does not serve a bits8 profile. Mutation-checked: both resolve tests fail when acquire passes nil.
    - evidence: `swift test` 2865/333 (+48, +19) green, IntegrationTests build-tests green.
    - next: gated QuantizedKVCacheIntegrationTests once the GPU lock is free.
  timestamp: 2026-11-17T18:39:28.940917+00:00
- actor: claude-code
  id: 01m7nd21t96twchcyw12cz9c9z
  text: |-
    ### test — green
    - evidence: gated QuantizedKVCacheIntegrationTests passed 1 test under bench.lock, 12:41:45 to 12:42:03. Qwen3.8 loaded through LiveModelLoader.loadLLM(kvCache: .bits8), which goes to Extras ModelPoolKey.kvCache: MLXLanguageModel.kvCache is affine 8/64, and two turns answered correctly. Pushed as Router 63e4c70c (Extras 1c69b4f).
  timestamp: 2026-11-17T18:42:09.865977+00:00
position_column: done
position_ordinal: ffffffffffa980
title: ProfileDefinition carries kvBits; the router applies it per profile at sizing and load
---
This is the user's profile design, relayed by ACPAgent: the Router owns the profile data model, and ACPAgent owns the profile files.

- `ProfileDefinition.kvCacheQuantization: KVCacheQuantization?` is coded as the key `kvBits`: 8 → .bits8, 4 → .bits4, absent → nil. Any other value throws `DecodingError.dataCorrupted`. It encodes back to the same form.
- Sizing (runJointFit and estimateFit) uses the resolved profile's value, not `loader.kvCacheQuantization`.
- Loading: the pool key of each generation slot carries the value, through Extras `ModelPoolKey.kvCache` (requested from foundationmodelsextras-2b), so profiles with different settings never share a resident model.
- Remove `LiveModelLoader(kvCacheQuantization:)`, `ModelLoader.kvCacheQuantization`, and the Router's own KVCacheQuantization enum (it moves to Extras), with no backward compatibility.
- After pushing, send the SHA to foundationmodelsacpagent-22.