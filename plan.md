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

### Dependency tracking: `MLXFoundationModels` (pre-release)

WWDC26 opened Apple's **FoundationModels** framework to third-party providers via
a `LanguageModel` protocol. `MLXFoundationModels` is the MLX-backed conformance
(`MLXLanguageModel`), letting MLX models run behind Apple's `LanguageModelSession`
with chat, tool calling, and xgrammar-backed guided generation. It is **not yet
merged upstream** — it lives in open PR
[ml-explore/mlx-swift-lm#334](https://github.com/ml-explore/mlx-swift-lm/pull/334)
(author `ctymoszek`).

We track it via our own fork so the dependency is stable and under our control:

- **Fork:** [`swissarmyhammer/mlx-swift-lm`](https://github.com/swissarmyhammer/mlx-swift-lm)
  (forked from `ctymoszek/mlx-swift-lm`).
- **Correct branch / dependency:** `mlx-foundationmodels`
  (tip `234787d` as of 2026-06-29).
- **SwiftPM:**
  `.package(url: "https://github.com/swissarmyhammer/mlx-swift-lm", branch: "mlx-foundationmodels")`
  — SwiftPM supports branch dependencies, pinned by commit in `Package.resolved`.
- **Platform: macOS 27+ / FoundationModels v2 SDK.** We commit to the whole stack —
  `MLXFoundationModels` (`MLXLanguageModel`) + `MLXGuidedGeneration` (xgrammar) — and
  keep **no** pre-27 fallback, so nothing in the design is conditional on OS version.
  The one live caveat is that this is a **branch dependency** (`mlx-foundationmodels`)
  until PR #334 merges upstream — a pin to manage, not an OS gate.

## Named Profiles

You name a profile and list the HF repos you like, biggest/best first, per slot.
You don't specify quants, RAM, or machine — the router sizes it automatically.
Manifest format is **Swift literals**.

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

// Resolution is async and reports progress for the UI (see Access API).
let progress = ResolutionProgress()                  // @MainActor @Observable
let profile  = try await router.resolve(coding, reporting: progress)
let summarizer = SummarizeTool(model: profile.flash)
```

The same named profile is **portable**: it resolves to the 32B on a 128 GB
machine and the 14B on a 32 GB machine — author once, run anywhere. The
`description` is shown in pickers to nudge users about what the profile is for
and whether their machine does it justice.

## Resolution (joint — all three slots co-fit)

The profile holds **all three slots resident at once**, so resolution finds the
highest-preference *combination* that co-fits one budget — not three independent
picks.

1. Compute the budget once (cached to disk):
   `budget = min(recommendedMaxWorkingSetSize, totalRAM − headroomReserve)`.
2. Size each candidate from HF metadata:
   `footprint ≈ quantized weights + KV cache(default context) + overhead`.
   A candidate is viable in a *remaining* budget iff `footprint × 1.2 ≤ remaining`
   (the 1.2 margin keeps the estimate conservative so load doesn't OOM).
3. Allocate in preference order against the shared budget:
   1. **embedding** — first viable candidate; reserve its footprint.
   2. **standard** — largest viable candidate in `budget − embedding`.
   3. **flash** — largest viable candidate in `budget − embedding − standard`.
4. The router only accepts or skips — it never substitutes a quant the author
   didn't list. If any slot has no viable candidate in what's left, the **whole
   resolution fails** with a diagnostic (slots, candidates considered, their
   footprints, the budget). Sizing a profile to co-fit is the author's job.
5. Once the trio is chosen, download + `preload()` all three, reporting progress
   throughout (see Access API).

## Sizing: profiling, metadata, footprint

The numbers behind Resolution steps 1–2. Each is pure given its inputs, so each is
unit-testable with injected values (milestones 1–3).

### Host profile & budget (milestone 1)

Measured once at startup, cached to disk keyed by `(chip, totalRAM)`:

- `totalRAM` — `ProcessInfo.physicalMemory` (≡ sysctl `hw.memsize`).
- `recommendedMaxWorkingSetSize` — `MTLDevice.recommendedMaxWorkingSetSize`, the GPU
  working set the system is willing to back (≈ 70–75% of RAM on Apple Silicon).
- `headroomReserve` — fixed OS/app slack held out of the budget (default 4 GB).
- `budget = min(recommendedMaxWorkingSetSize, totalRAM − headroomReserve)`.

### Repo metadata — no weights downloaded (milestone 3)

Per candidate, read two small things from the HF repo at its revision, cached per
`(repo, revision)`:

- **`config.json`** — architecture for the KV math: `num_hidden_layers`,
  `num_attention_heads`, `num_key_value_heads` (GQA; falls back to attention heads),
  `head_dim` (or `hidden_size / num_attention_heads`), plus the `quantization` block.
- **Weight file sizes** — from the repo tree listing (`…/tree/{rev}`, LFS `size`),
  summed over `*.safetensors`. Quantized weights load ≈ 1:1 from disk, so this sum is
  the resident weight bytes directly — no need to derive them from the quant bits.

A repo missing either ⇒ `CandidateReport.metadataUnavailable`; the router skips it.

### Footprint estimate (milestone 2)

```
weightBytes  = Σ size(*.safetensors)                      // ≈ resident, 1:1
kvBytes(ctx) = 2 × layers × ctx × kvHeads × headDim × 2   // K+V, fp16 cache
footprint    = weightBytes + kvBytes(defaultContext)      // overhead via margin
```

- `defaultContext` is the profile's `context` (default **8K**) — the same value
  used to size the KV cache at load, so the estimate matches reality. A long-context
  profile raises it, which inflates `kvBytes` and therefore fits smaller models.
- The KV cache is **fp16 regardless of weight quant** (2 bytes/elt).
- Activation / compute / framework **overhead** is not modeled term-by-term — the
  conservative `× 1.2` margin in Resolution absorbs it.
- **Embedders** have no autoregressive KV cache: `footprint ≈ weightBytes` (+ margin).

## Residency

A resolved `LanguageModelProfile` **holds its three models resident for its whole
lifetime** — no leases, no idle unload, no auto-eviction. An app picks a profile
and goes; residency is exactly as predictable as the object's lifetime.

- `resolve` `preload()`s all three slots; they stay in memory until teardown.
- Profile teardown (`deinit`, or an explicit `release()`) `evict()`s all three. Live
  sessions **retain their profile**, so models aren't freed while any session or fork
  is alive — `deinit` fires only once the profile handle and all its sessions are gone.
- Because everything is always resident, the budget must fit standard + flash +
  embedding **simultaneously** (see Resolution).
- **One active profile at a time:** the budget is sized for a single profile,
  so release the current one before resolving another. Resolving a profile that
  wouldn't co-fit already-resident models fails rather than over-committing RAM.
- Apple-managed models (e.g. `SystemLanguageModel`) are always resident and not
  charged against the budget.
- Downloaded weights are **cached on disk** and reused across runs; a model is
  fetched from Hugging Face at most once.

## Access API

The router is a Swift **actor**; resolution is async and reports progress. Because
the models are always resident, access needs no lease or scope — a slot is just a
ready model. A `RoutedLLM` vends a session and a `RoutedEmbedder` embeds, directly:

```swift
// Generation — a session over the resident standard model (backend-neutral)
let session = profile.standard.makeSession(instructions: "You are…")
let reply   = try await session.respond(to: "…")

// Embedding
let vectors = try await profile.embedding.embed(["…", "…"])
```

Resolution is the only slow, awaited step, and it surfaces progress for the UI via
a `@MainActor @Observable` object bound straight into SwiftUI:

```swift
@State private var progress = ResolutionProgress()
// in the view body: ProgressView(value: progress.fraction) + per-slot rows
.task { profile = try await router.resolve(coding, reporting: progress) }
```

(Sessions are vended over `MLXLMCommon`'s `ChatSession` / `ModelContainer`; a routed
model can also back a native `LanguageModelSession` via `MLXFoundationModels` — see Backends.)

## Core Types

```swift
struct ProfileDefinition {        // authored, pure data, no machine knowledge
    let name: String
    let description: String
    let standard:  [ModelRef]     // preference order, biggest/best first
    let flash:     [ModelRef]
    let embedding: [ModelRef]
    var context: Int = 8192       // working context; scales KV footprint & fit
}

final class LanguageModelProfile {  // resolved for THIS machine; holds models resident
    let definitionName: String
    let standard:  RoutedLLM
    let flash:     RoutedLLM
    let embedding: RoutedEmbedder
    func release()                  // evict all three; also runs on deinit
}

enum ModelSlot { case standard, flash, embedding }

// A resolved, resident generation model. Vends sessions — never a closure/lease.
struct RoutedLLM {
    let slot: ModelSlot                      // .standard or .flash
    let chosen: ModelRef
    let footprintBytes: Int64
    let resolution: SlotResolution           // why it won; what was skipped
    func makeSession(instructions: String? = nil,
                     workingDirectory: URL? = nil) -> RoutedSession   // nil ⇒ the session's recording dir
}

// A resolved, resident embedding model.
struct RoutedEmbedder {
    let chosen: ModelRef
    let footprintBytes: Int64
    let resolution: SlotResolution
    let dimension: Int                       // vector length, for callers/tests
    func embed(_ texts: [String]) async throws -> [[Float]]
}

// A session is an `actor`: it isolates its mutable state (KV cache, transcript,
// working directory) and serializes its own calls. It owns its KV cache (layered on
// the pinned weights), **retains its creating profile** (so resident models stay alive
// for its lifetime), and is **born holding the Router's recorder** — there is no public
// init, so an unrecorded session can't exist (see Transcripts & recording). `fork` is
// the primitive: a child inherits this session's cache (a copy of the prefilled
// prefix) and recorder, sets `parentID = self.id`, nests its directory under the
// parent, and diverges. Releasing a session frees its cache.
protocol RoutedSession: Actor {
    var profile: LanguageModelProfile { get }    // retained: keeps the models resident
    var routerID: ULID { get }                   // the recording group
    var id: ULID { get }                         // this session's span; sortable by creation
    var parentID: ULID? { get }                  // nil ⇒ a root session under the Router
    var recordingDirectory: URL { get }          // lineage-derived (…/<parent>/<id>/); NOT caller-set
    var workingDirectory: URL { get }            // tools' filesystem scope; defaults to recordingDirectory
    func respond(to prompt: String) async throws -> String
    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, Error>  // unconstrained text only
    func fork(workingDirectory: URL?) -> RoutedSession   // nil ⇒ default; transcript nests regardless
}

// Guided generation — constrain output to a grammar (xgrammar via MLXGuidedGeneration).
enum Grammar {
    case jsonSchema(String)   // a JSON Schema document (runtime; e.g. an MCP tool's)
    case ebnf(String)         // a raw xgrammar grammar
}

// Dynamic JSON — for schemas known only at runtime, with no Swift type.
enum JSONValue: Sendable, Codable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])
}

