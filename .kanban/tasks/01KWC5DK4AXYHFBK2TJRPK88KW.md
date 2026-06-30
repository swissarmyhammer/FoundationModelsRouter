---
comments:
- actor: wballard
  id: 01kwcz8t294983vkctd22rh23a
  text: |-
    Implemented milestone 3 TDD-style. New Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:
    - MetadataSource protocol (injected fetch) + RawRepoMetadata bundle (configJSON: Data?, treeJSON: Data) — keeps network as pure transport, parsing testable from canned JSON.
    - RepoMetadata (Sendable/Equatable/Codable): parses config.json arch fields + sums *.safetensors LFS sizes (prefers lfs.size over pointer size) -> weightBytes. Stores config-shaped fields and defers GQA/head_dim fallbacks to Footprint's config-shaped init (single source of truth, no re-derivation). init(raw:) throws RepoMetadataError.metadataUnavailable for: missing/unparseable config.json, missing num_hidden_layers/num_attention_heads, neither head_dim nor hidden_size, no *.safetensors.
    - RepoMetadataReader: ModelRef -> metadata/footprint, with on-disk RepoMetadataCache keyed by SHA256(repo\0revision) mirroring HostProfileCache. Cache hit returns without invoking source.
    - HuggingFaceMetadataSource: live MetadataSource via HF HTTP API (resolve/{rev}/config.json + api/models/{repo}/tree/{rev}); 404 on config.json -> nil configJSON. Not unit-tested (network boundary), matches SystemMachineProbe pattern.

    Deliberately omitted the quantization block: footprint is fully determined by weightBytes (1:1 from disk) + arch; no consumer exists (resolver CandidateReport doesn't use quant), so storing it would be an unused field.

    Tests Tests/FoundationModelsRouterTests/RepoMetadataTests.swift (8 tests, Swift Testing): happy-path metadata + hand-computed footprint (kvBytes(16)=262144, weightBytes=1.5M), GQA fallback, head_dim fallback, missing-config + no-safetensors => metadataUnavailable, cache-hit (fetchCount==1 via actor stub), distinct keys (fetchCount==2). RED confirmed first (types absent), then GREEN.

    Results: swift test --filter RepoMetadataTests = 8/8 pass; full swift test = 39/39 pass + integration target compiles. No warnings from new code. Task left in doing pending double-check.
  timestamp: 2026-06-30T19:14:35.721448+00:00
- actor: wballard
  id: 01kwczf9p0q8qsab90hfc2x11r
  text: |-
    Adversarial double-check returned REVISE with 2 findings; resolved:

    Finding 1 (FIXED) — LFS test fixture passed by construction. Original weightTreeJSON set plain `size` == `lfs.size`, so a regression summing the pointer `size` instead of `lfs.size` would still total 1.5M and pass — not proving the LFS-preference (the load-bearing part of "1:1 resident bytes"). Strengthened weightTreeJSON: two LFS shards now have pointer size 135 with real bytes only in lfs.size (1.0M, 0.5M), plus a third non-LFS shard with only a plain size (0.25M) to exercise the `lfs?.size ?? size` fallback. expectedWeightBytes -> 1_750_000. Verified the strengthened test has teeth: temporarily inverted production to `$1.size ?? $1.lfs?.size` -> happyPathMetadata + happyPathFootprint FAILED (weightBytes 250_270 != 1_750_000); restored correct `$1.lfs?.size ?? $1.size` -> GREEN.

    Finding 2 (WON'T FIX, justified) — num_attention_heads:0 with no head_dim reaches Footprint's hidden_size/0 integer divide-by-zero (traps). The double-check itself rated this very low and noted it is not in the authoritative criteria. The task's no-crash criterion is specifically "missing config.json OR weight sizes => metadataUnavailable"; a present-but-zero attention-head count is neither. A published HF config never has 0 attention heads, so guarding it would be defensive code for an impossible input (the implement guidance says trust framework guarantees, don't add defensive code for impossible scenarios). The divide also lives in pre-existing Footprint, untouched here. Proceeding past per really-done's advisory contract.

    Re-verified: swift test --filter RepoMetadataTests = 8/8; full swift test = 39/39 pass + integration target compiles. No new-code warnings. Task remains in doing.
  timestamp: 2026-06-30T19:18:08.320159+00:00
depends_on:
- 01KWC5C3B35X6N0DYZJYZ044BE
- 01KWC5CQ49ZCF1VVP9FW6T4QZF
position_column: doing
position_ordinal: '80'
title: HF repo metadata reader + fit (milestone 3)
---
## What
Read the two small things each candidate repo needs for sizing — without downloading weights — and feed the footprint math. Cached per `(repo, revision)`. Plan "Repo metadata (milestone 3)".

- `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`:
  - Fetch `config.json` at the repo's revision (architecture for KV math: `num_hidden_layers`, `num_attention_heads`, `num_key_value_heads` (GQA; fall back to attention heads), `head_dim` or `hidden_size/num_attention_heads`, plus the `quantization` block).
  - Fetch the repo tree listing (`…/tree/{rev}`, LFS `size`) and sum `*.safetensors` byte sizes → resident weight bytes (1:1).
  - Use `MLXHuggingFace` resolution where it exposes these; otherwise the HF HTTP API. Inject the fetch behind a protocol (`MetadataSource`) so tests use canned JSON — no network in unit tests.
  - Map a `ModelRef` → `FootprintInput` (feeds milestone-2 `Footprint`).
  - A repo missing `config.json` OR weight sizes ⇒ surface `metadataUnavailable` (a reason string), so the resolver can skip it.
- Cache parsed metadata per `(repo, revision)` under the configured `cacheDir`.

## Acceptance Criteria
- [ ] Given canned `config.json` + tree listing, produces the correct `FootprintInput` (layers/kvHeads/headDim/weightBytes), and `Footprint.footprint(context:)` over it matches a hand-computed value.
- [ ] GQA fallback: missing `num_key_value_heads` uses `num_attention_heads`; missing `head_dim` uses `hidden_size/num_attention_heads`.
- [ ] Missing `config.json` or no `*.safetensors` in the tree ⇒ `metadataUnavailable("…")`, not a crash.
- [ ] Second read for the same `(repo, revision)` hits the cache (fetch invoked once).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/RepoMetadataTests.swift` (Swift Testing) with an injected `MetadataSource` returning canned fixtures: happy path, GQA/head_dim fallbacks, missing-config and no-safetensors → metadataUnavailable, cache-hit (fetch count == 1).
- [ ] Run `swift test --filter RepoMetadataTests` — all pass.

## Workflow
- Use `/tdd` — write failing fixture-driven parsing tests first.