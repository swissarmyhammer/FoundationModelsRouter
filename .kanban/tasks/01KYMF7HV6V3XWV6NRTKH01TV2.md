---
comments:
- actor: claude-code
  id: 01kyn8zn6qde34ajz8tmgr257z
  text: |-
    Research complete. Read LanguageModelProfile.swift, Router.swift (full), ModelLoader.swift, ModelRef.swift, ModelSlot.swift, JointFit.swift, SlotResolution.swift, ProfileDefinition.swift, HostProfile.swift, Footprint.swift, and the existing test suites (ProfileLifecycleTests, ResolveTests, ExamplesTests, ToolIntegrationTests).

    Key findings:
    - Router is an `actor` already owning hostBudget(), sizeCandidates(), runJointFit(), download/finalize, and profile assembly. `residencyState` is currently `idle | resolving | resident(ULID)` — exactly one profile at a time, enforced by throwing `RouterError.profileAlreadyResident` on a second resolve while one is resident.
    - `slotMembership(profile:)` is NOT actual container-level dedup today — it only widens footprint *sizing* conservatively (max across roles) when one ModelRef is a candidate for two slots in the same profile. Standard/flash containers are always downloaded+loaded independently today even when they resolve to the identical ModelRef — i.e. intra-profile container sharing doesn't exist yet either. The task's framing of slotMembership as "existing precedent" is conceptual (accounting), not literal container reuse.
    - `generationGate`/`forkAdmissionGate` already live on `RoutedModel` (per loaded container), so sharing a container automatically shares serialization — nothing to change there.
    - `Footprint.embedder(weightBytes:)` has zero KV term, so embedding footprint is context-independent; generation footprint depends on `context` (KV cache).
    - 4 existing tests hard-code the single-residency behavior and must change since it's exactly what this task removes: `ProfileLifecycleTests.oneActiveProfileEnforced`, `ProfileLifecycleTests.staleReleaseDoesNotClobberResident` (its tail assertion), `ExamplesTests.residencyOneActiveProfileAndRelease`, `ToolIntegrationTests.constructingToolsDoesNotChangeResidency` (its tail assertion). All currently assert `RouterError` is thrown on a second resolve while one profile is resident — under pooled residency that resolve must now succeed (dedup instead of reject).

    Design decision: **One Router, several resident profiles** (not several Routers sharing a pool) — Router already owns the loader/probe/budget machinery, so this avoids introducing a third participant to memory decisions. Implementing:
    - `ResidencyKey { ref: ModelRef, role: .llm(context: Int) | .embedding }` — the exact artifact identity (ref+revision already in ModelRef; role+context is the load-time parameter that changes resident bytes; embedding has no context axis since its footprint is weights-only).
    - Router holds `pool: [ResidencyKey: PoolEntry(refcount, footprintBytes, container)]` and `residentProfiles: [ULID: [ResidencyKey]]` (replacing the single `residencyState` enum).
    - Whole `resolve()` pipeline serialized via one `AsyncSemaphore(value: 1)` (single authority over the budget decision) — this is a deliberate simplification: resolutions are single-flight even though resident profiles run fully concurrently once resolved (generation is unaffected, only the resolve-time decision is serialized). Matches the correctness requirement without a fine-grained reservation protocol.
    - Effective budget per resolve = machine budget − Σ(footprintBytes of all currently-pooled keys). The footprint closure fed to `JointFit.resolve` returns 0 marginal cost for a candidate whose (ref, role, context) key is already pool-resident, so an already-loaded model is "free" to reuse but a genuinely new one is charged its real cost against what's left — this makes the existing `ResolutionFailure` (JointFit's own failure path) naturally serve the "nothing fits, nothing evictable, fail cleanly" acceptance criterion with zero new error-handling code.
    - Eviction policy: refcount-based, immediate eviction at zero. No lingering/LRU cache — not required by any acceptance test and adds complexity the task doesn't ask for.
    - The pool mechanism is applied uniformly to all 3 slot acquisitions (standard/flash/embedding) per resolve, so as a side effect this also fixes the latent intra-profile gap (standard==flash ModelRef+context now shares one container) — same mechanism, no extra code path.

    Proceeding with TDD: writing failing tests first for each acceptance criterion, updating the 4 existing tests whose assertions are the exact old behavior being replaced.
  timestamp: 2026-07-28T21:09:40.695060+00:00
