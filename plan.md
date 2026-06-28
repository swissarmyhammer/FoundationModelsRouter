# FoundationModelsRouter — Plan

## Goal

A `FoundationModelsRouter` that, at startup, profiles the host machine and picks
the best-fit, best-performance local models for it. The constraint that drives
every decision is **unified memory**: on Apple Silicon, RAM is shared by CPU and
GPU and is the ceiling on what can run at all. The router selects models whose
in-memory footprint fits the machine's memory budget, prefers the highest quality
that still fits, and exposes them as a `LanguageModelProfile`.

The router is constructed **early** in application lifecycle and shared. Tools
take a reference to it (or to a profile/model it vends) in their constructors so
that many tools make coordinated use of a small, controlled set of resident
models.

## Foundation: mlx-swift-lm

This rides on top of [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm).
The router does **not** implement model loading or inference — it sits above
mlx-swift-lm and decides *which* model to load and *when*, then drives those
libraries. Modules we build on:

- **MLXLMCommon** — common API for LLM/VLM; the model-loading and generation
  foundation (e.g. `ModelContainer` for safe concurrent access, `ChatSession`).
- **MLXLLM** — large language model implementations → backs `standard` and `flash`.
- **MLXEmbedders** — encoder/embedding models → backs `embedding`.
- **MLXHuggingFace** — model download/resolution from Hugging Face.
- **MLX** GPU/memory APIs (cache limit, memory limit) → used by residency and
  memory-pressure handling.

Consequence for routing: MLX is the runtime, so the candidate catalog is the set
of **MLX-format (Hugging Face) models** mlx-swift-lm can load and quantize. This
narrows §5 (see "Backend Choice").

## Named Profiles & Auto-Sizing

The primary authoring experience: **you name a profile and list the models you
like** (by Hugging Face repo id) for each slot, mixing and matching freely. You
do **not** specify quants, RAM, or which machine it runs on — the router figures
out the footprint and picks what fits *this* machine automatically.

A profile is declarative. **For v1 the manifest format is Swift literals**
(`ProfileDefinition` values defined in code) — a data-file format (JSON/TOML) for
user-editable profiles is a later addition. Each slot takes a **preference-ordered
list of candidates**, and on `mlx-community` **one repo = one quant** (e.g.
`…-8bit`, `…-4bit` are separate repos). So the author **interleaves quant repos
and model sizes in the one list**, biggest/best first, and the router picks the
first that fits.

```swift
let coding = ProfileDefinition(
    name: "coding",
    description: "Code generation & review. Wants a big standard model — best on 64 GB+.",
    standard:  ["mlx-community/Qwen2.5-Coder-32B-Instruct-8bit",   // try 8-bit first
                "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",   // then 4-bit
                "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit"],  // then a smaller model
    flash:     ["mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"],
    embedding: ["mlx-community/bge-large-en-v1.5"]
)

// Resolve against the current machine → concrete, ready-to-use models:
let profile: LanguageModelProfile = try await router.resolve(coding)
```

Resolution rules per slot:

- Candidates (each a specific `repo` = a specific quant) are tried in
  **preference order** (best/biggest first).
- For each candidate, the router reads that repo's actual quantization and
  estimates its footprint (§3); a candidate is viable iff it fits the budget.
- The first viable candidate wins. Stepping down in quality (8-bit → 4-bit →
  smaller model) happens **across candidates**, exactly as the author ordered
  them — the router never picks a quant the author didn't list.
- If none fit, resolution fails with a clear diagnostic (which repos were
  considered, their footprints, the budget) rather than silently degrading.

This keeps profiles **portable**: the same named profile resolves to the 32B on a
128 GB machine and to the 14B on a 32 GB machine — author once, run anywhere.

## Core Types

### `ProfileDefinition`

The authored, named spec described above: a name, a human-facing description, and
a preference-ordered list of Hugging Face model refs per slot. Pure data, no
machine knowledge.

```swift
struct ProfileDefinition {
    let name: String
    let description: String      // human-facing; shown in pickers to nudge users
    let standard:  [ModelRef]    // preference order, biggest/best first
    let flash:     [ModelRef]
    let embedding: [ModelRef]
}
```

