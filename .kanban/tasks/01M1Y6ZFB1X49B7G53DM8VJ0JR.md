---
assignees:
- claude-code
depends_on:
- 01M1Y6WTHKDJW2REXWR5PH8CDM
position_column: todo
position_ordinal: '8280'
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