- actor: claude-code
  id: 01kyna3q8p2wg707dcnxq9fv43
  text: |-
    Implementation complete, TDD followed throughout.

    Files changed:
    - Sources/FoundationModelsRouter/Router.swift — full rewrite of the residency model. Replaced the single `residencyState` enum (idle/resolving/resident(token)) with a refcounted pool (`pool: [ResidencyKey: PoolEntry]`) and per-profile key tracking (`residentProfiles: [ULID: [ResidencyKey]]`). Added `ResidencyKey` (ModelRef + role, where role is `.llm(context:)` or `.embedding` — the exact load-time identity that determines resident bytes) and `PoolEntry` (refcount, footprintBytes, container, shared generationGate/forkAdmissionGate) as file-scope private types. `resolve()` now: serializes end-to-end via a private `AsyncSemaphore(value:1)` (`resolutionLock`) — single authority over the budget decision; computes an effective budget = machine budget − Σ(already-pooled footprints); feeds JointFit a footprint closure that prices an already-pool-resident candidate at 0 marginal cost; acquires each of the 3 slots (reuse+refcount++ or download+insert); rolls back everything this attempt acquired on any failure. `release(token:)` replaces `release(token:containers:)` — looks up and removes the profile's own key list, decrementing each, evicting at zero. Removed `RouterError` (its only case, `.profileAlreadyResident`, is no longer thrown by anything).
    - Sources/FoundationModelsRouter/LanguageModelProfile.swift — `RoutedModel.init` gained optional `generationGate`/`forkAdmissionGate` params (default nil → fresh semaphore, preserving old behavior for direct construction); Router now threads a REUSED pool entry's own gates into every handle built over it, so two profiles sharing a model share its generation serialization, not just its container. `release()`/`deinit` updated to the new `release(token:)` signature.
    - Tests/FoundationModelsRouterTests/PooledResidencyTests.swift (new) — 7 tests covering every acceptance criterion and required test case from the task description.
    - ProfileLifecycleTests.swift, ExamplesTests.swift, ToolIntegrationTests.swift — 4 pre-existing tests that hard-coded the OLD one-active-profile-throws behavior rewritten to assert the NEW dedup/pooling behavior (this is exactly the behavior the task replaces, not scope creep).

    Notable debugging detour: while writing PooledResidencyTests, discovered that discarding a resolved `LanguageModelProfile` with `_ = try await router.resolve(...)` lets ARC deallocate it immediately, firing `deinit`'s unstructured `Task { await router.release(...) }` before the next line runs — this raced and silently released residency between two "back-to-back" resolve calls in a test, making a test pass for the wrong reason (looked like dedup working; was actually release-then-reload). Fixed by holding named references to every resolved profile for the test's duration. Documented as a comment in the fixed test. This is a sharp edge worth remembering for anyone else writing tests against this profile-lifetime-tied-residency design.

    Verification: `swift build` exit 0, zero warnings on touched files. `swift test` (full suite, all three non-gated targets): 593/593 + 18/18 + 12/12 passing, zero failures. Adversarial double-check via the `double-check` agent is in flight; will report its verdict and any resulting changes in a follow-up comment.

    Task intentionally left in `doing` per the implement workflow — review is a separate step.
  timestamp: 2026-07-28T21:29:22.454270+00:00
