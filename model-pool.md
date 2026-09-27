# Model pool — one resident copy of each model for the whole process

The process has one model pool. When two users in one process name the same
model, the pool loads that model one time. A user is a `Router`, the tool
registry, the multitool, or other code that takes a hold. When two slots of
one router name the same model, the pool loads that model one time. The
memory budget counts the union of all resident models in the process, not the
resident models of one router.

The pool is `ModelPool` in the core `FoundationModelsExtras` target (Extras
revision `f4bd503`, source
`Sources/FoundationModelsExtras/ModelPool/ModelPool.swift`). The router is one
user of that pool. It does not have its own pool.

Section 1 shows the state of the code before the first pool plan. Section 2
is the current design. Section 6 is the history of the designs that the
current design replaced.

## 1. What the code did before the pool plan

This section is history. It shows the state of the code on `main` at commit
`37c7942` (2026-09-05), before the first pool plan.

### 1.1 One router: pooling was done

`Router` held a private `pool: [ResidencyKey: PoolEntry]`, keyed by
`(ModelRef, Role)`. Each entry counted the slot acquisitions that held it. A
resolve added a count to a resident entry and loaded only a new key. A release
removed a count and evicted at zero. One lock of the router serialized both.

`Tests/FoundationModelsRouterTests/PooledResidencyTests.swift` proved that two
profiles that name one model load it one time, and that a model stays
resident while a profile holds it.

### 1.2 Two routers: no pooling at the router layer

Each `Router` had its own pool and its own lock. Two routers did not see each
other. The consequences:

1. **The budget was incorrect in both directions.** Each router priced only
   its own resident models against the full machine budget. Two routers with
   disjoint models could together use too much memory. Two routers with the
   same model both charged its weights, and could refuse a profile that fits.
2. **A release in one router evicted the model under the other.** The live
   loader's eviction removes the container from the MLX layer's
   process-global cache (§1.4). The next call of the other router loaded the
   weights from disk again.
3. **Each router loaded its own copy of an embedder.** The embedder factory
   has no cache.
4. **Two generation gates for one container.** Each router made its own gate
   for a model, so two routers over one MLX container serialized generation
   only inside each router.

### 1.3 The context in the residency key did not match the loader

The old key of a generation model included its working context. The live
loader never reads the context: MLX allocates the KV cache at each generate
call, and the router prices the KV cache for each session. Thus a profile at
8k tokens and a profile at 32k tokens that name one model made two pool
entries and two weight charges. §2.3 removed the context from the key.

### 1.4 The MLX layer has a process-global cache, keyed by repo id only

`MLXLanguageModel` (fork `swissarmyhammer/mlx-swift-lm`, branch `stable`,
`Libraries/MLXFoundationModels/MLXLanguageModel.swift`) holds a
`private static let cache = ModelCache()`. `loadContainer()` returns the
cached `ModelContainer` for `modelID`, and joins concurrent loads of one id
into one task. `evict()` removes one id from that cache.

`modelID` is `configuration.name`, which for a Hub model is the repo id
alone. The revision is dropped. Two `ModelRef`s that differ only in revision
(`org/repo@rev1`, `org/repo@rev2`) get one container from that cache: the
second caller gets the weights of the first revision. The pool keys a model
by revision, so it thinks that it holds two models. This is a latent defect
in the fork, and §2.6 tracks it.

## 2. Design

### 2.1 `ModelPool`: the pool of the process, in `FoundationModelsExtras`

`ModelPool` is a `final class` in `FoundationModelsExtras`, not an actor. All
of its state is in one `Mutex`. The router exports the name with
`public typealias ModelPool = FoundationModelsExtras.ModelPool`
(`Sources/FoundationModelsRouter/Resolution/PoolPrimitives.swift`), so a
router user writes `Router(pool: ModelPool())` and `ModelPool.shared` with only
`import FoundationModelsRouter`. A file that imports both modules sees one
type, because the alias and the class are one declaration.

