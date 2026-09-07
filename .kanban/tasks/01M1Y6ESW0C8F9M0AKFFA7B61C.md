---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1y83fc422csqgj00b4jecjs
  text: |-
    Research and TDD notes.

    Name collision found: `Router.swift` already declared `private struct ResidencyHold` — the router's own per-slot bookkeeping (pool key + charged bytes). A new top-level `ResidencyHold` class could not be constructed from `Router.swift`, because the file-private struct shadows it there. I renamed the pre-existing struct to `SlotCharge` (4 use sites, all inside `Router.swift`, all private). The variable `slotHolds` became `slotCharges` for the same reason.

    RED, before any source change:
    - `droppingLastHandleFreesBudgetForNextResolve` failed at once: the second resolve threw `ResolutionFailure` with a budget of 1000 bytes, exactly the detached-eviction race the card describes.
    - `handleAloneKeepsModelResident` in its first, literal form PASSED. The detached release task had not run yet when the spy was read, so the assertion was a race, not a proof. I strengthened the test: after the profile is dropped it resolves the same definition again, which gives the whole eviction path (pool lock, loader, spy) its turn, and then asserts `evictions == 0` plus no reload (`llmLoads.count == 2`, `embedderLoads.count == 1`). That form failed 5 times out of 5 runs before the change and passes 5 out of 5 after it.

    Deviations from the card, each forced:
    1. `ResidencyHold` is `package`, not internal. The `package` initializers of `RoutedModel` and `LanguageModelProfile` take one, and Swift rejects a `package` initializer with an internal parameter type.
    2. The `residencyHold` parameter defaults to `nil` on both initializers. Two in-package fixtures build a profile by hand — `Tests/FoundationModelsRouterTests/Helpers/HandBuiltProfileFixtures.swift` and `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift` — and, as their own documentation says, hold no residency.
    3. `enqueuePendingRelease(_:)` also starts a best-effort `Task` that drains the queue. Without it, `SessionChokepointTests.sessionRetainsProfile` fails: it drops the profile and the session and waits for 3 evictions with no resolve after them, and a drain that only runs inside `resolve` never comes. The queue, not the task, is what makes the release certain; the in-resolve drain still runs first under the pool lock, so the card's deterministic requirement is untouched, and a token drained twice is a no-op.
  timestamp: 2026-09-07T15:34:32.580940+00:00
- actor: claude-code
  id: 01m1y84p0z6m89egn8857r8zzh
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/ResidencyHold.swift (new), Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/LanguageModelProfile.swift, Tests/FoundationModelsRouterTests/PooledResidencyTests.swift. `swift build --build-tests`: no errors, no warnings. `swift test`: 1234 tests in 134 suites passed (plus 83 tests in 10 suites), 2 known issues, both pre-existing. `swift test --filter 'PooledResidencyTests'`: 15 tests passed, up from 13, so the two new tests ran. The two new tests alone: 5 runs, 2 tests each, all passed; before the change the same two failed 5 runs out of 5.
    - next: /review
  timestamp: 2026-09-07T15:35:12.159255+00:00
