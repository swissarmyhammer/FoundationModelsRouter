---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1yd6qyn696j29gksg8fw95j
  text: |-
    Research and discoveries, before the step record.

    **Two consequences the card did not list, both necessary.**

    1. `Router.release(token:)` had one more caller than the card knew: `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift`, in `staleReleaseDoesNotClobberResident`. Card `^5ph8cdm` moved the suites off `LanguageModelProfile.release()`, not off the router method. Deleting `release(token:)` therefore breaks that test, so the test now queues the stale token on the real path — `router.enqueuePendingRelease(staleToken)` — and takes the next `resolve` as its drain point. The test proves the same claim and now proves it over the path a stale token really arrives on. A `drainer` profile holds that resolve's residency, and it is dropped with `second` so the final count is still 6.

    2. `LanguageModelProfile.private let router: Router` existed only to serve `release()`. With the method gone nothing reads it. The `dead-code-swift` validator runs periphery with `--retain-public --build-tests`, which reports exactly this shape (an assign-only internal property), so leaving it would ship a new finding. The card's own sentence covers it: "Delete it and the explicit-release path behind it." Removed, together with the `router:` parameter of the `package init`. That rippled to four call sites: `Router.buildProfile`, `Tests/.../Helpers/HandBuiltProfileFixtures.swift`, `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift`, and the DocC link in `OwningProfileTests.swift`. `residencyToken` stays — `ProfileLifecycleTests` reads it.

    **Stale doc comments that named the deleted symbols**, all corrected: `Router.swift` (the actor doc, the `poolLock` doc, the `residentProfiles` doc, and the `releaseHoldingPoolLock` doc, which now describes itself rather than "the body of `release(token:)`"), `Resolution/ModelLoader.swift` (`evict` said it was called from `LanguageModelProfile/release()`), and `PooledResidencyTests.swift`.

    **Orphaned comments left by the deleted call sites**, all removed: a `// MARK: - Release residency` heading in `Examples/CompactionDemo/main.swift` and in `Tools/RecordCompactionFixture/main.swift`, and that heading plus "// Frees both resident models and the router's residency slot." in `Examples/MultiModelGeneration/main.swift`.

    **Two verification traps this repo sets, both avoided.** `swift build --package-path IntegrationTests` alone returns a cache hit in 1.4 s and never compiles `IntegrationTests.swift`, so it proves nothing about the edited call site; it also builds no test target by default. The real proof is `--build-tests` after touching the file, which compiled `FoundationModelsRouterIntegrationTests` with zero warnings. Separately, `swift test` prints one summary line per test bundle, so reading only the tail of the output shows the 83-test Evals bundle and hides the 1234-test main bundle.

    **Discovery filed as a new card, not fixed here.** `^m8pw5mz` — the suite doc of `OwningProfileTests.swift` describes a `LanguageModelProfile.deinit` that does not exist. The staleness came in with `^fa7b61c`, not with this card, and correcting it is not on this card.

    No DocC page names `release()` or the old init, and this repo has no `Scripts/check-doc-links.py` and no `ARCHITECTURE.md`. No formatter was run.
  timestamp: 2026-09-07T17:03:42.549493+00:00
- actor: claude-code
  id: 01m1yd738kqwx2f7kx5me3mwge
  text: |-
    ### implement — changed

    - evidence: 13 files, +24/-60. Sources: `LanguageModelProfile.swift` (deleted `public func release() async`, deleted the `private let router: Router` it alone served and the `router:` parameter of the `package init`, corrected the class doc), `Router.swift` (deleted `func release(token:)`, corrected four doc comments that named it), `Resolution/ModelLoader.swift` (doc). Call sites: `Examples/CompactionDemo/main.swift`, `Examples/MultiModelGeneration/main.swift`, `Tools/RecordCompactionFixture/main.swift`, `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift`, `README.md`. Tests: `ProfileLifecycleTests.swift` (the stale-token test now queues through `enqueuePendingRelease`), `HandBuiltProfileFixtures.swift`, `RealModelHarness.swift`, `OwningProfileTests.swift`, `PooledResidencyTests.swift`.
    - verification: `swift build --build-tests` complete, no warnings. `swift test` — 1234 tests in 134 suites passed (2 pre-existing `withKnownIssue`), and 83 tests in 10 suites passed. `swift build --package-path IntegrationTests --build-tests`, after touching the edited file to defeat the cache — complete, no warnings.
    - acceptance criteria: all four met. No `release()` call on a `LanguageModelProfile` anywhere in Sources, Tests, Examples, Tools or IntegrationTests. `grep -n 'release' README.md` returns nothing. No public API added; the public surface is one method smaller. No new warnings.
    - next: ready for `/review`. Read the comment above this one first — it records two consequences the card did not list, and why each is necessary.
  timestamp: 2026-09-07T17:03:54.131172+00:00