extension RoutedLLM {
    // Typed: schema derived from the Generable type; result decoded into it.
    func respond<T: Generable>(to prompt: String, generating: T.Type) async throws -> T
    // Dynamic JSON: runtime JSON Schema (e.g. an MCP tool's), parsed — no Swift type.
    func respond(to prompt: String, matching jsonSchema: String) async throws -> JSONValue
    // Raw: any grammar (JSON Schema or EBNF); unparsed constrained text out.
    func respond(to prompt: String, following grammar: Grammar) async throws -> String
    // A session whose every response obeys `grammar` (forkable; returns raw text).
    func makeGuidedSession(_ grammar: Grammar, instructions: String? = nil,
                           workingDirectory: URL? = nil) -> RoutedSession   // nil ⇒ the session's recording dir
}

// Built once at app start, shared everywhere (see Goal). Holds the profiling +
// repo-metadata caches; resolution is async with UI-bindable progress.
actor Router {
    let id: ULID                              // recording root; sortable by construction time
    init(id: ULID = .generate(),              // pass one in to continue a prior recording root
         headroomReserve: Int64 = 4 << 30,    // 4 GB held out of the budget
         maxConcurrentForks: Int = 4,         // in-flight fork sessions per profile
         cacheDir: URL? = nil,                // host profile + repo-metadata cache (disposable)
         recordingsDir: URL? = nil,           // durable transcripts root (NOT the cache)
         recorder: TranscriptRecorder = .jsonl)  // .jsonl | .inMemory | .none (a no-op sink)

    func resolve(_ def: ProfileDefinition,
                 reporting: ResolutionProgress) async throws -> LanguageModelProfile
}