`description` is for **nudging users** — surfaced in the picker UI alongside what
the profile actually resolved to on this machine (model, quant, est. tok/s, §8),
so a user can tell at a glance what a profile is for and whether their machine
does it justice (e.g. "your RAM only fits the 14B fallback — a 64 GB machine runs
the 32B").

`ModelRef` is a Hugging Face repo id (optionally pinned to a revision). On
`mlx-community` a repo *is* a specific quant, so a `ModelRef` denotes one
`(model, quant)`; the author lists multiple refs to express quant preference.

### `LanguageModelProfile`

The **resolved** result of `router.resolve(definition)` for *this* machine — a
coherent set of concrete models chosen to fit the budget:

- `standard` — the highest-quality general model from its candidate list that fits.
- `flash` — a smaller/faster model for latency-sensitive or high-volume work.
- `embedding` — an embedding model for retrieval / similarity.

Each slot is a `RoutedModel` (see below), not a raw handle, so callers can ask
for capabilities and the router controls residency.

```swift
struct LanguageModelProfile {
    let definitionName: String
    let standard: RoutedModel
    let flash: RoutedModel
    let embedding: RoutedModel
}
```

### `RoutedModel`

A handle to a chosen (model, quant, backend, context) that the router knows how
to load, keep warm, and evict. It is not necessarily resident — asking it to
generate triggers load-on-demand through the residency manager.

Tools access the underlying mlx-swift-lm `ModelContainer` only through a
**scoped lease**:

```swift
try await profile.standard.withModel { container in
    // full mlx-swift-lm API inside: streaming, sampling, tool-use, embeddings
    try await container.generate(prompt, ...)
}
```

`withModel` loads-on-demand before the closure, registers an **active lease** for
its duration (so the residency manager never evicts a model mid-use), and resets
the idle timer when it returns. Tools get the full library API inside the closure;
residency control stays centralized. The router/residency manager are Swift
**actors**; `RoutedModel` methods are `async`.

Carries the routing *decision and reasoning* so it can be surfaced in UI/logs
(chosen quant, backend, estimated tok/s, footprint, why this tier).

### `FoundationModelsRouter`

The entry point. Constructed once, early. Responsibilities:

1. Profile the host (cached to disk).
2. Compute the memory budget.
3. **Resolve a `ProfileDefinition`** → choose model + quant per slot → build the
   `LanguageModelProfile` (§4).
4. Own the residency manager (lifecycle of resident models).

```swift
let router = try await FoundationModelsRouter()
// Resolve a named definition for this machine:
let profile = try await router.resolve(coding)   // LanguageModelProfile
// Tools take the router or specific resolved models:
let summarizer = SummarizeTool(model: profile.flash)
let searcher   = SemanticSearchTool(model: profile.embedding)
```

## Model Cache

Downloaded model weights are **cached on disk and reused across runs** — a model
is fetched from Hugging Face at most once, then loaded locally on every
subsequent resolve/launch. This is separate from in-memory residency (§7): the
cache is the on-disk tier, residency is the in-RAM tier.

- **Weights cache** — the resolved `(repo, revision, quant)` files, stored under
  a versioned cache directory. Reused across app runs, profiles, and machines'
  user accounts; survives eviction. mlx-swift-lm / HF Hub already cache
  downloads — we sit on top of that and treat the cache as the source of truth
  for "is this model available offline?".
- **Repo metadata cache** — each candidate repo's quant + weight-byte metadata
  (§3), cached so resolution does not hit the network every launch. Refreshed
  lazily / on explicit request; falls back to the cached metadata when offline.
- **Offline-first resolution** — prefer already-cached models during resolve so a
  profile resolves with no network when its weights are present; only fetch when
  a chosen candidate is missing.
- **Eviction policy (disk)** — bounded cache with LRU/size cap and a manual
  "purge" so large weights don't accumulate unbounded; distinct from the SSD
  prefix cache (§7) which stores KV prefixes, not weights.

## 1. Host Profiling

Profile the machine **once** and cache to disk; re-validate cheaply on launch.

Collect:

- Total unified memory.
- GPU recommended max working set (`recommendedMaxWorkingSetSize`).
- Memory bandwidth (for throughput labels).
- GPU core count.
- Chip identification (for future per-chip tuning).

Cache file is versioned; invalidate on OS/hardware change.

## 2. Memory Budget

The usable budget is the GPU's recommended working set, held under
`total RAM − headroom reserve` (a few GB for macOS and other apps, tunable).
Loading a model must never drive the machine into memory pressure or swap.

```
budget = min(recommendedMaxWorkingSetSize, totalRAM − headroomReserve)
```

## 3. Footprint Estimation

For a `(model, quant, context)`:

```
footprint ≈ quantized weights + KV cache(at context) + runtime overhead
```

KV grows with context, so compute the budget at a **sane default context with
room to grow** rather than max context.

Each candidate repo's quantization is **read from its Hugging Face metadata**
(the `quantization` block in `config.json`, plus weight-file sizes), so the
router knows the bit-width and weight bytes without the author stating them.
Quant *choice* is the author's ordered list of repos (above), not per-repo
discovery — one repo, one quant.

### Conservative estimate + verify-on-load

Because unified memory has no swap safety net, an under-estimate is the worst
failure mode. The estimate is therefore deliberately pessimistic on the way in
and reconciled with reality on the way out:

- **Picking** uses a safety margin: a `(model, quant)` is viable iff
  `footprint_est × margin ≤ budget` (margin ≈ 1.2, tunable). This absorbs
  allocator/Metal-buffer overhead, KV growth past the default context, and
  weight files whose in-memory size exceeds their on-disk size.
- **Verify-on-load**: after the model loads, read MLX's actual reported resident
  bytes. If reality exceeds the budget, back off — evict and advance to the next
  listed candidate (§4) — rather than risk memory pressure.
- **Correction caching**: the measured actual footprint is cached per
  `(model, quant, context)` so future picks use the real number instead of the
  estimate. The first load of a model is conservative; subsequent picks are exact.

## 4. Routing Decision (Fit & Quant Selection)

This runs **per slot**, over that slot's preference-ordered candidate list from
the `ProfileDefinition` (see "Named Profiles & Auto-Sizing").

Hard rule: a `(model, quant)` is **viable iff `footprint_est × margin ≤ budget`**
(§3, margin ≈ 1.2), with a verify-on-load guard that backs off if the loaded
model's real footprint still exceeds the budget.

1. Walk candidates in **preference order** (the author's biggest/best first).
   Each candidate is one `(model, quant)` repo, so the author's ordering already
   encodes the quality ladder (8-bit → 4-bit → smaller model).
2. A candidate is viable iff it fits the budget (the §3 margin rule). The router
   never substitutes a quant the author didn't list — it only accepts or skips.
3. The first viable candidate wins; otherwise advance. If the list is exhausted,
   fail with a diagnostic (§ Named Profiles).

This is a pure size/RAM decision. Throughput never overrides it. The author's
preference order is the only quality signal — the router does not reorder
candidates, it only filters by what fits.

## 5. Backend Choice

Because we ride on mlx-swift-lm, **MLX is the runtime** and there is no llama
backend in scope (see Foundation). The original "low-bit → MLX, GGUF-only →
llama" rule from the design notes is therefore collapsed: the candidate catalog
is restricted to repos that have an MLX build, and there is no backend or quant
decision left for the router — the quant is fixed by which repo the author
listed, and §4 only decides which listed repo fits.

Implication: the largest GGUF-only quants (e.g. UD-IQ2 of very large models) are
**not reachable** and are excluded from the catalog. If those models become
important later, a separate llama-backed runtime would be a future extension —
explicitly out of scope for v1.

## 6. Throughput (label only)

Token generation is memory-bandwidth-bound:

```
tok/s ≈ bandwidth ÷ active-bytes-per-token
```

Use this for **honest speed labels** in the picker UI. It is **never** a routing
input.

Calibration is **passive**, mirroring the footprint correction-caching (§3):
every `withModel` lease is already running real generation, so we observe actual
tok/s and cache it per `(model, quant, machine)`. No separate benchmark runs.

```
label = cached_measured_tok_s ?? analytic_estimate
```

The label shows the analytic estimate until a model's first real generation, then
the measured rate thereafter.

Expose the chosen backend/quant and the reasoning (see §8).

## 7. Residency Management

Routing picks *which* models; residency decides *what stays in memory*. There are
two lanes:

**Small / co-resident lane.** The embedding model (and any model small enough)
lives here: it loads once, stays warm, and is **never evicted** by large-model
switches — so RAG (embed query → generate) never thrashes. Its measured footprint
is **reserved from the budget**, so the large lane fits around it:

```
large_budget = budget − Σ(resident small-model footprints)
```

Apple-managed models (e.g. `SystemLanguageModel`) are the exception — always
resident and **not** charged against the budget.

**Large / single-resident lane.** The standard model (and flash, unless small
enough to co-reside) lives here:

- **At most one large model resident at a time**, fit against `large_budget`.
- **Load on demand, keep warm.** A model loads on first use and stays resident
  with its KV cache so follow-up turns are instant; an idle timer unloads it.
- **Evict to fit.** Switching models (user choice, subagent on a different model,
  scheduler job) unloads the resident one before loading the next when both
  won't fit. Eviction drops in-memory KV but **not** the SSD-tiered prefix cache,
  so reload re-warms fast.
- **Serialize large loads.** Two large loads never overlap; concurrent requests
  for different large models queue. (If both genuinely fit, they may co-reside —
  but the router never re-quantizes a model; it only loads listed candidates.)

**Both lanes — react to pressure.** On a system memory-pressure signal, shrink KV
context or unload proactively rather than letting the OS swap — swap on unified
memory is exactly what this design avoids.

## 8. Observability

Every routed model exposes its decision and reasoning:

- chosen model, quant, backend, context
- estimated footprint vs budget
- estimated tok/s (label)
- why this candidate was chosen / why higher-preference candidates were skipped
- current residency state (resident / warm / evicted)

## Decisions

- **Runtime:** MLX only (via mlx-swift-lm); no llama backend in v1.
- **Manifest:** Swift-literal `ProfileDefinition` values in v1; data-file
  (JSON/TOML) for user-editable profiles deferred.
- **Model weights:** cached on disk, reused across runs (see Model Cache).
- **Repo metadata:** cached so resolution is offline-first; refreshed lazily.
- **Quant model:** `mlx-community` ships one quant per repo, so a `ModelRef` =
  one `(model, quant)`. Authors interleave quant repos in the candidate list;
  the router never substitutes an unlisted quant — it only accepts or skips.
- **Footprint safety:** pick with a conservative `× margin` (≈1.2) estimate, then
  verify-on-load against MLX's real reported bytes and back off if it overflows;
  cache the measured footprint for exact future picks (see §3).
- **Residency lanes:** the embedding model (and any small-enough model) is
  co-resident in its own keep-warm lane, never evicted by large-model switches;
  its footprint is reserved from the budget. One large model resident at a time
  fits against `large_budget = budget − resident smalls` (see §7).
- **Access API:** router/residency are Swift actors; tools touch a model only via
  `await model.withModel { container in … }` — a scoped lease that load-on-demands,
  pins against eviction for its duration, and resets the idle timer on return.
- **Throughput calibration:** passive — observe actual tok/s during real
  `withModel` generations and cache per `(model, quant, machine)`; the label
  falls back to the analytic estimate only until first real use (see §6).

## Milestones

1. **Profiling + budget** — host profile, cache, budget computation. Unit-testable
   with injected machine specs.
2. **Footprint + fit/quant selection** — pure functions over a model catalog.
3. **Repo metadata + fit** — read each candidate repo's quant + weight bytes from
   HF metadata, estimate footprint, decide fit (no llama backend in v1).
4. **Named profile resolution** — `ProfileDefinition` authoring + Swift-literal
   manifest, `router.resolve()` walking candidate lists into a
   `LanguageModelProfile` (with failure diagnostics).
5. **Residency manager** — load/warm/evict, serialization, idle timer.
6. **Memory-pressure handling** — react to signals.
7. **Throughput labels + observability** — expose decisions/reasoning.
8. **Tool integration** — constructors take router/profile; shared use validated.
