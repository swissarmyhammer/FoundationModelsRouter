# Plan: Model pool — one resident copy of each model for the whole process

Make the resident-model pool a process-wide object. When two `Router`
instances in one process name the same model, that model is loaded one time.
When two slots in one router name the same model, that model is loaded one
time. The memory budget prices the union of every resident model in the
process, not the residents of one router.

## 1. What the code does today

Measured on `main` at commit `37c7942` (2026-09-05).

### 1.1 One router: pooling is done

`Router` (`Sources/FoundationModelsRouter/Router.swift`) holds a private
`pool: [ResidencyKey: PoolEntry]`. The key is `(ModelRef, Role)`, where
`Role` is `.llm(context: Int)` or `.embedding`. Each entry counts the slot
acquisitions that hold it. `resolve(profile:reporting:)` bumps an entry that
is already resident and loads only a key that is new. `release(token:)`
decrements the count and evicts at zero. `poolLock` serializes both calls.

Proven by `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift`:

- Two profiles that name one model load it one time
  (`sharedRefsLoadOnceAndBothGenerate`).
- One profile that names one model in `standard` and `flash` loads it one
  time and holds two KV caches against the budget
  (`sharedGenerationPairHoldsBothKVCachesAgainstTheBudget`).
- A model stays resident while any profile holds it
  (`releasingOneProfileKeepsSharedModelLoadedForTheOther`).