@MainActor @Observable            // bind straight into SwiftUI; updates on main actor
final class ResolutionProgress {
    enum Phase { case sizing, downloading, loading, ready, failed(String) }
    var phase: Phase = .sizing
    var fraction: Double = 0       // 0…1 overall — drives a ProgressView
    var slots: [ModelSlot: SlotProgress] = [:]
}

struct SlotProgress {
    enum State { case pending, sizing, downloading, loading, ready, failed(String) }
    var state: State = .pending
    var chosen: ModelRef?          // candidate that won the joint fit
    var bytesDownloaded: Int64 = 0
    var bytesTotal: Int64 = 0
}

// Per-slot resolution reasoning — attached to each routed model on success, and
// collected into ResolutionFailure when a slot can't be satisfied.
struct SlotResolution {
    let slot: ModelSlot
    let remainingBudgetBytes: Int64          // budget left when this slot was allocated
    let chosen: ModelRef?                    // nil ⇒ this slot is why resolution failed
    let considered: [CandidateReport]        // every candidate, in preference order
}

struct CandidateReport {
    let ref: ModelRef
    let estimatedFootprintBytes: Int64?      // already ×1.2; nil if metadata unread
    let verdict: Verdict
    enum Verdict {
        case chosen
        case tooLarge                        // footprint > remaining budget
        case skippedHigherPreferenceChosen   // a better candidate already won the slot
        case metadataUnavailable(String)     // HF metadata read failed
    }
}