- actor: claude-code
  id: 01m1y8f71yfy1chfq19vj5qfa0
  text: |-
    ### test — green
    - evidence: swift build --build-tests (forced real recompile by clearing FoundationModelsRouter build intermediates) — 0 errors, 0 new warnings; only the pre-existing, non-fixable vendored-dependency warning `missing creator for mutated node: ... mlx-swift_Cmlx.bundle/Contents/MacOS`. swift test — Test run with 1234 tests in 134 suites passed after 6.022 seconds with 2 known issues (both pre-existing, intentional `withKnownIssue` assertions in RealModelHarness.swift and BoundedWait.swift, files not touched by this change); Test run with 83 tests in 10 suites passed after 0.205 seconds (Evals bundle). Suite "Pooled model residency" (the new tests for this task) passed after 5.977 seconds. No skipped or disabled tests found in the repo. IntegrationTests package not run, per instruction.
    - note: code_context LSP diagnostics reported 10 stale "Cannot find type 'ResidencyHold' in scope" errors on Router.swift and LanguageModelProfile.swift. This is a stale sourcekit-lsp index (lsp_indexed_percent was 90%, and the tool's own status reports sourcekit-lsp as not fully installed/version-mismatched); the real swiftc compiler resolves ResidencyHold cleanly, proven by a from-scratch recompile of the FoundationModelsRouter target and a fully green swift test run. Not a real error.
    - next: none
  timestamp: 2026-09-07T15:40:57.278608+00:00
- actor: claude-code
  id: 01m1y8gpywad4mev881st1mvkm
  text: |-
    ### commit — changed
    - evidence: 2f6d603 feat(residency): move pooled model residency ownership to ARC (^fa7b61c)
    - next: none
  timestamp: 2026-09-07T15:41:46.332912+00:00
- actor: claude-code
  id: 01m1y8xfkmt1prvjr5wffw7v0y
  text: |-
    ### review — findings
    - evidence: 3 findings (3 confirmed, 0 refuted) from `review sha HEAD~1..HEAD` — LanguageModelProfile.swift:119, LanguageModelProfile.swift:209, Router.swift:456
    - next: correct the three findings in the description section dated 2026-09-07 10:42, then run the review again.
  timestamp: 2026-09-07T15:48:44.788756+00:00
- actor: wballard
  id: 01m1y8y6jvrsadndf4v6k3mtac
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 4 files, ResidencyHold.swift new
    - test: green — swift test, 1234 + 83 passed, 0 new warnings
    - commit: 2f6d603
    - review: findings — Sources/FoundationModelsRouter/LanguageModelProfile.swift:119, Sources/FoundationModelsRouter/LanguageModelProfile.swift:209, Sources/FoundationModelsRouter/Router.swift:456
  timestamp: 2026-09-07T15:49:08.315687+00:00
- actor: claude-code
  id: 01m1y9vtj174d2ysfvt56jw9vj
  text: |-
    How the three findings were corrected.

    Finding 3 (`duplication/duplication`, Router.swift): extracted `private func releaseCharges(_ charges: [SlotCharge]) async` beside `releaseKey`, and called it from the failed-resolve rollback and from `releaseHoldingPoolLock(token:)`. The two loop copies are gone.

    Findings 1 and 2 (`code-hygiene/dead-code-swift`, assignOnlyProperty on `residencyHold`) have two different causes, so they got two different corrections:

    - `LanguageModelProfile.residencyHold` was truly redundant storage. The profile holds its three handles strongly, and each handle holds the hold strongly, so the chain profile -> handle -> hold already keeps the residency alive for as long as the profile object. Deleting the property, its initializer parameter and its doc removes dead storage and removes NO strong reference. The class doc now states the chain.
    - `RoutedModel.residencyHold` must stay: it is the only ARC edge from a handle, and a tool that keeps a handle alone depends on it. Nothing reads the value, and nothing should — the strong reference is the claim, and the read periphery cannot see is ARC's own release at deinit. The `dead-code-swift` rule provides exactly one contract for that case: `// periphery:ignore` on the line above the declaration, with the reason on its own comment line above the marker and no trailing text on the marker. The property carries that marker and the reason.

    No validator was edited, and no strong reference was removed.

    Verification: `periphery` reports nothing on either property, and `review file Sources/FoundationModelsRouter/LanguageModelProfile.swift --validators code-hygiene` returns 0 findings. `review file Sources/FoundationModelsRouter/Router.swift --validators code-hygiene,duplication` returns 0 duplication findings and 0 dead-code findings; it does return 16 `swift/naming-clarity` findings (`def`, `ref`, `sp`, `slotRes` and similar) on pre-existing lines this change never touched, all outside the diff this card's review scope covers.
  timestamp: 2026-09-07T16:05:19.041427+00:00
- actor: claude-code
  id: 01m1y9w0gjk16wgmx54r2nyc21
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/LanguageModelProfile.swift, Sources/FoundationModelsRouter/ResidencyHold.swift. `swift build --build-tests`: 0 errors, 0 new warnings (only the pre-existing vendored `mlx-swift_Cmlx.bundle` node warning). `swift test`: 1234 tests in 134 suites passed with 2 known issues, both pre-existing; 83 tests in 10 suites passed (Evals). Suite "Pooled model residency" passed. `swift test --filter PooledResidencyTests`: 15 tests in 1 suite passed, the same count as before this change.
    - next: /review
  timestamp: 2026-09-07T16:05:25.138549+00:00
- actor: claude-code
  id: 01m1ya1h42e2wxvmgzvj2k5a95
  text: |-
    ### test — green
    - evidence: swift package clean && swift build --build-tests (forced full recompile, 0 warnings in FoundationModelsRouter/Tests/Evals targets — only pre-existing C++17-extension warnings from the vendored mlx-swift Cmlx checkout, unrelated to this change); swift test — 1234 tests in 134 suites passed (2 known issues, both pre-existing withKnownIssue blocks in BoundedWaitTests.swift and RealModelHarnessTests.swift, unrelated to Router.swift/LanguageModelProfile.swift/ResidencyHold.swift); FoundationModelsRouterEvals — 83 tests in 10 suites passed. IntegrationTests package not run, per instruction.
    - next: none — build is clean, no known pre-existing issues in the touched files (Router.swift releaseCharges, LanguageModelProfile.swift residencyHold periphery:ignore, ResidencyHold.swift deletion of LanguageModelProfile.residencyHold).
  timestamp: 2026-09-07T16:08:25.986848+00:00
- actor: claude-code
  id: 01m1ya2hh7na373qv2jv86jr8e
  text: |-
    ### commit — changed
    - evidence: 998186c fix(router): resolve review findings on residency hold ownership
    - next: none
  timestamp: 2026-09-07T16:08:59.175807+00:00
- actor: claude-code
  id: 01m1ya7bxkctxsxrnnk5n3z583
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (998186c) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. All three prior findings verified fixed: Router.swift:654 releaseCharges(_:) called from :457 and :644; LanguageModelProfile.residencyHold storage deleted; RoutedModel.residencyHold at LanguageModelProfile.swift:123 marked `// periphery:ignore` with its reason.
    - next: task moved to done.
  timestamp: 2026-09-07T16:11:37.267217+00:00
- actor: wballard
  id: 01m1ya844by3j6djdxn7gdag80
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files, all 3 findings fixed
    - test: green — swift package clean + swift build --build-tests, 0 warnings; swift test 1234 + 83 passed
    - commit: 998186c
    - review: clean — 0 findings, 7 validators attempted; task moved to done
  timestamp: 2026-09-07T16:12:02.059389+00:00
position_column: done
position_ordinal: ffffc780
title: ARC-own pooled residency with a shared ResidencyHold and drain evictions inside Router.resolve
---
## What

Today a pooled model stays resident only while the `LanguageModelProfile` **object** is alive. `RoutedModel` points back at its profile weakly (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:87`), and the profile's `deinit` starts a detached task to release the residency (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:226-230`).

Two problems come from this:

1. A tool keeps only a handle, not the profile — `SummarizeTool.model: RoutedLLM` (`Sources/FoundationModelsRouter/Tools.swift:13`) and `EmbedTool.model: RoutedEmbedder` (`Sources/FoundationModelsRouter/Tools.swift:45`). A tool that outlives the profile object loses its models.
2. The eviction runs in a detached task, so `loader.evict` (`Sources/FoundationModelsRouter/Router.swift:583`) may not have run when the next `resolve` measures the host budget at `Sources/FoundationModelsRouter/Router.swift:596`. A "does not fit" answer is therefore a race.

Move the residency claim out of the profile object and into a small reference-counted object that the profile **and** all three handles share.

Approach:

- Add `Sources/FoundationModelsRouter/ResidencyHold.swift`: a `final class ResidencyHold: Sendable` that stores the `Router` and the residency `ULID` token only. Its `deinit` calls a new synchronous `Router` method that appends the token to a pending queue. It must not refer to `LanguageModelProfile` or `RoutedModel`, so no reference cycle is possible.
- `RoutedModel` (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:17`) stores the hold strongly. Its `init` is `package`, so the added parameter breaks no caller outside the package.
- `LanguageModelProfile` stores the same hold instance and loses its `deinit` (`LanguageModelProfile.swift:226-230`); the hold's `deinit` replaces it. `Router.resolve` builds one hold per residency token and passes it to the three handles and to the profile.
- `Router` gains a `Mutex<[ULID]>` pending-eviction queue (import `Synchronization`, as `LanguageModelProfile.swift:2` does), a synchronous `enqueuePendingRelease(_:)` the hold's `deinit` calls, and a `private func drainPendingReleases() async` that pops every token and runs the existing `release(token:)` body. `resolve` awaits the drain before it computes the host budget (`Router.swift:596`).

Out of scope, and left exactly as it is:

- `LanguageModelProfile.release()` stays public and keeps its current behavior, so the suites that assert eviction counts right after a `release()` (`PooledResidencyTests.swift:433`, `:598`, `:687`) keep passing untouched. `Router.release(token:)` is already idempotent (`Router.swift:569`), so an explicit `release()` followed later by the hold's `deinit` still decrements once. Deleting `release()` and updating its 11 call sites is a follow-up task.
- The weak `owningProfile` back-reference stays. `makeSession` still needs the sibling slots (`RoutedLLM.swift:123`, `Recording/SessionTreeRestoration.swift:251`), so a `makeSession` call on a handle whose profile object is gone still traps at `RoutedLLM.swift:30`. The new tests must therefore not call `makeSession` after they drop the profile — `RoutedEmbedder.embed(texts:)` (`RoutedEmbedder.swift:44`) needs no profile and is the right probe.

- [x] Add `ResidencyHold` in `Sources/FoundationModelsRouter/ResidencyHold.swift`.
- [x] Store the hold in `RoutedModel` and in `LanguageModelProfile`; delete the profile's `deinit`; build one hold per token in `Router.resolve`.
- [x] Add the pending-eviction queue, `enqueuePendingRelease(_:)` and `drainPendingReleases()` to `Sources/FoundationModelsRouter/Router.swift`, and await the drain in `resolve` before the budget is measured.
- [x] Add the two new tests to `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift`.

## Acceptance Criteria

- [x] A resolved profile object is dropped while a stub tool still holds its `RoutedEmbedder`. The spy reports `evictions == 0`, and `embed(texts:)` through the held handle returns its stub vectors.
- [x] After the profile **and** every handle built from it are dropped, the three pooled models are evicted: the spy reports `evictions == 3` at the next `resolve`.
- [x] Neither new test calls `release()`. Dropping the last reference is the only eviction trigger in them.
- [x] A `resolve` that follows a dropped profile sees the freed bytes in its first budget measurement — the test contains no `Task.sleep`, no retry loop, and no `Task.yield`.
- [x] Every existing suite that calls `release()` passes with no edit: `PooledResidencyTests`, `ProfileLifecycleTests`, `ToolSharedProfileTests`, `ExamplesTests`, `ToolInvocationLivenessTests`, `TranscriptTreeAccessTests`.
- [x] `swift build` reports no new warnings.

## Tests

- [x] `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift` — add `handleAloneKeepsModelResident`: resolve a profile against the existing stub loader, build an `EmbedTool` over `profile.embedding`, drop the profile reference, then assert `await spy.evictions == 0` and that `embed(texts:)` through the tool's handle still returns vectors. Before the change this test fails, because the profile's `deinit` releases the residency while the tool still holds the handle.
- [x] `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift` — add `droppingLastHandleFreesBudgetForNextResolve`: drop the profile and every handle, then resolve a second profile whose footprint fits only if the first profile's models were evicted, and assert the resolve succeeds and `await spy.evictions == 3`. Before the change this test fails, because the detached eviction task has not run when the budget is measured.
- [x] Both new tests use the stub containers, the stub loader and the `LoadSpy` actor already in `PooledResidencyTests.swift` (`:112-180`) — no network, no GPU.
- [x] Run `swift test`. Every suite must pass, including the six unchanged suites listed in the acceptance criteria.
- [x] When narrowing with `swift test --filter PooledResidencyTests`, confirm the run reports the new tests as executed. A filter that matches a display name instead of the type name matches nothing and still exits `0`, so a green exit code alone does not prove the tests ran.

## Workflow

- Use `/tdd` — write the failing tests first, then implement until they pass.
#router #router-api #tech-debt

## Review Findings (2026-09-07 10:42)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 7 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file

- [x] `Sources/FoundationModelsRouter/LanguageModelProfile.swift:119` `code-hygiene/dead-code-swift` — var.instance `residencyHold` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/LanguageModelProfile.swift:209` `code-hygiene/dead-code-swift` — var.instance `residencyHold` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/Router.swift:456` `duplication/duplication` — The loop structure that iterates over charges and releases each is duplicated across two locations. Both blocks are verbatim identical except for the source of charges. Extract a shared async helper function `private func releaseCharges(_ charges: [SlotCharge]) async { for charge in charges { await releaseKey(key: charge.key, chargedBytes: charge.chargedBytes) } }`. Replace line 456-457 with `await releaseCharges(Array(slotCharges.values))` and line 645-646 with `await releaseCharges(charges)`. This eliminates the loop duplication and creates a single source of truth for charge release logic.