The public surface:

```swift
public final class ModelPool: Sendable {
    /// The pool of the process.
    public static let shared: ModelPool
    public init()

    /// Gives a hold of the model of `key`. A resident key adds a hold at once.
    /// A new key loads in one admission job.
    public func acquire(
        _ key: ModelPoolKey, footprintBytes: Int64, sessionBytes: Int64,
        loader: any PooledModelLoader
    ) async throws -> ModelHold

    /// Runs `job` as one job in the FIFO admission queue.
    public func admit<T: Sendable>(
        _ job: @escaping @Sendable (ModelPoolAdmission) async throws -> T
    ) async throws -> T

    /// Synchronous reads.
    public var footprint: ModelPoolFootprint { get }  // resident, loadingBytes, totalBytes
    public var residentModelCount: Int { get }
    public func isResident(_ key: ModelPoolKey) -> Bool

    /// The current footprint first, then each change.
    public var footprints: AsyncStream<ModelPoolFootprint> { get }
}

public struct ModelPoolAdmission: Sendable {
    public var footprint: ModelPoolFootprint { get }
    /// Acquires at once, inside the running admission job.
    public func acquire(
        _ key: ModelPoolKey, footprintBytes: Int64, sessionBytes: Int64,
        loader: any PooledModelLoader
    ) async throws -> ModelHold
}

public final class ModelHold: Sendable {
    public let key: ModelPoolKey
    public let container: any Sendable
    public let queue: GenerationQueue  // the one work queue of the model
    // deinit releases the hold.
}
```

The key is `ModelPoolKey` (a `ModelRef` and a `ModelRole`, `.llm` or
`.embedding`). The loader is `PooledModelLoader`: it loads a model by its key
and evicts a container that it loaded. `LiveModelLoader` conforms to it, so
an application can give a live loader to the pool without a `Router`. The
router exports `ModelPoolKey`, `ModelRole`, `PooledModelLoader` and
`PooledEmbedding` under the same names.

The pool keeps, for each resident key, the container, the loader that loaded
it, one `GenerationQueue`, the bytes (the weights and the session of each
hold), and the hold count. Each eviction runs through the loader that loaded
the container, whichever user releases last.

`Router.init` takes `pool: ModelPool = .shared`. `Router` keeps its own
identity, recorder, tracer, metadata reader, loader, sampling mode, and
budget probe.

### 2.2 The first loader wins a key

The first user that loads a key makes its container with its own loader. A
later user that names the same key gets that container, whatever its own
loader would make. The MLX cache applies the same rule. Thus a user must use
a container through a protocol, never through a cast to the container type
of one loader. The router uses an embedding container through
`PooledEmbedding` only, and a generation container through
`ModelHold.generationContainer()`.

The sampling mode is a decode option, not a property of the weights. §2.5
moves it off the container, so two routers with two sampling modes can share
one container.

### 2.3 No context in the generation key

A generation key is the chosen reference and the role `.llm`, with no
context. The per-session KV cache is charged for each hold (`sessionBytes`,
from the joint fit at the context of that resolve). The first hold charges
the weights plus its KV cache. Each later hold charges its own KV cache at
its own context. `ModelLoader.loadLLM(context:)` keeps its parameter for
source compatibility, and its doc comment says that the value is advisory.

### 2.4 Tests must not share the default pool

Swift Testing runs suites in parallel, and stub loaders vend stub containers
for references such as `org/std-shared`. If a test router used
`ModelPool.shared`, the resident stub of one suite could satisfy a key of
another suite, and the budget arithmetic would depend on the schedule. Thus
each router in `Tests/FoundationModelsRouterTests` names a pool: each private
`makeRouter` takes `pool: ModelPool = ModelPool()`, and a direct `Router(...)`
call passes `pool: ModelPool()`. A test that wants two routers over one pool
gives the same pool to both.

### 2.5 Sampling mode belongs to the router, not the container

