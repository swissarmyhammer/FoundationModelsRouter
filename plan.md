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
**MLX is the only runtime** (no llama backend) for weights and inference. We
don't load or run models ourselves; we decide *which* and *when*, then drive its
modules to supply a model — but we do **not** drive generation through MLX's own
chat surface. The session a caller actually talks to is Apple's
`LanguageModelSession` (see Backends), not `ChatSession`:

- **MLXLMCommon** — `ModelContainer` (loading; resident weights + KV cache
  substrate). We construct this; we do not construct its `ChatSession`.
- **MLXLLM** -> `standard` / `flash`. **MLXEmbedders** -> `embedding`.
- **MLXHuggingFace** — download/resolve from Hugging Face.
- **MLXFoundationModels** — `MLXLanguageModel`, the `LanguageModel`-protocol
  conformance that lets a resident `ModelContainer` run behind a real
  `LanguageModelSession`. This is the session backend, and it is **load-bearing**
  — see Backends.

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

**This is not an optional interop path — it is *the* session backend.**
`RoutedSession` is built directly on Apple's `LanguageModelSession`, conformed to
our resident MLX model via `MLXLanguageModel`. We do not implement our own
turn/tool-dispatch generation loop over `ModelContainer`/`ChatSession`; multi-turn
state, tool calling, and `@Generable` decoding all belong to `LanguageModelSession`
itself, not to code we wrote.

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
// Generation — a session over the resident standard model (LanguageModelSession-backed)
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

(Sessions are vended as Apple's own `LanguageModelSession`, backed by the resident
`ModelContainer` conformed to the `LanguageModel` protocol via `MLXLanguageModel`
(`MLXFoundationModels`) — see Backends. We do not construct `MLXLMCommon`'s
`ChatSession` and do not run our own generation/tool-dispatch loop.)

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

// A session is an `actor`: it isolates its mutable state (transcript, working
// directory) and serializes its own calls. It **retains its creating profile** (so
// resident models stay alive for its lifetime), and is **born holding the Router's
// recorder** — there is no public init, so an unrecorded session can't exist (see
// Transcripts & recording). `fork` sets `parentID = self.id`, nests its directory
// under the parent, and diverges into an independent child session that correctly
// **inherits the parent's conversation history** (seeded from the parent's
// transcript via `LanguageModelSession.init(model:tools:transcript:)`) — but does
// NOT inherit the parent's prefilled-prefix *compute* cheaply: that reuse is a
// performance gap in the pinned `mlx-swift-lm` dependency's `MLXLanguageModel.Executor`,
// which has no persisted-cache state to copy at the pinned revision, not a
// correctness gap (see Backends).
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