struct ResolutionFailure: Error {            // thrown by resolve when a slot has no fit
    let profileName: String
    let budgetBytes: Int64
    let slots: [SlotResolution]              // includes the unsatisfiable slot(s)
    // `description` renders slots → candidates → footprints vs budget for logs/UI.
}
```

- `ModelRef` is a HF repo id (optionally revision-pinned). It is
  `ExpressibleByStringLiteral`, so a bare string is a valid `ModelRef`.
- `ULID` is a 128-bit, lexicographically time-sortable identifier (Crockford base32);
  it names the Router's recording root and each session (see Transcripts & recording).
- `RoutedLLM` / `RoutedEmbedder` are handles to a resident `(model, quant)`. The
  LLM vends sessions (`makeSession`); the embedder vends `embed`. Both carry their
  `SlotResolution` (chosen model, footprint vs budget, why higher-preference
  candidates were skipped) for UI/logs.
- On failure `resolve` throws `ResolutionFailure` carrying the same per-slot
  reasoning, so a UI can show exactly why no profile fit this machine.

## Backends

One stack, macOS 27+. Generation and embedding run on `MLXLMCommon`
(`ChatSession` / `ModelContainer`) and `MLXEmbedders`; guided generation runs on
`MLXGuidedGeneration` (xgrammar). **Our session owns its KV cache** at this layer —
that's what makes `fork()` real (see "Sessions & KV cache").

FoundationModels interop is available but not load-bearing: a routed model can also
back a native `LanguageModelSession` (via `MLXLanguageModel`) for callers who want
Apple's `@Generable` / `Tool` ergonomics. That path delegates cache management to
FoundationModels, so it does **not** expose our cache-level `fork()` — use our
session when you want forking.

## Guided generation

xgrammar gives us **grammar-constrained decoding**: output is forced to be valid for
a grammar, so structured results are correct *by construction*, not by
hope-and-parse. The primitive is a **guided session** — a session whose responses
are constrained to a `Grammar` (a JSON Schema or a raw EBNF grammar).

### The engine

`MLXGuidedGeneration` (PR #334) provides the xgrammar engine: its entry points take
a **runtime grammar string** (`GrammarConstraint(jsonSchema:)` +
`GuidedGenerationLoop.run(…)`) and constrain MLX sampling directly over a resident
`ModelContainer`. `RoutedLLM` exposes it as `respond(to:following:)` and
`makeGuidedSession(_:)` (see Core Types).

### Three response shapes

Pick by whether the caller has a Swift type for the result:

- **Typed** — `respond(to:generating: T.self) -> T` for a `@Generable` type. The
  schema is *derived from the type* and the result decoded into it. One source of
  truth; use when the shape is known at compile time.
- **Dynamic JSON** — `respond(to:matching: jsonSchema) -> JSONValue` for a schema
  known only at runtime with **no Swift type** — e.g. an MCP tool that "returns JSON"
  against its advertised schema. The result is valid for the schema but introspected
  dynamically (`JSONValue`), never decoded into a fixed type.
- **Raw** — `respond(to:following: Grammar) -> String` for any grammar (JSON Schema
  *or* EBNF); unparsed constrained text out. This is also what a guided session binds,
  so `makeGuidedSession(_:).respond(to:)` and its forks return raw text the caller
  decodes (to a type or to `JSONValue`).

The grammar source is always the caller's — hand-written, `@Generable`-derived, or
discovered from a catalog like MCP. The router supplies the guided session; callers
decide the source and whether to wrap a tool-call loop on top.

### Worked example

```swift
// Known type → typed result (schema derived from the @Generable type).
@Generable struct Review { let verdict: String; let issues: [String] }
let review = try await profile.standard.respond(to: "Review:\n\(diff)",
                                                generating: Review.self)