This landed in two steps.

**Step A, the seam.** `Router.init` takes
`samplingMode: GenerationOptions.SamplingMode? = nil`. `RoutedModel` carries
it. All four `LoadedLLMContainer.makeSession` signatures take a
`samplingMode:` parameter, with default extensions that forward to the old
signatures, so stub containers compile unchanged. The compaction summarizer
(`RoutedSessionActorCompaction.swift`) calls
`profile.flash.container.makeSession(instructions: nil)` and needs the
parameter. A fork (`makeFork(tools:)`) and a transcript replace
(`replacingTranscript(_:)`) copy the mode from their backend. The test for
step A pins the summarizer backend.

**Step B, the removal.** `MLXFoundationModelsContainer` has no stored
`samplingMode`, and `LiveModelLoader(samplingMode:)` is gone. The real-model
helpers `RealModelContainer.load(...)`
(`Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift`) and
`CompactionEvalRealModelContainer.load(...)` (`IntegrationTests/.../Support/`)
return a bare container. Each gated suite that calls `makeSession` on it
passes the mode into `makeSession(...samplingMode:)`. The argmax pin is what
makes those suites repeatable. `Examples/CompactionDemo/main.swift` passes the
mode to `Router`.

### 2.6 Fork: key the MLX cache by revision

In `swissarmyhammer/mlx-swift-lm`, give `MLXLanguageModel.modelID` the
revision: `"\(id)@\(revision)"` for `.id(id, revision:)` when the revision is
not `"main"`, and `configuration.name` unchanged for `.directory(url)`. Keep
`configuration.name` as it is, so download paths and progress reporting do
not change. The two `weightsLocation(modelID)` call sites are in
`MLXLanguageModel+Availability.swift`; both change to `configuration.name`.
Add a unit test that two configurations for one id at two revisions get two
`modelID` values and two loads. The test must be under the
`@Suite(.serialized)` parent that `ModelCacheEvictionTests` documents,
because the cache is one process-global `static let`.

The work needs its own clone of the fork and a push to `stable`. The checkout
under `IntegrationTests/.build/checkouts/mlx-swift-lm` is a SwiftPM artifact,
and `swift package resolve` discards edits there. `.gitignore` ignores both
`Package.resolved` files, and both manifests take the fork by
`branch: "stable"`. A tracked guarantee needs a `revision:` pin in both
manifests or a tracked `Package.resolved`.

### 2.7 Rules the shared pool sets for each user

- **One work queue for each model.** The pool makes one `GenerationQueue`
  when it loads a key. Each hold of that key, of each user, gives the same
  queue (`ModelHold.queue`). Forks are not counted: any number of forks over
  one container can exist at one time.
- **Lifetime: a model stays resident while a hold exists.** There is no
  release call and no `evictAll()`. Each `RoutedModel` handle keeps the three
  `ModelHold`s of its resolve (`residencyHolds`), so one handle alone (for
  example in a tool) keeps the whole trio resident. A leaked handle keeps its
  models resident and charged. `ModelPool.residentModelCount` lets a host see
  this. §2.9 gives the eviction rules.
- **Budget: the pool holds the resident models, each router keeps its
  budget.** `hostBudget()` is a probe of each router. A resolve subtracts
  `footprint.totalBytes` of the pool from that budget. Two routers with two
  probes see two effective budgets over one pool. A test that pins a budget
  across two routers gives both the same probe.
- **Standard is not flash.** A profile never uses one model for both
  generation slots. A synchronous tool call can run a `flash` call inside an
  open submission on `standard`, and each model has one FIFO work queue, so
  one model in both slots would wait on itself. `Router.resolve` skips the
  model that `standard` chose in the `flash` list, and throws before it loads
  when no other `flash` candidate exists.

### 2.8 The admission job of a resolve

The pool has one FIFO admission queue. Each load of a new key, by any user,
is one admission job. Each eviction is one admission job. `admit` runs a job
of the caller in the same queue.