- actor: claude-code
  id: 01m1ydece03ffkbf66qsf23rw8
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` (files touched to force real recompile) — Build complete in 30.12s, 0 compiler warnings on our source (1 pre-existing `missing creator for mutated node` llbuild message from the vendored mlx-swift resource bundle, unrelated to any edited file). `swift test` — main bundle: 1234 tests in 134 suites passed with 2 known issues (intentional negative-path assertions, not failures); Evals bundle: 83 tests in 10 suites passed. Zero skipped tests. One run showed `ToolInvocationLivenessTests` fail under parallel load (`BoundedWait` timing); reran it isolated (20/20 passed) and reran the full main bundle twice more (1234/1234 passed both times) — flaky under system load, not a regression from this change. `swift build --package-path IntegrationTests --build-tests` — Build complete in 4.27s, same single pre-existing mlx-swift bundle warning, no others; proves the deleted `release()` call site in `IntegrationTests.swift` compiles.
    - acceptance checks: `grep -rn 'release()' --include='*.swift' Sources Tests Examples Tools IntegrationTests` finds matches only under vendored `IntegrationTests/.build/checkouts` and `.build/index-build` third-party dependency sources (`gate.release()`, `Unmanaged<...>.release()`, etc.) — none on `LanguageModelProfile`. `grep -n 'release' README.md` returns nothing.
    - next: hand off to review.

    step: test
    outcome: green
    evidence: swift build --build-tests (30.12s, real recompile, 0 source warnings) + swift test (main: 1234/1234 passed, 2 known issues; Evals: 83/83 passed) + swift build --package-path IntegrationTests --build-tests (4.27s, 0 source warnings)
    task: ^m8vj0jr
  timestamp: 2026-09-07T17:07:52.896467+00:00
depends_on:
- 01M1Y6WTHKDJW2REXWR5PH8CDM
position_column: doing
position_ordinal: '80'
title: Delete LanguageModelProfile.release() and its remaining call sites
---
## What

With `^fa7b61c` (residency owned by ARC) and `^5ph8cdm` (suites off `release()`) done, `LanguageModelProfile.release()` has no job left. It only offers a way to free models that something else still borrows. Delete it and the explicit-release path behind it.

Changes:

- `Sources/FoundationModelsRouter/LanguageModelProfile.swift` — delete `public func release() async` (`:220-222`) and the doc paragraph above it that tells a caller to release. Correct the class doc (`:160-165`) to say residency ends when the last reference goes away.
- `Sources/FoundationModelsRouter/Router.swift` — keep the release body as the drain step only. `release(token:)` (`:566`) stops being the entry point a profile calls and becomes internal to `drainPendingReleases()`. `residentProfiles` and `releaseKey` (`:577`) are unchanged.
- `Examples/MultiModelGeneration/main.swift:215`, `Examples/CompactionDemo/main.swift:352`, `Tools/RecordCompactionFixture/main.swift:184` — delete the `await profile.release()` line. Each is the last statement before exit, so nothing replaces it.
- `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift:522` — delete the call.
- `README.md` — delete the `await profile.release()` line from the example (`:61`) and any sentence that tells a caller to release.

There is no DocC reference to fix: `Sources/FoundationModelsRouter/FoundationModelsRouter.docc` names `release()` nowhere.

- [ ] Delete `release()` from `LanguageModelProfile.swift` and correct the class doc.
- [ ] Fold `Router.release(token:)` into the drain path in `Router.swift`.
- [ ] Delete the call in the three `main.swift` files and in `IntegrationTests.swift`.
- [ ] Update `README.md`.

## Acceptance Criteria

- [ ] `grep -rn 'release()' --include='*.swift' Sources Tests Examples Tools IntegrationTests` finds no call on a `LanguageModelProfile`.
- [ ] `grep -n 'release' README.md` returns nothing.
- [ ] No public API is added to replace it — the public surface is one method smaller than before `^fa7b61c`.
- [ ] `swift build` reports no new warnings.

## Tests

- [ ] Run `swift test`. Every suite passes, including the suites `^5ph8cdm` migrated.
- [ ] Run `swift build --package-path IntegrationTests` so the deleted call site in `IntegrationTests.swift` is proven to compile. The real-model suites themselves are not run for this task.
- [ ] `Tests/FoundationModelsRouterTests/ExamplesTests.swift` keeps a residency example, and it now reads resolve → use → drop with no cleanup call. This is the worked-example documentation, so it is the regression guard against the method coming back.

## Workflow

- Use `/tdd` — the suites are already green from `^5ph8cdm`; delete, then prove the whole build stays green.
#router #router-api #api #cleanup