One stack, macOS 27+. `MLXLMCommon`'s `ModelContainer` loads and holds the
resident weights; `MLXEmbedders` handles embedding. **The session surface is
Apple's own `LanguageModelSession`** (`FoundationModels`, macOS 27+): a resident
`ModelContainer` is conformed to Apple's `LanguageModel` protocol via
`MLXLanguageModel` (`MLXFoundationModels`, our PR #334 fork), and `RoutedSession`
constructs and forwards to a real `LanguageModelSession` built over that
conformance. We do **not** construct `MLXLMCommon`'s `ChatSession` and do **not**
implement our own turn/tool-dispatch loop — multi-turn state, tool calling, and
`@Generable` decoding are `LanguageModelSession`'s, not ours. Guided generation
still runs on `MLXGuidedGeneration` (xgrammar) beneath the `LanguageModel`
conformance.

This is a **load-bearing** dependency, not an optional interop path: `RoutedSession`
has no `ChatSession`-backed fallback path. **Implemented**: `RoutedSession`'s live
conformance (`MLXFoundationModelsContainer`, in `LiveModelLoader.swift`) constructs
an `MLXLanguageModel` (wrapping this package's own `Downloader`/`TokenizerLoader`
injection). No code in `Sources/FoundationModelsRouter` constructs
`MLXLMCommon.ChatSession`, and no code drives `MLXGuidedGeneration`'s
`GuidedGenerationLoop` directly — that engine now runs *inside* `MLXLanguageModel`'s
own `Executor`, invoked by `LanguageModelSession` when a caller passes a `schema:`,
not by a loop we wrote.

**Session-as-factory, not a stateless invoker.** `MLXFoundationModelsContainer` is
not a generation entry point itself — it is a *factory*:
`makeSession(instructions:) -> any LanguageModelSessionBackend` builds one
`LanguageModelSession(model:instructions:)` and hands it to a new
`MLXFoundationModelsSessionBackend`, which **holds that session for its entire
lifetime** (`liveSession` is a `let`, never rebuilt). Every generation call on that
backend — `respond`, `streamResponse`, and the guided (`schema:`) path — runs
against the same `liveSession`, so the session's `Transcript` accumulates across
calls the way a real multi-turn chat does: a second `respond(to:maxTokens:)` sees
the first turn's content in context. `RoutedSessionActor` mirrors this at the
session layer — it is constructed with one `backend` it keeps for its whole
lifetime (see `LanguageModelSessionBackend` below and `RoutedSession.swift`), not a
per-call handle. There is no code path anywhere in `Sources/FoundationModelsRouter`
that constructs a new `LanguageModelSession` per `respond`/`streamResponse` call.

**`LanguageModelSessionBackend` — the seam between factory and session.** The
`LanguageModelSessionBackend` protocol (`Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`)
is what makes the factory/persistent-session split concrete: a `LoadedLLMContainer`
(the factory) *manufactures* a backend via `makeSession(instructions:)`, and from
then on the backend — not the container — owns the live `LanguageModelSession` and
its accumulated transcript for as long as the owning `RoutedSession` lives.
`makeFork()` is the seam `RoutedSession.fork(workingDirectory:)` calls to produce a
child backend: it does not start the child from scratch, it seeds it from the
parent's own accumulated conversation state (see "Resolved — `fork()`" below), then
the two diverge independently as each records its own further turns.

**Resolved — `fork()`.** The `fork()` design below was originally premised on
owning `MLXLMCommon`'s KV cache directly (`KVCache.copy()`), which required sitting
below `ChatSession`. Research against the real FoundationModels v2 SDK
(`FoundationModels.swiftinterface`, macOS 27 SDK) found a genuine
transcript-continuation primitive: `LanguageModelSession.init(model:tools:transcript:)`
constructs a new session that continues a prior session's `Transcript`. **This is
now implemented**: `MLXFoundationModelsSessionBackend.makeFork()`
(`LiveModelLoader.swift`) builds the forked session as
`LanguageModelSession(model: model, tools: [], transcript: liveSession.transcript)`
— the child begins holding every entry the parent's transcript has accumulated so
far (including the parent's `Transcript.Entry.instructions` entry, if any), then
diverges independently as each session's own further turns append to its own
transcript. So **conversation history is correctly inherited across a fork** — a
child sees everything its parent said and heard up to the fork point, and forking
mid-conversation no longer silently drops that context.

What this primitive does **not** give back is cheap prefix reuse at the GPU level.
Verified by reading the pinned `swissarmyhammer/mlx-swift-lm` fork's
`Libraries/MLXFoundationModels/MLXLanguageModel.swift` (branch
`mlx-foundationmodels`, revision `e6ccd2721` as of 2026-06-29, tracking upstream PR
#334): `MLXLanguageModel`'s `Executor.respond(to:model:streamingInto:)` re-derives
its full `LMInput` from `TranscriptConverter.mlxMessages(for: request.transcript)`
and runs a fresh `MLXLMCommon.generate(...)` call on **every** turn — there is no
`KVCache`, prompt cache, or any other persisted-across-turns state anywhere in that
module (confirmed by grep: zero `KVCache`/`promptCache`/`trim(`/`savePromptCache`
references in `Libraries/MLXFoundationModels`). So every turn of every session —
forked or not — reprocesses its whole transcript from scratch under this backend.
**This is a performance observation, not a correctness gap**: conversation
correctness (fork inherits the right history; a session sees its own prior turns)
is fully implemented and tested today; only the *compute-reuse* optimization
(skipping re-derivation of the shared prefix's `LMInput`/KV state) is unavailable,
because the upstream `MLXLanguageModel` executor this router depends on has no
persisted-cache mechanism to reuse it against. That upstream gap is filed and
tracked as its own concern against the `mlx-swift-lm` fork, not as an open item of
this router's design — revisit if a future `mlx-swift-lm` release adds a
persisted-cache executor.

## Guided generation

xgrammar gives us **grammar-constrained decoding**: output is forced to be valid for
a grammar, so structured results are correct *by construction*, not by
hope-and-parse. The primitive is a **guided session** — a session whose responses
are constrained to a `Grammar` (a JSON Schema or a raw EBNF grammar).

### The engine

**Resolved.** `MLXFoundationModels`' `MLXLanguageModel.Executor` (the
`LanguageModelExecutor` witness invoked by `LanguageModelSession`) drives
`MLXGuidedGeneration`'s xgrammar engine (`GrammarConstraint` +
`GuidedGenerationLoop.run(…)`) **internally**, whenever the framework's
`LanguageModelSession.respond(to:schema:)`/`streamResponse(to:schema:)` is called
with a non-nil `schema:` — confirmed by reading
`Libraries/MLXFoundationModels/MLXLanguageModel.swift`'s `Executor.respond(...)`,
which branches on `request.schema` and, when present, compiles a
`GrammarConstraint` and runs `GuidedGenerationLoop.run` itself. So the constrained
decode is invoked *by FoundationModels*, underneath the `LanguageModel`
conformance, not by a loop this router writes: `RoutedLLM`'s
`respond(to:following:)`/`makeGuidedSession(_:)` (see Core Types) call
`LanguageModelSession.respond(to:schema:)` and let `MLXLanguageModel` do the rest.

**The missing piece was building the `schema:` itself.** `LanguageModelSession`'s
guided API takes a typed `GenerationSchema`, not a raw grammar string — so turning
a caller's runtime JSON Schema *text* into a `GenerationSchema` is this router's own
work. The obvious approach — `JSONDecoder().decode(GenerationSchema.self, from:)`,
since `GenerationSchema` is `Codable` and its *encoding* is a standard JSON Schema
document — was tried and **empirically fails**: `GenerationSchema`'s decode
requires proprietary metadata its own encoder adds (an `x-order` key recording
property order, a mandatory `title` on every object/string node) and treats a
*titled* string schema as a closed-enum carrier, rejecting a plain titled string
outright (see `LanguageModelSessionBackendTests.GenerationSchemaDecodingTests`, a
real, run assertion, not a comment). So `GenerationSchema`'s `Codable` conformance
only round-trips *its own* encoding — it is not a general JSON-Schema ingestion path
for a caller's foreign schema (e.g. an MCP tool's `inputSchema`).

Instead, `RuntimeJSONSchemaConverter` (`Sources/FoundationModelsRouter/Guided/`)
hand-walks the parsed JSON Schema tree into `DynamicGenerationSchema` nodes — a pure
data transform, not a generation loop — covering exactly the subset
`Grammar.validateForXGrammar()` already accepts: object (`properties`/`required`),
string/number/integer/boolean leaves, closed string `enum`s (`DynamicGenerationSchema(name:anyOf:
[String])`), and arrays (`items`, `minItems`/`maxItems`), nestable to any depth.
Anything else (`oneOf`/discriminated unions, `$defs`-based recursion) throws a
typed `ConversionError` rather than silently mis-converting — real-tested, not
theoretical (`RuntimeJSONSchemaConverterTests`, 11 cases including the schema
derived from a real `@Generable` type). The live `MLXFoundationModelsContainer`
uses this converter for both the typed shape (round-tripping `T.generationSchema`
through JSON) and the dynamic/raw shapes (a caller's own JSON Schema text).

**`Grammar.ebnf(_:)` is genuinely blocked**, not deferred: `LanguageModelSession`
has no entry point that accepts a raw grammar string — only a typed `schema:`
parameter built from `GenerationSchema`/`DynamicGenerationSchema`. There is no way
to drive an arbitrary EBNF/GBNF grammar through this session surface without
compiling our own generation loop underneath it, which is exactly what this pivot
removes. `MLXFoundationModelsContainer.respond(to:instructions:following:maxTokens:)`
throws `GuidedRequestError.ebnfNotSupportedByLanguageModelSession` for this case.

### Three response shapes

Pick by whether the caller has a Swift type for the result:

- **Typed** — `respond(to:generating: T.self) -> T` for a `@Generable` type. The
  schema is *derived from the type* and the result decoded into it. One source of
  truth; use when the shape is known at compile time.
- **Dynamic JSON** — `respond(to:matching: jsonSchema) -> JSONValue` for a schema
  known only at runtime with **no Swift type** — e.g. an MCP tool that "returns JSON"
  against its advertised schema. The result is valid for the schema but introspected
  dynamically (`JSONValue`), never decoded into a fixed type.
- **Raw** — `respond(to:following: Grammar) -> String`; unparsed constrained text
  out. `.jsonSchema(_)` works (see "The engine"); `.ebnf(_)` throws
  `GuidedRequestError.ebnfNotSupportedByLanguageModelSession` — `LanguageModelSession`
  has no raw-grammar entry point. This is also what a guided session binds, so
  `makeGuidedSession(_:).respond(to:)` and its forks return raw text the caller
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
    let sub = template.fork()                  // inherits the grammar; independent conversation
    // sub.respond(to: diff) → raw JSON text; decode to Review or JSONValue.
}                                              // each `sub` + its cache freed at scope exit
```

Caveat: two layers reject unsupported schemas, both with typed errors rather than a
crash. `Grammar.validateForXGrammar()` rejects `$ref` / `allOf` / `format` up front
(xgrammar's own supported-subset boundary). `RuntimeJSONSchemaConverter` then
compiles what's left into a `GenerationSchema`; it covers object/array/scalar/closed-enum
constructs but rejects `oneOf`/discriminated unions and anything else it doesn't
recognize with a typed `ConversionError` (see "The engine").

## Sessions & KV cache

**Correctness: implemented. Compute-reuse: a performance gap in a dependency we
don't control, not a correctness gap.** The mechanism originally sketched here was
designed for owning MLX's KV cache directly below `ChatSession`, which we no
longer construct. Under `LanguageModelSession`, the real primitive is
transcript continuation: `LanguageModelSession.init(model:tools:transcript:)`
constructs a new session that continues a prior session's `Transcript`, and
`RoutedSession.fork(workingDirectory:)` is wired to it —
`MLXFoundationModelsSessionBackend.makeFork()` builds the child session as
`LanguageModelSession(model: model, tools: [], transcript: liveSession.transcript)`,
so a fork **correctly inherits its parent's conversation history** up to the fork
point, then diverges independently. This is tested against stubs
(`Tests/FoundationModelsRouterTests/MultiTurnSessionTests.swift`) and, in the gated
integration suite, against a real model
(`Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`'s
`makeForkSeedsFromParentTranscript`) — not aspirational. That same gated file also
carries `secondTurnReusesFirstTurnsKVCache`, a hard, never-weakened assertion that
`usage.input.cachedTokenCount > 0` on a session's second turn — written as the
acceptance test for the upstream compute-reuse fix described below. It is
currently expected to fail against the pinned revision (every `usage` this
backend's `Executor` constructs hardcodes `cachedTokenCount: 0` — see the
compute-reuse discussion just below), and is opt-in
(`FM_ROUTER_INTEGRATION_TESTS`) precisely so that expected failure never blocks
CI; it will start passing the moment the upstream fix lands.

What is *not* recovered is cheap prefix reuse at the compute layer. Reading the
pinned `swissarmyhammer/mlx-swift-lm` fork's `MLXLanguageModel.Executor` (branch
`mlx-foundationmodels`, revision `e6ccd2721`) found it re-derives its full model
input from the request's `Transcript` and runs a *fresh* `MLXLMCommon.generate(...)`
on every single turn — there is no `KVCache`, prompt cache, or any
persisted-across-turns state anywhere in `Libraries/MLXFoundationModels`
(confirmed by grep: zero hits for `KVCache`/`promptCache`/`trim(`/`savePromptCache`).
So every turn, forked or not, reprocesses its whole transcript from scratch under
this backend today. This is purely a **performance** characteristic of the
upstream `MLXLanguageModel` executor this router depends on — it has no
persisted-cache mechanism to reuse a shared prefix's compute against, at the
pinned revision. That upstream fix is filed and tracked as its own concern against
the `mlx-swift-lm` fork, not as an open correctness item of this router's design.

1. A session — root or fork — is driven through its own persistent
   `LanguageModelSessionBackend`, which owns one `LanguageModelSession` for the
   session's whole lifetime and accumulates its `Transcript` turn over turn (see
   Backends).
2. `fork()` seeds the child's backend from the parent's *current* accumulated
   transcript (`makeFork()`, under the parent's serial gate so the read can't race
   an in-flight turn — see `RoutedSessionActor.fork(workingDirectory:)`), so the
   child sees everything the parent said and heard up to that point, then the two
   diverge independently and may run concurrently.
3. **A session's backend (and its `LanguageModelSession`) dies with the session**
   (ARC) — releasing a fork frees whatever conversation state it holds. A session
   also **retains its creating profile** (`session.profile`), so resident models
   can't be freed out from under it; the profile evicts only once its handle and
   all sessions/forks are released.

Substrate previously verified below `ChatSession` (**confirmed absent from the
`LanguageModelSession`/`MLXLanguageModel` path at the pinned revision** — see
above): `KVCache.copy()` (compute-level fork), `trim(_:)` (serial reuse — recycle
one cache instead of copying), `savePromptCache` / `loadPromptCache` (spill a warm
prefix to disk). None of these are reachable through `MLXLanguageModel.Executor`
today; `fork()`'s conversation-history inheritance above does not depend on any of
them.

**Budget caveat (moot at the pinned revision, kept for when compute-level reuse
becomes real):** a hypothetical `copy()`-based cache is a *deep* copy, so K
concurrent forks would hold K× the prefix KV. KV is a **reclaimable, pooled**
resource separate from pinned weights, and the footprint math budgets only one
cache per model — so a wide fan-out would need a KV budget
carved from headroom and a bound on concurrent forks, or it would OOM a machine
that held the models comfortably, *if and when* a persisted-cache executor exists
to make this a real cost.

## Concurrency

Generation on a resident model is **serialized** — one at a time per model, FIFO.
Concurrent `respond()` calls (including from forks of the same model) **queue** rather
than run in parallel: MLX generation isn't safe to interleave on a single model's
weights, and the GPU runs one stream anyway. Each `RoutedLLM` owns a serial gate.

**Fork fan-out is bounded** by `maxConcurrentForks` (a `Router` setting): at most that
many fork sessions are in flight at once, capping the K× prefix-KV cost of `copy()`
(mechanism per Backends' open question — see "Sessions & KV cache").
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
is an **`actor`**, so its mutable state (transcript, working directory, and whatever
cache state `LanguageModelSession` carries) is isolated and its own calls serialize.

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
  on `throw`. **Tool-call recording gap — mechanism identified, not yet wired
  (no tool support exists on `RoutedSession` to wire it to).** If
  `LanguageModelSession` owns tool dispatch internally, per-tool-call
  (`toolCall`/`toolOutput`) events are *not* automatically captured by wrapping the
  outer `respond`/`streamResponse` call. Two real mechanisms were found in the
  FoundationModels v2 SDK: (1) `LanguageModelSession.Response<Content>.transcriptEntries`
  / `ResponseStream<Content>.Snapshot.transcriptEntries` return the `ArraySlice<Transcript.Entry>`
  a turn *added*, which includes `.toolCalls`/`.toolOutput` entries when tools ran —
  so the chokepoint could inspect this slice after each turn and emit
  `toolCall`/`toolOutput` transcript events without touching `Tool` conformances at
  all; (2) instrumenting each `Tool.call(arguments:)` directly, wrapping the caller's
  tool in a recording decorator, is the fallback if (1)'s entries turn out to lack
  enough detail. Neither is implemented: `RoutedSession`/`RoutedLLM` currently has no
  `tools:` parameter anywhere in its API, so there is no tool-calling code path to
  exercise or test yet — this is deferred until tool support is added, at which point
  (1) is the preferred mechanism to wire in first.
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

### Transcript fidelity: persist the SDK's own `Transcript`, not a paraphrase (planned)

**The gap.** The package has two unrelated "transcript" concepts. `FoundationModels.Transcript`
is the SDK's own conversation state — the `RandomAccessCollection` of `Transcript.Entry` a
`LanguageModelSession` accumulates, the value that actually drives generation, and the only
thing `LanguageModelSession(model:tools:transcript:)` accepts when seeding a fork. Our on-disk
`TranscriptEvent` log is a bespoke audit format that *paraphrases* it: the `generate`
chokepoint hand-builds one `.prompt` and one `.response` event per turn from the
prompt/response *strings it already had before calling the SDK*, not from what the SDK
actually appended. The two drift by construction: a single `respond()` adds *multiple*
entries to the real transcript (at minimum a `.prompt` and a `.response` entry; an
`.instructions` entry on first contact; `.toolCalls`/`.toolOutput`/`.reasoning` when
applicable — the SDK's own `Response.transcriptEntries: ArraySlice<Transcript.Entry>` is
direct evidence a turn's delta is a slice, not a pair of strings). Nothing on disk can
reconstruct a real `Transcript`, so recorded history cannot re-seed a session in a new
process, and any GUI over the recordings renders a lossy paraphrase rather than the
conversation the model saw.

**Verified SDK surface** (macOS 27 beta SDK,
`MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`;
every statement below was read from that interface, none assumed):

- `Transcript.Entry` has exactly six cases: `.instructions(Instructions)`,
  `.prompt(Prompt)`, `.toolCalls(ToolCalls)`, `.toolOutput(ToolOutput)`,
  `.response(Response)`, and (27+) `.reasoning(Reasoning)`.
- Payloads: `Instructions{id, segments, toolDefinitions: [ToolDefinition{name, description,
  parameters: GenerationSchema}]}`; `Prompt{id, segments, options: GenerationOptions,
  responseFormat?, (27+) contextOptions, metadata}`; `ToolCalls` — a
  `RandomAccessCollection` of `ToolCall{id, toolName, arguments: GeneratedContent, (27+)
  metadata}`; `ToolOutput{id, toolName, segments}`; `Response{id, assetIDs, segments, (27+)
  metadata}`; `Reasoning{id, segments, signature: Data?, metadata}`.
- `Transcript.Segment` has four cases: `.text(TextSegment{id, content})`,
  `.structure(StructuredSegment{id, schemaName, content: GeneratedContent})`, and (27+)
  `.attachment(AttachmentSegment{id, content: Attachment(.image(ImageAttachment)), label})`
  and `.custom(any CustomSegment)` — an *existential*, but a well-behaved one: the
  `CustomSegment` protocol requires `var id: String` and `var content: Content` with
  `associatedtype Content : Codable & Equatable & Sendable`, so any custom segment's content
  is *guaranteed encodable*. What the protocol does **not** declare is an initializer, so
  re-instantiating a concrete conforming type from disk needs a router-side registry (see
  "Honest fidelity scope" below).
- `Transcript : Codable`. `Transcript.Entry` alone is **not** Codable (only `Sendable,
  Identifiable, Equatable`). `GenerationSchema : Codable`. `GeneratedContent` is not Codable
  but round-trips via `jsonString` / `init(json:) throws`. `GenerationOptions` is **not**
  Codable; its public surface is `temperature`, `maximumResponseTokens`, `toolCallingMode`,
  and an opaque `sampling: SamplingMode?` with constructors but no public introspection.
- Every entry/segment type has a **public memberwise initializer**, `Transcript(entries:)`
  is public, and `LanguageModelSession(model: some LanguageModel, tools:, transcript:)` is
  public — so disk → `[Transcript.Entry]` → `Transcript` → live session is achievable
  entirely with public API. **There is no SDK wall.**
- `LanguageModelSession : Observation.Observable`, `transcript` is an observable stored
  property, and `Response<Content>` carries `transcriptEntries` (the turn's delta) and (27+)
  `usage: LanguageModelSession.Usage{input.totalTokenCount, input.cachedTokenCount,
  output.totalTokenCount, output.reasoningTokenCount}`.

**Chosen architecture: observe the real transcript and persist its deltas.** The
event-bracket's role as *content source* is superseded. After each turn completes — inside
the same serial-gate window the bracket already occupies, on the success and throw paths
alike — the session snapshots the backend's real transcript and diffs by entry count:
everything past `persistedEntryCount` is what the SDK actually appended this turn, and
*those real entries* are mapped into events and persisted. Pull-based snapshotting at the
deterministic point is chosen over push-based `withObservationTracking`: `Observable` fires
willSet without payloads and out of band with the serial gate, while the post-turn snapshot
observes exactly the settled state, in order, with no reentrancy hazards. A fork's baseline
starts at *its parent's entry count at fork time* (the fork copies the parent transcript),
so inherited history is never re-persisted — and the same number is recorded as the fork's
cut point in the session index (below), making the diff baseline and the lineage
reconstruction rule one fact, not two.

`LanguageModelSessionBackend` grows one requirement to make this possible —
`transcriptEntries() -> [Transcript.Entry]` (today only the concrete
`MLXFoundationModelsSessionBackend` can see `liveSession.transcript`; `respond` returns a
bare `String`). Test stubs fabricate entries with the SDK's public initializers.

**Schema: entry-shaped `TranscriptEvent`, one event per `Transcript.Entry`.** Our own schema
(not Apple's opaque whole-`Transcript` encoding) stays the on-disk format, because it
composes with the recording level, the redact hook, the JSONL append-only sink, and the
provenance envelope. It grows to mirror the real entry shape:

- `Kind` gains `instructions`, `toolCalls`, and `reasoning`; `prompt`/`response` now mean
  "the SDK appended this entry", not "we bracketed a call". `session` and `embedding` remain
  router-only kinds (embeddings never enter Apple's transcript). The legacy `toolCall` case
  remains decodable but is no longer written.
- A new optional `entry: TranscriptEntryPayload` field carries the structural mirror:
  Apple's entry `id`, segments (`text` content; `structure` as `schemaName` +
  `GeneratedContent.jsonString`; `attachment` as label + URL when available; `custom` as its
  `id` + a type-discriminator string + its `content` encoded to JSON, since
  `CustomSegment.Content` is protocol-guaranteed `Codable`), tool
  definitions (name, description, `GenerationSchema` via its own Codable), tool calls (id,
  toolName, arguments JSON), `assetIDs`, reasoning `signature`, and the introspectable slice
  of `GenerationOptions`. Old lines (no `entry`) still decode; `MergedTranscript`'s flat
  `(ts, seq)` view is unchanged.
- The flattened `text` stays as the human/GUI convenience body and remains what the gate
  trims: `metadataOnly` now also strips payload content (keeping ids, kinds, counts, tool
  names — shape without content), and the redact hook applies to every textual content site
  in the payload, not just `text`. Stripping stamps an explicit `contentRemoved` marker on
  the payload so reconstruction can *refuse* stripped shapes with a typed error instead of
  silently rebuilding empty entries.

**What stays event-driven, and why.** The envelope
(`routerId`/`sessionId`/`parentId`/`slot`/`model`/`seq`/`ts`), the `session` meta line,
`embedding` events, `grammar`, wall-clock `ms`, and `tokensIn`/`tokensOut` (from per-turn
`usage` deltas where the backend reports them) are router facts Apple's `Transcript` does
not carry — they remain recorder-stamped. A failed turn still records a bodyless
`response`-kind close so every turn leaves a trace, *plus* whatever entries the SDK durably
appended before failing — which is precisely what snapshot-diffing captures that
string-bracketing never could.

**Retrieval & the fork hierarchy as first-class data.** Today the lineage is only implicit
in directory nesting, and the only query is "everything under this router, flattened"
(`MergedTranscript.merged(under:)`). Two additions:

- **A session index.** `recordings/<routerId>/sessions.jsonl` gains one appended record per
  session at creation — `{sessionId, parentId, path, forkedAtEntryCount, slot, model,
  createdAt}` — written from the two places that know it: root vending and
  `fork(workingDirectory:)`. Appends are best-effort JSONL like the transcript itself (no
  read-modify-write). The index makes lookup by `ULID` O(index) instead of O(walk every
  file), and `forkedAtEntryCount` records where the child's inherited history ends.
- **`TranscriptTree`.** Loads the index (falling back to a directory walk plus per-event
  `parentId` for pre-index recordings) and exposes the hierarchy as data: the tree of
  sessions under a router, `children(of:)`, `events(forSession:)` (that session's own
  delta), and `effectiveEntryEvents(forSession:)` — the session's *whole effective
  conversation*, computed recursively as the parent's effective entries truncated to
  `forkedAtEntryCount` plus the session's own, exactly mirroring what its live `Transcript`
  held.

**Reconstruction end-to-end — rooted at the root session.** `effectiveTranscript(forSession:)`
maps the effective entry payloads back through the public initializers into
`[Transcript.Entry]` and returns `Transcript(entries:)` — directly usable as the
`LanguageModelSession(model:tools:transcript:)` seed. Round-tripping is validated in both
directions (entry → payload → entry equality on every representable field). Restoration is
a *tree* operation, not per-arbitrary-session: given a **root session's id** (and only the
root's — forks are never restored individually), a fresh `Router` pointed at the same
recordings root reconstructs the whole associated fork tree in memory — the root plus every
descendant, each node re-seeded with its own effective `Transcript` — synced with what is on
disk. The proof is a gated integration test (`FM_ROUTER_INTEGRATION_TESTS`, matching the
existing pattern in `Tests/FoundationModelsRouterIntegrationTests/`): drive real turns on a
root, fork it into a genuine branching multi-level tree, fork a fork, assert the on-disk
state mid-test (turns sync as they happen, not only at teardown), discard the router and
every in-memory session, construct a **new** `Router` over the same directory, restore by
the root id alone, and assert the restored tree matches — structure, per-node turns, and,
the fidelity payoff, that a *new* live turn on a restored node sees its prior context
exactly as an never-torn-down session would.

**Honest fidelity scope.** Faithful capture is a property of `full`-level recording *only*:
`metadataOnly` intentionally discards content (reconstruction yields shape, not a usable
seed) and `off` discards everything — that is the levels' contract, not a bug. Within
`full`, the known, deliberate losses — each degraded explicitly rather than silently:
`GenerationOptions.sampling` (no public introspection; dropped), the
`Prompt`/`ToolCall`/`Response`/`Reasoning` `metadata` dictionaries (existential-typed;
dropped), image attachment *bytes* (label/URL persisted; pixels not — and an in-memory
attachment whose `ImageAttachment.url` is `nil` cannot be rebuilt at all, so it degrades to
a labeled text segment), and a `Prompt.responseFormat`, which round-trips through its
persisted `GenerationSchema` (Codable) via `ResponseFormat(schema:)` — there is no
`init(name:)` — so a format originally built from a `Generable` *type* rebuilds in schema
form.

`.custom` segments are **not** on that list — they round-trip. The `CustomSegment` protocol
guarantees `content: Content` with `Content : Codable`, so *persisting* is unconditional
and registry-free: the mapper opens the existential and stores the segment's `id`, a type
discriminator string, and the content encoded to JSON. Only *rebuilding* needs outside
help, because the protocol declares no initializer. The router defines a refinement,
`PersistableCustomSegment: CustomSegment`, adding `init(id: String, content: Content)
throws` and a stable `static var typeDiscriminator: String` (defaulting to the type's
fully-qualified name — which is also what the mapper writes for types that never conform),
plus a `CustomSegmentRegistry` value the integrator populates with their concrete types
(`registry.register(MySegment.self)`) and passes to reconstruction/restore. Registering a
second type under an already-registered discriminator traps (`preconditionFailure`) rather
than silently overwriting — two conformances aliasing one on-disk representation is a setup
bug, not a runtime condition to degrade through, and `register` runs at integrator
setup time, not on the decode path. Rebuild looks the discriminator up in the registry,
decodes `Content` with `JSONDecoder`, and calls `init(id:content:)`; an unregistered
discriminator is a typed, descriptive error naming the discriminator — never a silent drop
or a lossy text stand-in. The persisted content JSON is
a text body like any other: `metadataOnly` strips it and the redact hook covers it. None of
these occur on today's MLX text paths — instructions, text prompts/responses, guided structured
responses, and tool traffic round-trip losslessly.

## Decisions

- **Runtime:** MLX only (mlx-swift-lm) for weights/inference; no llama backend.
- **Session engine:** Apple's `LanguageModelSession` (`FoundationModels`, macOS 27+)
  is the load-bearing session surface, not `MLXLMCommon`'s `ChatSession` — **implemented**:
  `MLXFoundationModelsContainer` (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`)
  is a **session factory** (`makeSession(instructions:) -> any LanguageModelSessionBackend`),
  backed by `MLXLanguageModel` (`MLXFoundationModels`). No `ChatSession` construction
  and no hand-rolled generation/tool-dispatch loop anywhere in
  `Sources/FoundationModelsRouter`. `fork()`'s cheap-*compute*-reuse under this backend
  is a **performance gap in the upstream dependency, not a correctness gap** (see
  Backends) — verified against the pinned `mlx-swift-lm` dependency's
  `MLXLanguageModel.Executor`, which has no persisted-cache mechanism at the pinned
  revision, so `KVCache.copy()` does not apply; fork's *conversation-history*
  inheritance, by contrast, is implemented and tested (see below).
- **Session-as-factory (replaces the stateless invoker):** a `LoadedLLMContainer`
  manufactures a `LanguageModelSessionBackend` once per session
  (`makeSession(instructions:)`), and that backend holds one `LanguageModelSession`
  for its whole lifetime (`MLXFoundationModelsSessionBackend.liveSession`), so every
  call on a session accumulates conversation state instead of starting over. This
  replaced an earlier stateless-invoker design where each call constructed and
  discarded a fresh `LanguageModelSession`, which **silently discarded all
  conversation history** — every turn was effectively single-turn, `respond`
  ignored everything said before it, and `fork()` had nothing meaningful to seed a
  child from. `makeFork()` seeds a forked backend from the parent's accumulated
  `Transcript` via `LanguageModelSession.init(model:tools:transcript:)`, so a fork
  now correctly continues its parent's conversation instead of starting cold.
- **Platform:** macOS 27+ / FoundationModels v2 SDK; full `MLXFoundationModels` +
  `MLXGuidedGeneration` stack, no pre-27 fallback (branch dep until PR #334 merges).
- **Guided generation:** xgrammar via `MLXGuidedGeneration`, invoked *underneath*
  `MLXLanguageModel`'s `Executor` when `LanguageModelSession.respond(to:schema:)` is
  called — never by a loop of our own (**implemented**, verified by reading the
  Executor's source). Three shapes — typed (`generating: T.self`, `@Generable`,
  decoded via `T.generationSchema` directly), dynamic JSON (`matching: jsonSchema`
  → `JSONValue`, for runtime schemas with no Swift type, e.g. an MCP tool), and raw
  JSON-Schema (`following: .jsonSchema(_)` → text, also what a guided session binds).
  The dynamic/raw shapes compile a caller's JSON Schema text into a `GenerationSchema`
  via the hand-written `RuntimeJSONSchemaConverter` (`DynamicGenerationSchema`-based,
  not `JSONDecoder`-based — see Guided generation for why `GenerationSchema`'s own
  `Codable` decode doesn't work for a foreign schema), covering object/array/scalar/enum
  constructs. **`following: .ebnf(_)` is unsupported and throws a typed error** —
  `LanguageModelSession` has no raw-grammar entry point, only a typed `schema:`
  parameter.
- **Sessions & KV cache:** a session **retains its creating profile**
  (`session.profile`), so resident models stay alive for its lifetime. `fork()`
  produces an independent child session (nested transcript, freed on release) whose
  backend is seeded from the parent's accumulated `Transcript` via
  `LanguageModelSession.init(model:tools:transcript:)` — **conversation-history
  inheritance is implemented and tested**, not aspirational. What it does **not** do
  is reuse the parent's prefilled-prefix *compute* — verified against the pinned
  `mlx-swift-lm` dependency, whose `MLXLanguageModel.Executor` has no persisted-cache
  mechanism to reuse it against (see Backends and "Sessions & KV cache" for
  the citation); this is a performance property of that upstream dependency, not a
  gap in this router's own correctness. `SessionKVCache` stays an inert copy/free
  lifecycle contract for every current conformer, live included.
- **Concurrency:** generation is serialized per resident model (FIFO, one at a time);
  `fork()` fan-out is bounded by `maxConcurrentForks` and queues for admission — both
  on a fair async semaphore. Guided output is whole-chunk; only unconstrained text
  streams.
- **Sessions:** each session is an `actor` with its own `workingDirectory` (host;
  defaults to the session's recording directory); many coexist in one process over
  the shared resident models, with separate working directories as cooperative
  isolation.
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

**Pivot note (resolved):** milestones 6 (tool integration), 8 (guided generation),
and 9 (session fork) were scoped against `ModelContainer`/`ChatSession` directly.
`RoutedSession` is now built on `LanguageModelSession` (see Backends):
milestone 8's guided generation is **implemented** against the real backend
(`MLXFoundationModelsContainer` + `RuntimeJSONSchemaConverter`, `.ebnf` blocked with
a typed error); milestone 9's `fork()` is **implemented** for conversation-history inheritance
(`makeFork()` seeds the child from the parent's `Transcript` via
`LanguageModelSession.init(model:tools:transcript:)`, tested — see Sessions & KV
cache) and **split/blocked** only on the cheap-*compute*-reuse half — a
performance property, not a correctness one — verified, not assumed, against the
pinned `mlx-swift-lm` dependency's `MLXLanguageModel.Executor`.
Milestone 6 (tool integration) is unaffected in practice: `RoutedSession`/`RoutedLLM`
still has no `tools:` parameter, so there is nothing tool-specific to re-scope yet
beyond the transcript tool-call recording mechanism identified in "Transcripts &
recording."

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
  session honors its grammar — all three models co-resident. Recording asserts a
  fork's `transcript.jsonl` nests under its parent's directory and the merged log is
  totally ordered by `seq`. Per the resolved "Sessions & KV cache" open question,
  `fork()`'s assertion is lineage/independent-generation only (no prefix-reuse/cache-release
  assertion is written, since that mechanism does not exist against the pinned
  dependency — see Backends).

Additionally, GPU-free unit coverage backs the guided-generation resolution
directly (`Tests/FoundationModelsRouterTests/LanguageModelSessionBackendTests.swift`):
`GenerationSchemaDecodingTests` proves — with real, run assertions against the
actual `FoundationModels` types, not comments — that `GenerationSchema`'s `Codable`
conformance rejects a caller's plain JSON Schema text; `RuntimeJSONSchemaConverterTests`
proves the hand-written converter used instead actually compiles a real
`GenerationSchema` for every construct it claims to support (object, nested object,
array, string/number/integer/boolean, closed enum, plus the schema derived from a
real `@Generable` type) and throws a typed error for what it doesn't (`oneOf`, a
malformed array). None of this needs network or GPU: constructing a schema value
never touches a model.
