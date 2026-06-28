# FoundationModelsRouter — Plan

## Goal

A `FoundationModelsRouter` that profiles the host's **unified memory** at startup
and picks the best-fit local models for it, exposing them as a
`LanguageModelProfile` of three slots: `.standard`, `.flash`, `.embedding`.

The hard constraint is RAM: on Apple Silicon, memory is shared by CPU and GPU and
there is no swap we're willing to use, so a model is viable only if its in-memory
footprint fits the machine's budget.

The router is constructed **early** and shared. Tools take it (or a model it
vends) in their constructors so many tools reuse a small set of resident models.

## Foundation: mlx-swift-lm

Rides on [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) —
**MLX is the only runtime** (no llama backend). We don't load or run models
ourselves; we decide *which* and *when*, then drive its modules:

- **MLXLMCommon** — `ModelContainer`, `ChatSession` (loading + generation).
- **MLXLLM** -> `standard` / `flash`. **MLXEmbedders** -> `embedding`.
- **MLXHuggingFace** — download/resolve from Hugging Face.

The candidate catalog is therefore MLX-format Hugging Face repos. On
`mlx-community` **one repo is one quant** (`…-8bit`, `…-4bit` are separate repos),
so the router never picks or produces a quant — it only loads the repos the
author listed.

## Named Profiles

You name a profile and list the HF repos you like, biggest/best first, per slot.
You don't specify quants, RAM, or machine — the router sizes it automatically.
Manifest format is **Swift literals** for v1.

```swift
let coding = ProfileDefinition(
    name: "coding",
    description: "Code generation & review. Wants a big standard model — best on 64 GB+.",
    standard:  ["mlx-community/Qwen2.5-Coder-32B-Instruct-8bit",   // try first
                "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",   // then 4-bit
                "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit"],  // then smaller
    flash:     ["mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"],
    embedding: ["mlx-community/bge-large-en-v1.5"]
)

let profile = try await router.resolve(coding)   // LanguageModelProfile
let summarizer = SummarizeTool(model: profile.flash)
```

The same named profile is **portable**: it resolves to the 32B on a 128 GB
machine and the 14B on a 32 GB machine — author once, run anywhere. The
`description` is shown in pickers to nudge users about what the profile is for
and whether their machine does it justice.

## Resolution (per slot)

1. Compute the budget: `budget = min(recommendedMaxWorkingSetSize,
   totalRAM − headroomReserve)`. Profiled once, cached to disk.
2. Walk the slot's candidates in order. For each repo, read its quant + weight
   bytes from HF metadata and estimate footprint:
   `footprint ≈ quantized weights + KV cache(default context) + overhead`.
3. A candidate is viable iff `footprint × 1.2 ≤ budget` (the 1.2 margin keeps the
   estimate conservative so a pick doesn't OOM on load).
4. The **first viable candidate wins**. The router only accepts or skips — it
   never substitutes a quant the author didn't list. If none fit, fail with a
   clear diagnostic (repos considered, their footprints, the budget).

## Residency

- **Embedding (and any small model) is co-resident** in a keep-warm lane: loads
  once, never evicted by large-model switches, so RAG (embed -> generate) never
  thrashes. Its footprint is reserved from the budget:
  `large_budget = budget − Σ(resident small footprints)`.
- **One large model resident at a time** (standard/flash), fit against
  `large_budget`. Switching evicts the resident one first, then loads the next.
- **Load on demand, keep warm**, idle-timer unload. Apple-managed models (e.g.
  `SystemLanguageModel`) are always resident and not charged against the budget.
- Downloaded weights are **cached on disk** and reused across runs; a model is
  fetched from Hugging Face at most once.

## Access API

The router and residency manager are Swift **actors**. Tools touch the
underlying `ModelContainer` only through a **scoped lease**, which loads on
demand, pins the model against eviction for the closure's duration, and resets
the idle timer on return:

```swift
try await profile.standard.withModel { container in
    try await container.generate(prompt, ...)   // full mlx-swift-lm API inside
}
```

## Core Types

```swift
struct ProfileDefinition {        // authored, pure data, no machine knowledge
    let name: String
    let description: String
    let standard:  [ModelRef]     // preference order, biggest/best first
    let flash:     [ModelRef]
    let embedding: [ModelRef]
}

struct LanguageModelProfile {     // resolved for THIS machine
    let definitionName: String
    let standard:  RoutedModel
    let flash:     RoutedModel
    let embedding: RoutedModel
}
```

- `ModelRef` is a HF repo id (optionally revision-pinned). It is
  `ExpressibleByStringLiteral`, so a bare string is a valid `ModelRef`.
- `RoutedModel` is a handle to a chosen `(model, quant)` the router loads / keeps
  warm / evicts; it exposes `withModel` and the resolution reasoning (chosen
  model, quant, footprint vs budget, why higher-preference candidates were
  skipped, residency state) for UI/logs.

## Decisions

- **Runtime:** MLX only (mlx-swift-lm); no llama backend.
- **Manifest:** Swift-literal `ProfileDefinition` in v1.
- **Quant model:** one repo = one quant; `ModelRef` = one `(model, quant)`;
  author interleaves quant repos; router only accepts or skips.
- **Footprint safety:** conservative `× 1.2` margin on the estimate.
- **Residency:** embedding co-resident with reserved footprint; one large at a
  time against `large_budget`; `withModel` lease pins against eviction.
- **Weights:** cached on disk, reused across runs.

## Deferred (v2+)

Kept out of v1 to keep it small and obviously correct; the approach for each is
already decided:

- **Verify-on-load + correction caching** — after load, read MLX's real resident
  bytes; if over budget, evict and advance to the next listed candidate; cache
  the measured footprint per `(model, quant, machine)` for exact future picks.
  (v1 relies on the `× 1.2` margin alone.)
- **Throughput labels** — `tok/s ≈ bandwidth ÷ active-bytes-per-token` as an
  honest speed label, sharpened by **passive** calibration (measure tok/s during
  real `withModel` leases, cache per `(model, quant, machine)`). Label only,
  never a routing input.
- **SSD-tiered prefix cache** — persist KV prefixes so a reload re-warms fast.
- **Memory-pressure handling** — on a system pressure signal, shrink KV context
  or unload proactively rather than swap.
- **Per-chip tuning** and a **data-file manifest** (JSON/TOML) for user-editable
  profiles.

## Milestones

1. **Profiling + budget** — host profile, disk cache, budget. Unit-testable with
   injected machine specs.
2. **Footprint math** — pure footprint/budget functions given quant + weight
   bytes; unit-testable with injected values.
3. **Repo metadata + fit** — read each repo's quant + weight bytes from HF, feed
   milestone 2, decide fit (depends on 2).
4. **Named profile resolution** — `ProfileDefinition` + `router.resolve()`
   walking candidate lists into a `LanguageModelProfile`, with failure
   diagnostics.
5. **Residency + access** — co-resident embedding lane, single large lane,
   load-on-demand, evict-to-fit, idle unload, `withModel` lease.
6. **Tool integration** — constructors take router/profile; shared use validated.