// Runtime schema, no Swift type (e.g. an MCP tool's) → a JSON ball, schema-valid.
let value: JSONValue = try await profile.standard.respond(to: prompt,
                                                          matching: tool.inputSchema)

// Subagent fan-out: one template (shared prefix + grammar), many short-lived forks.
let template = profile.flash.makeGuidedSession(.jsonSchema(schema),
                                               instructions: "Emit only JSON for the schema.")
for diff in diffs {                            // forks past maxConcurrentForks queue
    let sub = template.fork()                  // inherits the prefilled prefix + grammar
    // sub.respond(to: diff) → raw JSON text; decode to Review or JSONValue.
}                                              // each `sub` + its cache freed at scope exit
```

Caveat: xgrammar covers a **subset of JSON Schema**; grammars using `$ref` / `allOf`
/ `format` need normalization or are rejected with a clear error (surfaced like a
metadata failure, not a crash).

## Sessions & KV cache

A session owns its KV cache, layered on the model's pinned weights (weights stay
resident; caches come and go). `fork()` is the primitive for the "many subagents,
common instructions + tools" pattern:

1. Build a **template session** with the shared instructions (and grammar/tools);
   priming it prefills that common prefix once into its cache.
2. `template.fork()` returns a child whose cache **begins as a copy of the template's**
   (`KVCache.copy()`), so it inherits the prefix's compute and diverges on its own
   prompt. Forks are independent and may run concurrently.
3. **A session's cache dies with the session** (ARC) — releasing a fork frees its KV.
   A session also **retains its creating profile** (`session.profile`), so resident
   models can't be freed out from under it; the profile evicts only once its handle
   and all sessions/forks are released. No keyed pool or LRU: the live template *is*
   the warm prefix; forks are explicit and short-lived.

Substrate (verified on the branch): `KVCache.copy()` (fork), `trim(_:)` (serial
reuse — recycle one cache instead of copying), `savePromptCache` /
`loadPromptCache` (spill a warm prefix to disk).

**Budget caveat:** `copy()` is a *deep* copy, so K concurrent forks hold K× the
prefix KV. KV is a **reclaimable, pooled** resource separate from pinned weights, and
the footprint math budgets only one cache per model — so a wide fan-out needs a KV
budget carved from headroom and a bound on concurrent forks, or it OOMs a machine
that held the models comfortably.

## Concurrency

Generation on a resident model is **serialized** — one at a time per model, FIFO.
Concurrent `respond()` calls (including from forks of the same model) **queue** rather
than run in parallel: MLX generation isn't safe to interleave on a single model's
weights, and the GPU runs one stream anyway. Each `RoutedLLM` owns a serial gate.

**Fork fan-out is bounded** by `maxConcurrentForks` (a `Router` setting): at most that
many fork sessions are in flight at once, capping the K× prefix-KV cost of `copy()`.
`fork()` past the limit **awaits a free slot**, which frees when a fork is released —
so a wide subagent fan-out self-throttles instead of OOMing.

Both gates are the same primitive: a **fair (FIFO) async semaphore** (await-based, not
a thread-blocking `DispatchSemaphore`) — value 1 for the per-model serial gate, value
`maxConcurrentForks` for fork admission.

**Guided output is whole-chunk, not streamed:** `respond(to:generating:)` / `matching:`
/ `following:` return the complete, schema-valid result. Token streaming
(`streamResponse`) stays for *unconstrained* text only.

## Sessions: working directory & isolation

Every session has a **`workingDirectory`** (host filesystem) — where its tools,
relative paths, and outputs resolve. It defaults to the session's **recording
directory** (lineage-nested under the Router — see Transcripts & recording); pass one
explicitly to move the files elsewhere, and the transcript stays in the tree. A session
is an **`actor`**, so its mutable state (KV cache, transcript, working directory) is
isolated and its own calls serialize.

**Many sessions in one process** is the normal case: the process holds the router and
the shared, resident models (host-side), and each session is a separate actor with its
own working directory, all generating against the same weights through the per-model
serial gate (see Concurrency). Separate working directories give *cooperative*
isolation between sessions.

## Transcripts & recording

Every session from a Router is recorded, and the wiring is **structural** — an
unrecorded session can't be constructed.

**The Router is the recording root.** It carries an `id: ULID` assigned at
construction. ULIDs are lexicographically time-sortable, so recording roots and the
sessions under them sort chronologically with no separate timestamp. One Router
instance = one recording aggregate = one `recordings/<routerID>/` tree; a fresh `id`
each construction makes every process/router lifetime its own root. Pass an `id` in to
continue a prior root.

**A session is born holding its recorder — it can't be attached late or skipped:**

- **No public initializers.** A `RoutedSession` is only vended by `RoutedLLM` (from a
  resolved profile, from `Router.resolve`). The Router is the single root of session
  creation, so the recorder and `routerID` flow down that chain automatically —
  callers never pass or see a recorder.
- **The recorder is a non-optional `let`; "off" is a sink, not `nil`.** Disabling
  recording is `.none` (a no-op `TranscriptRecorder`) chosen once at the Router. The
  code path is identical whether recording or not — no branch can forget to record.
- **One bracketed generation chokepoint.** Every public method (`respond`,
  `streamResponse`, the guided variants) funnels through a single private `generate`,
  which runs the model *inside* a recorder bracket: open event → body → close/error
  event in `defer`. A new API can't bypass recording, and the close can't be skipped
  on `throw`.
- **`fork()` inherits.** The child takes `routerID`, the recorder, and
  `parentID = self.id` from `self`. No fork overload accepts a recorder, so you can't
  fork into an unrecorded or ungrouped state.
- **No side door.** The raw `ChatSession` / `LanguageModelSession` is never vended;
  `RoutedSession` is the only generation surface.
- **The recorder actor assigns `seq` + `ts` at append**, so concurrent forks across
  models still produce a totally-ordered log.

**Forks nest on disk to mirror the lineage** — a session's directory sits under its
parent's, so the path *is* the fork tree:

```
recordings/
  01J…ROUTER/
    manifest.json                 # router config, profiles resolved, start/end
    01J…A/                        # root session (parentID = nil)
      transcript.jsonl            # A's turns; first line is a `session` meta event
      01J…B/                      # fork of A
        transcript.jsonl
        01J…C/                    # fork of B
          transcript.jsonl