So the second half of the request ("the same model in multiple slots of one
router") is already so, with one exception in §1.3.

### 1.2 Two routers: no pooling at the router layer

Each `Router` has its own `pool`, its own `poolLock`, and its own
`residentProfiles`. Two routers do not see each other. The consequences:

1. **The budget is wrong in both directions.** Each router prices its own
   residents against the full machine budget (`hostBudget()` less the sum of
   its own `pool`). Two routers with disjoint models each think the whole
   machine is free, so together they can over-commit memory. Two routers
   with the same model both charge its weights, so together they can refuse a
   profile that fits.
2. **A release in one router evicts the model under the other.** The live
   loader's `evict(container:)` calls `MLXLanguageModel.evict()`, which
   removes the container from the MLX layer's process-global cache (§1.4).
   The other router's handle still exists, and its next call reloads the
   weights from disk. Memory churn, and a multi-second stall.
3. **Embedders are loaded one time per router.** `LiveModelLoader.loadEmbedder`
   calls `EmbedderModelFactory.shared.loadContainer`, which has no cache
   (`GenericModelFactory.loadContainer` in `MLXLMCommon/ModelFactory.swift`
   loads on every call). Two routers with the same embedder hold two copies.
4. **Two generation gates for one container.** `ResidentModelGates` is minted
   per pool entry, so two routers over one MLX container serialize
   generation only inside each router. The MLX `ModelContainer` is a serial
   access container, so this is safe, but it is not the invariant the gate
   documents.

### 1.3 The context in the residency key does not match the loader

`ResidencyKey.Role.llm(context:)` keys a generation model by its working
context. The comment says "the KV cache is sized at load time". That is not
what the live loader does: `LiveModelLoader.loadLLM(ref:slot:context:reporting:)`
never reads `context`. The KV cache is allocated per generate call inside
MLX, and it is priced per session already: `Router.footprintBytes` charges a
model that an earlier resolve made resident one session KV cache
(`residentKeys.contains(key) ? sessionKV : raw`), and `JointFit.sessionBytes`
charges a slot that reuses an earlier slot of the same resolve.

Result: a profile at 8k tokens and a profile at 32k tokens that name one
model produce two pool entries, two `MLXLanguageModel` values, and two full
weight charges against the budget. The MLX cache (§1.4) collapses them to one
container underneath, so the budget over-reserves the weights one time, and
the release of either entry evicts the container under the other.
`sameRepoDifferentContextDoesNotShare` pins this behaviour on purpose. The
plan reverses it (§2.3).

### 1.4 The MLX layer has a process-global cache, keyed by repo id only

`MLXLanguageModel` (fork `swissarmyhammer/mlx-swift-lm`, branch `stable`,
`Libraries/MLXFoundationModels/MLXLanguageModel.swift`) holds a
`private static let cache = ModelCache()`. `loadContainer()` returns the
cached `ModelContainer` for `modelID`, and coalesces concurrent loads of one
id onto one task. `evict()` removes one id from that cache.

`modelID` is `configuration.name`, which for a Hub model is the repo id
alone. The revision is dropped. Two `ModelRef`s that differ only in revision
(`org/repo@rev1`, `org/repo@rev2`) get one container from that cache: the
second caller gets the first revision's weights. The router keys its pool by
revision, so it believes it holds two models. This is a latent defect in the
fork, independent of this plan, and §2.6 tracks it.

## 2. Design

### 2.1 `ModelPool`: the residency pool as a process-wide actor

Move the pool out of `Router` into a new actor,
`Sources/FoundationModelsRouter/Resolution/ModelPool.swift`:

```swift
/// The resident-model pool. One instance serves every router in a process,
/// so a model that two routers name is loaded one time and priced one time.
public actor ModelPool {
    /// The pool every router uses when none is given.
    public static let shared = ModelPool()

    /// Makes an empty pool. Tests make one per router for isolation.
    public init()

    /// How many models are resident in this pool. For a host that wants to
    /// know what a process holds at shutdown.
    public var residentModelCount: Int { get }

    // package: what Router needs
    /// Runs `body` under the resolve-wide lock. The lock is a nonisolated
    /// `AsyncSemaphore`, so no caller can forget it and no `defer` needs an
    /// `await`.
    func withResolveLock<T>(_ body: () async throws -> T) async rethrows -> T
    var residentFootprintBytes: Int64       // sum of every entry's footprint
    var residentKeys: Set<ResidencyKey>
    /// Bumps a resident entry or loads a new one. Returns the entry, so the
    /// resolve holds the container and the gates it needs and never reads
    /// the pool a second time.
    func acquire(key:load:wrap:evict:...) async throws -> PoolEntry
    func grant(token: ULID, holds: [ResidencyHold])
    func release(token: ULID) async
}
```

`ResidencyKey`, `PoolEntry`, `PooledContainer`, and `ResidencyHold` move
with it and become `package`. `PoolEntry` gains an `evict` closure captured
from the loader that loaded it, so an eviction runs through the loader that
made the container, whichever router releases last.

Two shape rules, because the pool is an actor:

- The lock is a closure-taking method over a nonisolated semaphore. An
  actor does not make check-then-insert atomic across an `await`, and
  `acquire` awaits a download. The lock is what stops two routers from
  loading one key two times. Today's `defer { poolLock.signal() }` sites in
  `Router.swift` cannot await an isolated `unlock()`, so the closure form
  replaces them.
- `acquire` returns the `PoolEntry`. Today `buildProfile`, `makeRoutedModel`,
  `makeRoutedLLM`, and `makeRoutedEmbedder` read `pool[key]` synchronously
  and trap when the key is missing. With the entry in hand, those helpers
  stay synchronous and the two trap paths go away.

`Router.init` gains `pool: ModelPool = .shared`. Every existing call site
compiles unchanged and shares one pool. `Router` keeps its own identity,
recorder, tracer, metadata reader, and loader. `resolve` and `release` become
clients of the pool: the pool lock replaces `poolLock`, the resident
footprint and keys come from the pool, and `acquireModel` and `releaseKey`
forward to it. `LanguageModelProfile.release()` keeps calling
`router.release(token:)`, which forwards to the pool.

The lock stays resolve-wide, so two routers' resolves serialize
process-wide, as two resolves on one router do today.

### 2.2 The first loader wins a key

The router that first loads a key makes its container with its own loader.
A second router that names the same key gets that container, whatever its
own loader would have made. This is the same rule the MLX cache applies
("first caller wins; later callers reuse the cached container regardless of
which loader they brought along").

One consequence needs a decision: `LiveModelLoader(samplingMode:)` stores the
decoding strategy on the container (`MLXFoundationModelsContainer.samplingMode`).
Two routers with different sampling modes over one key would share the first
router's mode. The sampling mode is a decode option, not a property of the
weights, so §2.5 moves it off the container.

### 2.3 Drop the context from the generation key

`ResidencyKey.Role` becomes `.llm` and `.embedding`, with no context. The
per-session KV cache is already charged per acquisition (`chargedBytes` on
`ResidencyHold`; `sessionBytes` in the joint fit at that resolve's own
context), so the accounting is unchanged: the first hold charges weights plus
its KV cache, and every later hold charges its own KV cache at its own
context. `ModelLoader.loadLLM(context:)` keeps its parameter for source
compatibility, and its doc comment says the value is advisory.

### 2.4 Tests must not share the default pool

The unit target builds a `Router` at 64 sites in 41 files. Most suites have
their own private `makeRouter`. Swift Testing runs suites in parallel, and
stub loaders vend stub containers for refs such as `org/std-shared`. If a
test router used `ModelPool.shared`, one suite's resident stub would satisfy
another suite's key, and the budget arithmetic in `PooledResidencyTests` and
`ResolveTests` would depend on scheduling. So every router-building site in
`Tests/FoundationModelsRouterTests` names a pool: each private `makeRouter`
gains `pool: ModelPool = ModelPool()`, and a direct `Router(...)` call passes
`pool: ModelPool()`. A test that wants two routers over one pool passes the
same pool to both. The extraction task's acceptance criterion is that no
file under the unit target builds a `Router` without a `pool:` argument.

### 2.5 Sampling mode belongs to the router, not the container

This lands in two steps.

**Step A, the seam.** `Router.init` gains
`samplingMode: GenerationOptions.SamplingMode? = nil`. `RoutedModel` carries
it. All four `LoadedLLMContainer.makeSession` signatures gain a
`samplingMode:` parameter, with default extensions that forward to the old
signatures so stub containers compile unchanged. The one call site that
needs the parameter and has no other way to get the mode is the compaction
summarizer: `RoutedSessionActorCompaction.swift` line 145 calls
`profile.flash.container.makeSession(instructions: nil)`, the no-tools
signature. A fork (`makeFork(tools:)`) and a transcript replace
(`replacingTranscript(_:)`) inherit the mode from the backend they copy, so
they need no change, and a test on them cannot fail. The test for step A
pins the summarizer backend.

**Step B, the removal.** `MLXFoundationModelsContainer` drops its stored
`samplingMode`, and `LiveModelLoader(samplingMode:)` goes. The mode reaches
`LiveModelLoader` today through `RealModelContainer.load(ref:context:samplingMode:chatTemplateDate:)`
(`Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift`)
and `CompactionEvalRealModelContainer.load(...)`
(`IntegrationTests/.../Support/`). Neither builds a `Router`; both return a
bare container that about fifteen gated suites call `makeSession` on
directly, and the argmax pin is what makes those suites repeatable. Each of
those sites passes the mode into `makeSession(...samplingMode:)` instead.
`Examples/CompactionDemo/main.swift` passes it to `Router`;
`Examples/MultiModelGeneration` names no sampling mode. The DocC link
``MLXFoundationModelsContainer/samplingMode`` in `RealToolTurnComparisonTests`
and the rationale comment in `GatedEvalSerialGate.swift` ("one container
cannot carry two strategies") are updated with it.

### 2.6 Fork: key the MLX cache by revision

In `swissarmyhammer/mlx-swift-lm`, give `MLXLanguageModel.modelID` the
revision: `"\(id)@\(revision)"` for `.id(id, revision:)` when the revision is
not `"main"`, and `configuration.name` unchanged for `.directory(url)`. Keep
`configuration.name` as it is so download paths and progress reporting do
not change (progress already passes `configuration.name`). The two
`weightsLocation(modelID)` call sites are in
`MLXLanguageModel+Availability.swift` (lines 143 and 182 at revision
`41e9f41c`); both change to `configuration.name`. Add a unit test that two
configurations for one id at two revisions get two `modelID` values and two
loads; it must sit under the `@Suite(.serialized)` parent that
`ModelCacheEvictionTests` documents, because the cache is one process-global
`static let`.

The work needs its own clone of the fork and a push to `stable`. The checkout
under `IntegrationTests/.build/checkouts/mlx-swift-lm` is a SwiftPM artifact,
detached at the pinned revision, and `swift package resolve` discards edits
there. Then bump `Package.resolved` and `IntegrationTests/Package.resolved`
here.

### 2.7 Two rules the shared entry sets for every router

- **Fork ceiling: the first router wins.** `ResidentModelGates` is minted at
  first load from the loading router's `maxConcurrentForks`. A second router
  over the same key gets that ceiling. The alternative, a per-handle
  admission gate beside the shared generation gate, is more code for a
  setting almost every application leaves at the default. The rule is stated
  on `ResidentModelGates` and pinned by a cross-router test.
- **Lifetime: a container is freed only by `release`.** Today a dropped
  `Router` frees its pool through ARC. With `ModelPool.shared`, a global
  holds the containers, so a leaked profile whose `deinit` task never runs
  keeps its models resident and charged. `ModelPool.residentModelCount` lets
  a host see this. No `evictAll()`: an eviction while a profile still holds
  a reference would corrupt the accounting the plan sets out to fix.
- **Budget: the pool holds the residents, each router keeps its budget.**
  `hostBudget()` stays per router (its own probe and headroom). Two routers
  with different headroom see two different effective budgets over one pool.
  A test that pins a budget across two routers gives both the same probe and
  the same headroom.

## 3. Testing

- **Cross-router unit tests**, in
  `Tests/FoundationModelsRouterTests/CrossRouterResidencyTests.swift`, all
  over stubs: two routers on one pool load a shared ref one time; a release
  from one router keeps the model for the other; a release from the last
  router evicts through the loader that loaded it; a second router's resolve
  prices the first router's residents, so a disjoint union that exceeds the
  budget fails with `ResolutionFailure`; two routers on two pools do not
  share.
- **Context key test**: `sameRepoDifferentContextDoesNotShare` becomes
  `sameRepoDifferentContextSharesOneContainer`, and a budget pin proves the
  second profile charges one KV cache at its own context and no weights.
- **Sampling-mode tests**: a stub container records the sampling mode each
  `makeSession` receives; two routers with different modes over one pool
  each see their own mode; the compaction summarizer backend receives the
  router's mode.
- **Fork-ceiling test**: two routers with different `maxConcurrentForks`
  over one pool; the second router's forks admit at the first router's
  ceiling.
- **Gated real-model test**, in `IntegrationTests/`: two `Router`s over
  `LiveModelLoader` resolve one profile. With `InMemoryTracing` bound, the
  second resolve opens zero `load` spans, and a session from each router
  answers a prompt.
- **Fork test** per §2.6.

## 4. Build order

1. `ModelPool` extraction with `Router(pool:)`; every unit-test router
   names a pool.
2. Cross-router unit tests, including the fork-ceiling pin.
3. Drop the context from the key (after 2: both edit
   `PooledResidencyTests.swift`).
4. Sampling mode, step A: the seam (after 2: its test lands in the
   cross-router suite).
5. Sampling mode, step B: the removal.
6. Gated two-router test (after 5: the gated harness changes with it).
7. Fork revision key and `Package.resolved` bump (independent).
8. README and doc comments: residency is process-wide.

## 5. Decisions

- **One pool per process, injectable.** `ModelPool.shared` is the default so
  an application gets process-wide pooling with no configuration. The
  parameter exists for tests and for an application that wants two isolated
  budgets on purpose.
- **The pool does not depend on the MLX cache.** The MLX cache stays as a
  second line of defence, but the router's own pool is the authority on
  residency and on the budget. The router evicts only at zero references
  across the process, so the MLX eviction becomes correct as a side effect.
- **First loader wins.** The alternative, a loader identity in the key, would
  load one model two times to serve two routers, which is the waste this plan
  removes.
- **No context in the key.** The loader never read it; the KV cache is
  priced per session already.
- **Sampling mode moves to the router.** It is a decode option. Storing it on
  a shared container gives the wrong mode to the second router.
- **Fork ceiling: first router wins** (§2.7). Stated, tested, not
  engineered around.
- **A container is freed only by `release`** (§2.7). The pool is process
  lifetime; a host can read `residentModelCount`.
- **Each router keeps its own budget over the shared residents** (§2.7).