- actor: claude-code
  id: 01kynav85mkd1w6b94vyx55qx6
  text: |-
    First double-check pass returned REVISE with a real finding: a TOCTOU race between `resolve()`'s pool-pricing decision (which prices an already-resident candidate at 0 marginal cost) and an unlocked `release(token:)` that could evict that exact key mid-flight, causing a silent double-load recorded at the stale zero footprint — permanently under-counting that model's real cost in every future budget computation. This is exactly the "single authority over the budget" correctness bar the task calls out.

    Fixed via TDD: wrote `PooledResidencyTests.releaseCannotRaceAnInFlightResolveAndCorruptAccounting`, which forces the race deterministically (a gated loader ref suspends one profile's resolve mid-acquisition while a concurrent release of a shared model's other owner is issued). Confirmed RED against the pre-fix code, reproducibly across 5 runs (the shared model was silently double-loaded). Fix: the `resolutionLock` (renamed `poolLock` to reflect its now-broader scope) is now also acquired by `release(token:)`, not just `resolve()` — since `release()`'s own mutation path (`releaseKey`) never itself re-acquires the lock, no deadlock: `resolve()`'s own rollback path calls `releaseKey` directly while already holding the lock. Confirmed GREEN reproducibly across 8 runs, and the full suite (594/594 + 18/18 + 12/12) stable across 3 consecutive full runs post-fix.

    Second (bounded, final per really-done's "at most once" re-check rule) adversarial double-check is in flight now, focused specifically on verifying the fix closes the race without introducing deadlock/regression. Will report its verdict next.
  timestamp: 2026-07-28T21:42:13.428331+00:00
- actor: claude-code
  id: 01kynb2hq448efd9prqt1ghsqd
  text: |-
    Second (bounded, final) adversarial double-check: PASS. It independently re-derived the race-fix's correctness (traced every `pool`/`residentProfiles` mutation site to confirm all are lock-guarded, confirmed `releaseKey` doesn't re-acquire the lock so no deadlock, traced the acquire-loop's awaits to rule out any new deadlock/starvation from locking `release()`, independently re-derived the regression test's eviction-count arithmetic and confirmed it would genuinely have failed pre-fix, and ran `swift build`/`swift test` itself rather than trusting my report — got the same 594/18/12 green). One cosmetic nit flagged (a stale `resolutionLock` name reference in a doc comment, left over from the `poolLock` rename) — fixed immediately.

    Final verification, fresh: `swift build` exit 0. `swift test`: 594/594 + 18/18 + 12/12 passing, zero failures, zero warnings on touched files.

    Task is done and green. Leaving in `doing` per the implement workflow — `/review` is a separate step.

    Summary of the shape decision and design for anyone picking this up next: chose "one Router, several resident profiles" (not several Routers sharing a pool) since Router already owns the loader/probe/budget machinery — adding a pool as Router-internal state avoids introducing a third participant to memory decisions. Residency is refcounted per `ResidencyKey` (ModelRef + role, where role is `.llm(context:)` or `.embedding`) — the exact load-time identity that determines resident bytes. A single `poolLock` (`AsyncSemaphore(value: 1)`) serializes every mutation to the pool, both `resolve()`'s acquisition path and `release(token:)`'s decrement path — this was tightened mid-task after the first adversarial review caught a real race in the release-side gap. Eviction policy is immediate-at-zero-refcount (no lingering/LRU cache) — sufficient for every acceptance criterion and simpler than the alternative.
  timestamp: 2026-07-28T21:46:12.580436+00:00
- actor: claude-code
  id: 01kynb3hbqm3r01g87s0sjrxwv
  text: 'Implementation landed via implementer subagent (TDD). Chose shape: one Router with several resident profiles (Router already owns loader/probe/budget machinery). New ResidencyKey (ModelRef + role) identifies resident artifacts; refcounted pool[ResidencyKey: PoolEntry] + residentProfiles[ULID: [ResidencyKey]] replaces old single residencyState enum. resolve() prices already-resident candidates at zero marginal cost so the union of resident models is priced against one budget. Adversarial review caught a real TOCTOU race in release() (unlocked decrement could evict a key resolve() had already priced as free, corrupting budget accounting toward OOM) — fixed by serializing all pool mutations through one poolLock semaphore; regression test added and confirmed RED then GREEN across repeated runs. Reused pool entries share generationGate/forkAdmissionGate across profiles so shared-model generation actually serializes. RouterError.profileAlreadyResident removed (nothing throws it now). New PooledResidencyTests.swift (8 tests) covers all acceptance criteria + required test cases + the race regression; 4 pre-existing tests updated from old one-active-profile-throws behavior to new pooled-sharing behavior (that old behavior is exactly what this task replaces). swift build clean, swift test green (594+18+12 = 624 tests, 0 failures). Two double-check rounds: first REVISE (the race bug), fixed, second PASS. Task left in doing for checkpoint + review.'
  timestamp: 2026-07-28T21:46:44.983877+00:00