`Router.resolve` does its work in this order:

1. Outside of the queue, the router fetches the metadata of each candidate
   (the sizing).
2. The router runs one `pool.admit` job. In that job it reads
   `admission.footprint`, runs `JointFit` against the budget less
   `footprint.totalBytes`, and calls `admission.acquire` for each slot. It
   also preloads each model that it loaded.

Because the measurement and the acquires are in one job, no load by another
user and no eviction can occur between them. Thus the router needs no lock of
its own and no step that processes queued releases before it measures.

Inside a job, a caller must acquire through the `ModelPoolAdmission`.
`ModelPool.acquire` of a new key waits for the end of the running job.

### 2.9 Holds and eviction

A `ModelHold` releases in its `deinit`, synchronously: the hold count and the
session bytes of the hold go at once, and the `footprints` stream gets the
change. After the last hold of a key, the pool submits an eviction job from a
detached task. The eviction job examines the hold count again. When the count
is still zero, the job removes the entry, and then calls `evict` on the loader
that loaded the container. When a new hold came first, the job does nothing.

The eviction thus comes after the drop of the last reference, not at the
drop. This is a difference from the router pool that this design replaced
(§6). That pool gave a guarantee that the next resolve saw the freed weights.
Now a resolve that starts immediately after the drop of the last reference can
run before the eviction job. Then it sees the model as still resident (the
weights only, with no session bytes), and a new hold of the same key revives
it with no new load. A caller that needs the freed bytes must wait for the
eviction. For example, it reads `footprints` until the key is not resident,
and then runs `try await pool.admit { _ in }` as a barrier: the barrier job
starts only after the eviction job ends.

### 2.10 Prompt-cache resize points

The prompt cache of the MLX fork is one store for the process. The router
sends a budget for it through its own loader
(`PromptCacheBudget.resize`, `Sources/FoundationModelsRouter/Sizing/PromptCacheBudget.swift`).
The budget is the working set less the resident footprint of the pool, the
bytes of a load that runs now, and the bytes that the next acquire adds.

This design keeps these resize points, all inside the admission job of a
resolve:

- Before each acquire, the router resizes for the bytes that the acquire
  adds: the whole footprint of a new model, or the session bytes of a new
  hold on a resident model.
- After a failed acquire, the router resizes back to the resident footprint.

These changes do not resize the prompt cache yet:

- A load by a user that is not the router (for example the registry or the
  multitool).
- A release of a hold.
- An eviction.

Kanban task `01M3FNK00PYXP7E102NWNHMD56` (^wnhmd56) adds an observer of the
`footprints` stream that resizes for these changes.

## 3. Testing

- **Cross-router unit tests**, in
  `Tests/FoundationModelsRouterTests/CrossRouterResidencyTests.swift`, all
  over stubs: two routers on one pool load a shared reference one time; a
  release from one router keeps the model for the other; a release from the
  last router evicts through the loader that loaded it; the resolve of a
  second router prices the resident models of the first router, so a disjoint
  union that is larger than the budget fails with `ResolutionFailure`; two
  routers on two pools do not share.
- **Extras pool tests**: `ExtrasPoolResolveTests` pins that two routers on
  one pool load each model one time, that a router and a direct acquire of
  one key share one load, and that a direct acquire of a new key during a
  resolve loads only after the admission job of the router ends.
  `ModelPoolNameTests` pins that the router name `ModelPool` and the Extras
  class are one type.
- **Context key test**: `sameRepoDifferentContextSharesOneContainer`, and a
  budget pin proves that the second profile charges one KV cache at its own
  context and no weights.
- **Sampling-mode tests**: a stub container records the sampling mode that
  each `makeSession` receives; two routers with two modes over one pool each
  see their own mode; the compaction summarizer backend receives the mode of
  the router.
- **Uncounted-forks test**: eight forks over one model all exist at one time.
  See `ForkConcurrencyTests`.