```

Each session writes its own `transcript.jsonl`; siblings are separate files (no write
contention). The "what did this whole Router do" view is `**/transcript.jsonl` merged
by `(ts, seq)` — and the ULID-ordered paths already give near-order. Provenance on
every line keeps it self-describing across files:

```
{ routerId, sessionId, parentId, slot, model, seq, ts,
  kind: "session"|"prompt"|"response"|"toolCall"|"toolOutput"|"embedding",
  grammar?, tokensIn, tokensOut, ms, … }
```

**Transcript nesting is lineage-derived and not caller-controllable.** The recording
directory is computed from the `parentID` chain inside the session, so a fork's
transcript always lands under its parent regardless of what the caller passes.
`workingDirectory` (where the agent's tools resolve files) is a *separate*,
overridable thing that defaults to the session's recording directory — override it and
the files move, but the transcript stays in the tree.

Recording stays **off the hot path and best-effort**: appends happen after the turn
returns, through the recorder actor; a sink failure logs but never fails generation. A
redaction hook and a level (`off` / `metadata-only` / `full`) gate what's written,
since local models still see sensitive prompts.

## Decisions

- **Runtime:** MLX only (mlx-swift-lm); no llama backend.
- **Platform:** macOS 27+ / FoundationModels v2 SDK; full `MLXFoundationModels` +
  `MLXGuidedGeneration` stack, no pre-27 fallback (branch dep until PR #334 merges).
- **Guided generation:** xgrammar via `MLXGuidedGeneration`, in three shapes — typed
  (`generating: T.self`, `@Generable`, decoded), dynamic JSON (`matching: jsonSchema`
  → `JSONValue`, for runtime schemas with no Swift type, e.g. an MCP tool), and raw
  (`following: Grammar` → text, also what a guided session binds). Grammar source is
  the caller's.
- **Sessions & KV cache:** a session owns its KV cache and **retains its creating
  profile** (`session.profile`), so resident models stay alive for its lifetime;
  `fork()` copies the prefilled prefix into a child; a session's cache frees on
  release. KV is pooled/reclaimable (separate from pinned weights); wide fork fan-out
  needs a KV budget + concurrency bound.
- **Concurrency:** generation is serialized per resident model (FIFO, one at a time);
  `fork()` fan-out is bounded by `maxConcurrentForks` and queues for admission — both
  on a fair async semaphore. Guided output is whole-chunk; only unconstrained text
  streams.
- **Sessions:** each session is an `actor` with its own `workingDirectory` (host;
  default a fresh temp subdir); many coexist in one process over the shared resident
  models, with separate working directories as cooperative isolation.
- **Transcripts:** the Router is the recording root (`id: ULID`, time-sortable); every
  session is **born holding** the Router's recorder (non-optional; `.none` is a no-op
  sink) and records through one bracketed generation chokepoint, so an unrecorded
  session can't exist. Forks **nest on disk** to mirror the fork tree; transcript
  location is lineage-derived, not caller-controllable. JSONL, best-effort, off the hot
  path.
- **Manifest:** Swift-literal `ProfileDefinition`.
- **Quant model:** one repo = one quant; `ModelRef` = one `(model, quant)`;
  author interleaves quant repos; router only accepts or skips.
- **Footprint safety:** conservative `× 1.2` margin per candidate.
- **Budget:** the profile holds all three slots resident at once, so they must
  **co-fit one budget**; allocate embedding → standard → flash in preference order.
- **Residency:** profile holds its models resident for its lifetime — no lease, no
  idle unload, no auto-eviction (simplicity over RAM efficiency). One active
  profile at a time; teardown evicts. Access is direct (no scope/closure).
- **Resolution:** async, reporting `ResolutionProgress` (`@MainActor @Observable`)
  for direct SwiftUI binding.
- **Weights:** cached on disk, reused across runs.

## Milestones

1. **Profiling + budget** — host profile, disk cache, budget. Unit-testable with
   injected machine specs.
2. **Footprint math** — pure footprint/budget functions given quant + weight
   bytes; unit-testable with injected values.
3. **Repo metadata + fit** — read each repo's quant + weight bytes from HF, feed
   milestone 2, decide fit (depends on 2).
4. **Joint resolution + progress** — `ProfileDefinition` + async `router.resolve`
   doing the embedding → standard → flash joint fit into a `LanguageModelProfile`,
   reporting `ResolutionProgress`, with failure diagnostics.
5. **Residency + access** — `preload()` all three on resolve, hold resident for the
   profile's lifetime, `evict()` on teardown; direct session/embed access.
6. **Tool integration** — constructors take router/profile; shared use validated.
7. **Integration test** — Swift Testing suite with tiny real models exercising a
   FoundationModels session + embedding while co-resident (see Testing).
8. **Guided generation** — grammar-constrained sessions over a routed model
   (`respond(to:following:)` / `makeGuidedSession`, `Grammar` = JSON Schema or EBNF)
   via `GrammarConstraint`.
9. **Session fork + concurrency** — `RoutedSession.fork()` via `KVCache.copy()` (cache
   freed on release); per-model serial generation queue and a `maxConcurrentForks`
   admission gate, both on a fair async semaphore.
10. **Transcripts & recording** — Router `id: ULID` + `TranscriptRecorder` sink;
    sessions emit tagged events through the bracketed generation chokepoint; per-session
    `transcript.jsonl` nested by fork lineage; `.jsonl` / `.inMemory` / `.none` sinks.
    Unit-testable with `.inMemory`.

## Testing

Unit-testable pieces (profiling, footprint math, joint allocation, diagnostics)
take injected machine specs / metadata and need no models — covered per milestone.

A separate **integration suite** (Swift Testing, `import Testing`) proves the real
path end-to-end with **deliberately tiny models** to keep download/CI cost low:

- A small 4-bit generation model and a small embedding model from `mlx-community`.
- **Gated** (needs real download + GPU): `@available(macOS 27, …)` and an opt-in env
  var so it never fires on a CI box without network/GPU (`.enabled(if:)`).
- **`.serialized`** suite + `.timeLimit` — these load real models under the budget
  and must not run concurrently.
- Asserts, in one resolved profile: progress advances `sizing → downloading →
  loading → ready`; a `profile.standard` session returns non-empty text;
  `profile.embedding.embed` returns vectors of the expected dimension; a guided
  session honors its grammar; and a `fork()` reuses the prefix and frees its cache on
  release — all three models co-resident. Recording asserts a fork's `transcript.jsonl`
  nests under its parent's directory and the merged log is totally ordered by `seq`.