- actor: claude-code
  id: 01kyndnqw3xxbd8k3wfqvfp8h7
  text: 'Checkpoint committed (f6ea064). Review pass 1 scoped to HEAD~1..HEAD: 15 engine findings, 5 dropped per never-refactor-existing-tests exception (ExamplesTests.swift and ToolIntegrationTests.swift findings targeted lines outside this commit''s touched hunks). 10 kept and appended: LanguageModelProfile.swift register(_:) label, Router.swift releaseKey(_:) label, two repeated "candidate ... was not sized" string literal sites needing a shared constant, makeRoutedLLM/makeRoutedEmbedder near-duplicate builders needing extraction, and 4x repeated hardcoded 1_000 headroom buffer in the new PooledResidencyTests.swift needing a shared constant. Task remains in review; looping back to implement.'
  timestamp: 2026-07-28T22:31:38.627155+00:00
- actor: claude-code
  id: 01kyne4k3g79g31xfk0bzj93nv
  text: |-
    Resolved all 10 review findings from the 2026-07-28 17:12 pass:

    1-2. Argument label renames: `OwningProfileBox.register(_:)` → `register(profile:)` (3 call sites in LanguageModelProfile.init updated); `Router.releaseKey(_:)` → `releaseKey(key:)` (2 call sites updated: resolve()'s rollback loop and release(token:)).

    3-4 (Router.swift:388, 454 — same underlying finding reported at both sites). Extracted the repeated "candidate ... was not sized" diagnostic into a new `private static func unsizedCandidateMessage(for ref: ModelRef) -> String` on Router, called from both `footprintBytes(for:context:metadataByRef:membership:residentKeys:)` and `runJointFit`'s `nativeMaxContext` closure.

    5. Extracted the shared logic between `makeRoutedLLM` and `makeRoutedEmbedder` into a new generic `private func makeRoutedModel<Container: Sendable>(slot:chosen:resolution:key:resolvedProfile:unwrap:) -> RoutedModel<Container>`. It does the pool lookup + RoutedModel construction (footprint, durable recording, gates) that was identical between the two; each caller passes an `unwrap: (PooledContainer) -> Container?` closure to extract its concrete container type from the pool entry's `PooledContainer` enum. `makeRoutedLLM` passes `slot` through and unwraps `.llm`; `makeRoutedEmbedder` hardcodes `slot: .embedding` and unwraps `.embedding`. `maxConcurrentForks` is now passed uniformly by the shared helper — verified safe because `forkAdmissionGate` is always supplied explicitly at both call sites, so `RoutedModel.init`'s `?? AsyncSemaphore(value: maxConcurrentForks)` fallback never triggers.

    6. Extracted the repeated `1_000` headroom-buffer literal in the new PooledResidencyTests.swift into `private static let headroomBufferBytes: Int64 = 1_000`, used at all 8 call sites (the review flagged 4; all 8 occurrences of the same magic number were normalized for consistency).

    Verification: `swift build` exit 0, zero warnings. `swift test`: 594/594 + 18/18 + 12/12 = 624/624 passing, zero failures (matches the pre-fix baseline count, confirming no regressions). LSP diagnostics on the working tree: 0 errors, 0 warnings. Adversarial double-check dispatched to independently verify the diff and re-run build/test.

    All 10 checklist items in the "## Review Findings" section flipped to `- [x]`. Task left in `doing` per the implement workflow — `/review` is the next step.
  timestamp: 2026-07-28T22:39:45.264887+00:00
position_column: doing
position_ordinal: '80'
title: 'Pooled model residency: per-project profiles sharing one budget'
---
## What

**Upstream ask from `FoundationModelsACPAgent`** (its `plan.md` §9.1). Pairs with `ke41yth` (per-session recording root) — both fall out of the same change: that package now resolves **configuration per project root**, so two concurrent ACP sessions in different repos are no longer guaranteed to want the same thing.

Config is layered per session cwd, and a project's `.<name>/config.yaml` may name its own `profile:`. So a repo that pins a particular coding model should get it, while a session in another repo keeps its own. Today that is impossible: a Router has one resident profile, so the consumer degrades to "log a warning and reuse whatever is already loaded." It ships that way as a stopgap and wants it gone.

## The correctness constraint, which is sharper than the optimization

The obvious framing is deduplication — two projects naming the same model should share one loaded copy instead of paying for it twice. True, and worth having. But the load-bearing requirement is stricter:

**The memory budget must have exactly one authority.**

`runJointFit(profile:budget:metadataByRef:)` prices one profile's models against the machine budget (`headroomReserve`, the `probe`). Two Routers each running that against the *whole* budget will each independently conclude they can afford a large model, and together they will exhaust GPU memory. Whatever shape this takes, there must be a single place that decides what is resident and what gets evicted — the joint fit has to price the **union** of resident models, not one profile at a time.

That makes pooling a correctness requirement for multi-profile operation, not a nice-to-have.

## What is already right

- **The generation gate is already on the model, not the Router.** `LanguageModelProfile.generationGate` (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:130`), because "MLX generation runs a single GPU stream and is not safe to interleave." A shared model therefore already carries the gate that stops two borrowers interleaving on it — the piece that would have been hardest to retrofit.
- **Slot-level dedupe is the existing precedent.** `slotMembership(profile:) -> [ModelRef: Set<ModelSlot>]` (`Router.swift:394`) already handles one `ModelRef` serving several slots within a profile. This ask is the same idea one level up: one `ModelRef` serving several *profiles*.
- **`residencyState` is the constraint** (`Router.swift:304`) — a single resident set per Router is what has to generalize.

## Shape — left to Router, with the requirement stated

Either reading satisfies the constraint, and the choice belongs with Router:

- **One Router, several resident profiles.** Sessions name the profile they want; Router dedupes `ModelRef`s across profiles and runs one joint fit over the union. Keeps a single owner of GPU memory, which is what you want when memory is the scarce resource.
- **Several Routers, one shared pool.** The pool owns residency, refcounts by `ModelRef`, and is the single evictor; Routers borrow. Matches the consumer's mental model but adds a third participant to every memory decision.

Requirements either way:

- Residency keyed on whatever actually determines the loaded artifact — `ModelRef` including revision, plus quantization and any load-time parameter that changes the resident bytes. Two profiles naming the same thing share one instance; two naming different revisions do not.
- Reference counted, with a defined eviction policy when the budget is exceeded (and a defined answer for "a model is wanted but nothing can be evicted" — fail the session honestly rather than OOM).
- A model stays loaded while any session references it; unloading is safe only at zero.
- The joint fit prices the union of resident models against one budget.

## Acceptance Criteria

- [ ] Two sessions with different profiles can be live at once, each generating with its own model.
- [ ] Two sessions naming the same model share one loaded instance (verifiable: loaded-model count, not just behavior).
- [ ] Total resident footprint respects the single budget; the second profile cannot push past `headroomReserve`.
- [ ] A model is evicted only when no session references it.
- [ ] When a requested model cannot fit and nothing is evictable, the session fails with a clear error rather than exhausting memory.
- [ ] Single-profile callers are unaffected.

## Tests

- [ ] Two profiles sharing a `ModelRef` → one load, two live sessions, both generate.
- [ ] Two profiles with disjoint refs → both resident, total within budget.
- [ ] Two profiles whose union exceeds the budget → defined, non-OOM outcome.
- [ ] Releasing one session keeps a shared model loaded for the other; releasing both unloads it.
- [ ] Concurrent generation on a shared model serializes on the model's `generationGate`.
- [ ] Same-ref-different-revision does **not** share.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-28 17:12)

Scope: `HEAD~1..HEAD` (checkpoint commit f6ea064).

- [x] `Sources/FoundationModelsRouter/LanguageModelProfile.swift:1` — No magic numbers found in this file. N/A.
- [x] `Sources/FoundationModelsRouter/LanguageModelProfile.swift:51` — First argument label omitted in non-conversion method. The `register` method accepts a `LanguageModelProfile` parameter for side effects, not a value-preserving conversion, so the parameter should have a label. Change `func register(_ profile: LanguageModelProfile)` to `func register(profile: LanguageModelProfile)`, and update the call sites (line 181-183) to use the labeled parameter: `register(profile: self)`.
- [x] `Sources/FoundationModelsRouter/Router.swift:362` — First argument label omitted in non-conversion method. The `releaseKey` method modifies pool state (side effects), not a value-preserving conversion, so the parameter should have a label for clarity. Change `private func releaseKey(_ key: ResidencyKey) async` to `private func releaseKey(key: ResidencyKey) async`, and update call sites (line 333 in `release(token:)`) to `await releaseKey(key: key)`.
- [x] `Sources/FoundationModelsRouter/Router.swift:388` — Repeated string literal that should be a named constant. The error message `"candidate \(ref.stringValue) was not sized"` appears in at least two places (here and in `runJointFit`), making the string maintenance fragile — a typo or change in one location will drift from the other. Define a module-level or type-level constant like `private static let unsizedCandidateErrorMessage = "candidate \(ref.stringValue) was not sized"` and reuse it in both locations.
- [x] `Sources/FoundationModelsRouter/Router.swift:454` — Repeated string literal that should be a named constant. The error message `"candidate \(ref.stringValue) was not sized"` appears in at least two places (here and in `footprintBytes`), making the string maintenance fragile — a change in one location will drift from the other. Define a module-level or type-level constant like `private static let unsizedCandidateErrorMessage = "candidate \(ref.stringValue) was not sized"` and reuse it in both locations.
- [x] `Sources/FoundationModelsRouter/Router.swift:574` — makeRoutedLLM and makeRoutedEmbedder (line ~574 and ~606) are near-verbatim duplicates that differ only by the slot handling, guard pattern, container type, and maxConcurrentForks parameter. The RoutedModel initialization is nearly identical and could drift. Extract a shared builder function that takes the slot, container type, guard/precondition closure, and other parameters. Use this to eliminate duplication in the RoutedModel initialization logic that currently repeats across both functions.
- [x] `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift:243` — Duplicate hardcoded headroom buffer 1_000 bytes in router configuration for releasingOneProfileKeepsSharedModelLoadedForTheOther test. Use shared constant: define at file scope `private static let headroomBufferBytes: Int64 = 1_000`.
- [x] `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift:376` — Duplicate hardcoded headroom buffer 1_000 bytes in router configuration for sameRepoDifferentRevisionDoesNotShare test. Use shared constant: `private static let headroomBufferBytes: Int64 = 1_000`.
- [x] `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift:413` — Duplicate hardcoded headroom buffer 1_000 bytes in router configuration for singleProfileCallerSequentialUseIsUnaffected test. Use shared constant: `private static let headroomBufferBytes: Int64 = 1_000`.
- [x] `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift:443` — Duplicate hardcoded headroom buffer 1_000 bytes in router configuration for releaseCannotRaceAnInFlightResolveAndCorruptAccounting test. Use shared constant: `private static let headroomBufferBytes: Int64 = 1_000`.

_Note: 5 engine findings were dropped from this report under the "never ask to refactor existing tests" rule — `ExamplesTests.swift:532,561,575,576` and `ToolIntegrationTests.swift:77` all target test code that already existed prior to this commit's diff hunks (confirmed via `git diff HEAD~1..HEAD`), not new test code added by this change._