- **Gated real-model test**, in
  `IntegrationTests/.../CrossRouterPoolIntegrationTests.swift`: two `Router`s
  over `LiveModelLoader` resolve one profile. With `InMemoryTracing` bound,
  the second resolve opens zero `load` spans, and a session from each router
  answers a prompt. After the drop of both profiles, the test waits on
  `footprints` and an admission barrier (§2.9), and then the pool has no
  resident model.
- **Fork test** per §2.6.

## 4. Build order

This section is history: the order of the first pool plan.

1. Pool extraction with `Router(pool:)`; each unit-test router names a pool.
2. Cross-router unit tests.
3. Remove the context from the key.
4. Sampling mode, step A: the seam.
5. Sampling mode, step B: the removal.
6. Gated two-router test.
7. Fork revision key and `Package.resolved` update.
8. README and doc comments: residency is process-wide.

After these steps, the router pool moved to `FoundationModelsExtras` (§6).

## 5. Decisions

- **One pool per process, injectable.** `ModelPool.shared` is the default, so
  an application gets process-wide pooling with no configuration. The
  `Router(pool:)` parameter exists for tests and for an application that
  wants two isolated budgets on purpose.
- **One pool for all users.** The pool is in the core `FoundationModelsExtras`
  target, so the router, the registry and the multitool share one copy of
  each model and one footprint.
- **The pool does not depend on the MLX cache.** The MLX cache stays as a
  second line of defence, but the pool is the authority on residency and on
  the footprint. The pool evicts only when no hold remains in the process, so
  the MLX eviction is correct as a side effect.
- **First loader wins.** A loader identity in the key would load one model
  two times to serve two users, which is the waste that the pool removes.
- **No context in the key.** The loader never read it; the KV cache is
  priced for each session.
- **Sampling mode belongs to the router.** It is a decode option. A mode on a
  shared container gives the incorrect mode to the second router.
- **One work queue for each model** (§2.7). Forks are not counted.
- **A model stays resident while a hold exists** (§2.7, §2.9). A host can
  read `residentModelCount`.
- **Each router keeps its own budget over the shared resident models**
  (§2.7).
- **One admission queue, no lock** (§2.8). A resolve measures and acquires in
  one admission job.

## 6. History

These designs came before the current design. The current design replaced
them. The code does not contain them now.

- **The router pool actor.** The first pool plan moved the pool out of
  `Router` into a router actor `ModelPool`
  (`Sources/FoundationModelsRouter/Resolution/ModelPool.swift`) with
  `pool: [ResidencyKey: PoolEntry]`, `PooledContainer`, a resolve-wide lock
  (`withResolveLock`, over a nonisolated `AsyncSemaphore`),
  `residentFootprintBytes`, `residentKeys`, and
  `acquire(key:load:wrap:evict:...)`. Each loaded entry had
  `ResidentModelGates`.
- **ARC residency with tokens.** A later merge removed `release(token:)` and
  `LanguageModelProfile.release()`. A resolve made one `ResidencyHold` (a
  token) and gave it to the three handles (`LanguageModelProfile.residencyToken`,
  `grant(token:holds:)`). The per-slot bookkeeping was `SlotCharge`. When the
  last `ResidencyHold` was deallocated, its `deinit` queued the token on the
  pool (`enqueuePendingRelease(_:)`). Each resolve processed that queue
  (`drainPendingReleases()`) before it measured the budget, under
  `withResolveLockUnlessCancelled`, so a cancelled caller left the lock queue.
  That design gave the guarantee that the next resolve saw the freed weights.
- **The move to `FoundationModelsExtras`.** The current design deleted the
  router pool actor, `ResidencyHold` and `SlotCharge`. `ModelPool` is now the
  Extras class (§2.1), each handle keeps `ModelHold`s (§2.7), a resolve is one
  admission job (§2.8), and eviction comes after the last hold (§2.9).
