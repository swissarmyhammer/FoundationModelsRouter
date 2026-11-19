---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7s1h6yz2v7bdj099styfp18
  text: |-
    Research (implement, part 1).
    - Both build paths reach `RoutedSessionActor.makeFork(id:seed:tools:)` through `ForkBuild` (Directory/SessionLaunchForkRequest.swift). The directory mails the first prompt only after `launchFork` returns, so a copy that `makeFork` awaits is done before the first prompt.
    - The fork is made by the handle of the slot of the source (`forkHandle()`), so the slot and the model are equal by construction on this path. The guard is still necessary (task spec), and a test reaches it through a hand-built handle with another slot or model.
    - A session has no reference to the router. The budget goes through a new closure on `RoutedModel` that the router sets with a weak capture of its `PromptCacheSizing`, so a handle does not keep the sizing alive after the router.
    - The router is the only conformer of `SessionPromptCacheScoping` (`MLXFoundationModelsSessionBackend`). No test helper conforms.
    - Log capture: `TelemetryCapture.run` + `useCaptureLogger(for:)` on the source; the fork takes the explicit logger of its source in `useTelemetry` before the copy.
    - A stored property on the fork for the outcome would be filled after init (rule "no stored property waits for a later method"), so the fork logs the outcome itself, with the fork id metadata of the fork log, through the logger of the session (category SessionDirectory).
  timestamp: 2026-11-19T04:37:41.471013+00:00
- actor: claude-code
  id: 01m7s202yspsz4vexja5avanv9
  text: |-
    ### implement — changed
    - evidence: names: protocol `SessionPromptCacheCopying.copyPromptCache(fromSession:toSession:) async -> PromptCacheCopyOutcome`; Router result `PromptCacheCopyOutcome` (String raw: `copied`, `sourceNotFound`, `sourceInUse`; not named PromptCacheCopyResult, so it does not hide the mlx-swift-lm type in part 2); `SessionPromptCacheScoping.copyPromptCache(fromSession:toSession:) async -> PromptCacheCopyOutcome?` (nil when the model does not conform) on `MLXFoundationModelsSessionBackend`; `RoutedSessionActor.takePromptCacheCopy(of:through:)` (guard same slot + model, log, budget after `.copied`), called by `makeFork(id:seed:tools:)` before it returns; `RoutedModel.promptCacheBudgetSender` (Router sets it with a weak capture of its sizing); `PromptCacheSizing.sendBudgetAgain()`; log key `RouterTelemetry.LogMetadataKey.forkPromptCacheCopy` ("session.fork_prompt_cache_copy"), record "a fork asked for a copy of the prompt cache of its source" with session id + fork id, category SessionDirectory. No MLXLanguageModel conformance, no pin change.
    - files: Sources/FoundationModelsRouter/{Concurrency/SessionPromptCache.swift, Resolution/LiveModelLoader.swift, Session/RoutedSessionActorPromptCache.swift, Session/RoutedSessionActorForking.swift, LanguageModelProfile.swift, Router.swift, Sizing/PromptCacheSizing.swift, Sizing/PromptCacheBudget.swift (doc: MLX copy / GGUF live sequence), Directory/RouterSessionDirectory.swift (doc of fork(_:)), Tracing/RouterTelemetry.swift}; Tests: new ForkPromptCacheCopyTests.swift (11 tests), new Helpers/PromptCacheLogLoader.swift, Helpers/PromptCacheScopeRecordingModel.swift (copy log + conformance), Helpers/ForkFixtures.swift and Helpers/RouterTestFixtures.swift (optional loader).
    - RED: with declaration stubs, 4 failed (default-path copy, launcher copy, budget, log); then without the guard, the 2 slot/model tests failed; then all 11 passed. 5 tests passed at the stub stage because they pin existing behavior or the nil branch: aBackendOverAModelThatDoesNotCopyGivesNoOutcome, aForkWhoseSourceHasNoCacheAnswers, aForkWhoseSourceCacheIsInUseAnswers, aClosedForkReleasesOnlyItsOwnKey, aClosedSourceDoesNotReleaseTheKeyOfTheFork.
    - filtered: 10 suites (ForkPromptCacheCopyTests, SessionPromptCacheKeyTests, SummarizerPromptCacheTests, the 4 directory fork suites, ForkBuildTests, RouterTelemetryLoggingTests, PromptCacheBudgetTests): 95 tests passed.
    - full `swift test` once: 3093 tests in 352 suites passed, plus 50 and 19; 0 failures; only the known mlx-swift_Cmlx bundle warning. Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full-swift-test.txt
    - next: /review. Not committed or pushed (orders of this run).
  timestamp: 2026-11-19T04:45:48.889042+00:00
- actor: claude-code
  id: 01m7s2c90pgstp02z5c80cjbs8
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD; engine counts: 1 finding, 1 confirmed, 1 refuted. Driver check: 1 more finding. Tests/FoundationModelsRouterTests/Helpers/PromptCacheScopeRecordingModel.swift:85, Tests/FoundationModelsRouterTests/ForkPromptCacheCopyTests.swift:178
    - next: /implement the 2 open items in "Review Findings (2026-11-18 22:46)", then /review again.
  timestamp: 2026-11-19T04:52:28.310528+00:00
- actor: claude-code
  id: 01m7s2d86gd720pjpjkgfz3wjn
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 10 source files, 5 test files (new ForkPromptCacheCopyTests with 11 tests)
    - test: green — one full swift test run, 3093 tests in 352 suites (+50, +19), 0 failures
    - commit: 0244b600
    - review: findings — PromptCacheScopeRecordingModel.swift:85 (the fake reports usage after a copy that did not copy), ForkPromptCacheCopyTests.swift:178 (the two no-copy tests and the copied-only budget guard are not tested)
  timestamp: 2026-11-19T04:53:00.240605+00:00
- actor: claude-code
  id: 01m7s2pspdj3e5d1j7wgydqf9c
  text: |-
    ### implement — changed
    - evidence: the 2 items of "Review Findings (2026-11-18 22:46)" are done and flipped to [x]. No production change.
    - files: Tests/FoundationModelsRouterTests/Helpers/PromptCacheScopeRecordingModel.swift (`PromptCacheCopyCall.outcome`; `recordCopy(from:to:outcome:)`; `promptCacheUsage` changes only after a recorded `.copied` copy), Tests/FoundationModelsRouterTests/ForkPromptCacheCopyTests.swift (`copyBeforeTheFirstPass(of:to:outcome:)`; the two no-copy tests expect one copy from the source id to the fork id with their outcome; new parameterized test `theBudgetIsSentAgainOnlyAfterACopyThatCopied` with `.copied` -> 1 send, `.sourceNotFound` -> 0, `.sourceInUse` -> 0), Tests/FoundationModelsRouterTests/Helpers/HandBuiltProfileFixtures.swift (optional `promptCacheBudgetSender` on `makeProfile`, default nil).
    - why a counting sender and not a budget value: after the fix of item 1, a send after a non-copied outcome reads the same usage, so the budget value is the same with or without the guard. The count of the budgets of the loader is not usable, because the footprints task of the router sends budgets at times the test does not control. So the new test forks through a hand-built handle whose budget sender counts its calls (the existing `RunCount`).
    - RED: with `guard outcome == .copied else { return }` removed from `takePromptCacheCopy(of:through:)`, the `.sourceNotFound` and `.sourceInUse` cases failed (`budgetSends.value → 1`, expected 0). Then the guard was put back with `git checkout` of that file; `git status` shows no Sources change.
    - filtered: FoundationModelsRouterTests.ForkPromptCacheCopyTests, 12 tests passed (the new test has 3 cases).
    - full `swift test` once: 3094 tests in 352 suites passed, plus 50 and 19; 0 failures; only the known mlx-swift_Cmlx bundle warning. Output: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer-FoundationModelsRouter/9f2cfbe4-77ae-4086-bbe8-c47c9f2c5409/scratchpad/full-swift-test-findings.txt
    - next: /review. Not committed (orders of this run). Task stays in doing.
  timestamp: 2026-11-19T04:58:13.069692+00:00
position_column: doing
position_ordinal: '80'
title: 'A fork copies the prompt cache of its source: the protocol, the copy at the fork, and the budget (D205 (f), part 1)'
---
## Goal

When the Router makes a fork, the prompt cache of the fork starts as a copy of the cache of the source. The first pass of the fork does not prefill the copied history. The source and the fork stay independent. The user approved this on 2026-11-18 ("Yes, do it"). Brief: `../.briefs/fork-kv/router-brief.md`, overview `overview.md`; research on the closed task ^3x07j46.

This part needs no new pin. It uses a fake copying model in the tests. The MLX conformance and the real-cache tests are part 2; the GGUF tests are part 3.

## Change

1. A new protocol `SessionPromptCacheCopying` (or a requirement on `SessionPromptCacheReleasing`, `Concurrency/SessionPromptCache.swift:14`): `copyPromptCache(fromSession:toSession:) async -> PromptCacheCopyResult`, with a Router-side result type that maps to the mlx-swift-lm `PromptCacheCopyResult` later (`copied`, `sourceNotFound`, `sourceInUse`). Add `copyPromptCache(fromSession:toSession:) async` to `SessionPromptCacheScoping` (`:26`), implemented on `MLXFoundationModelsSessionBackend` as `releasePromptCache(ofSession:)` is (`Resolution/LiveModelLoader.swift:994`): it calls the model only when the model conforms.
2. The copy at the fork: in `RoutedSessionActor.makeFork(id:seed:tools:)` (`Session/RoutedSessionActorForking.swift:90`), after the fork adopts its backend and before the function returns, copy the cache of the source (`promptCacheSessionID`) to the id of the fork. Only when the source and the fork use the same slot and the same model reference. Thus the copy is done before `fork(_:)` mails the first prompt, on both build paths (the host launcher and the default). Log the result with the fork log.
3. The cut: the copy holds the whole cache of the source. The reuse rules of the model rewind it to the common prefix at the first pass. The Router does not count tokens.
4. The memory budget: after a copy, send the prompt-cache budget again (as `PromptCacheSizing.sendBudget` does at an acquire, `Sizing/PromptCacheSizing.swift:180`). Write in the doc of `PromptCacheBudget` (`Sizing/PromptCacheBudget.swift`) that the MLX copy is in the prompt-cache store and its budget, and that the GGUF copy is a live sequence inside the KV of the context.
5. Close: `releasePromptCache()` of the fork (`Session/RoutedSessionActorPromptCache.swift:40`) releases only the copy. A close of the source does not release the copy.

Read `routed-session-cancellation-invariants` in the memory folder before a change in `Session/RoutedSessionActor*.swift`.

## Tests (with a fake copying model)

- [x] A fork calls the copy one time, from the source id to the fork id, before the first prompt of the fork starts. Both build paths (the default and a host launcher).
- [x] No copy when the slot or the model reference differs, or when the model does not conform.
- [x] `sourceNotFound` and `sourceInUse`: the fork works and answers.
- [x] The budget is sent again after a copy.
- [x] A close of the fork releases the fork id only; a close of the source does not release the fork id.

## After

Push when green. Send the sha to testudoapp-9a. #d205

## Review Findings (2026-11-18 22:46)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 15 file(s) reviewed, 6 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

- [x] `Tests/FoundationModelsRouterTests/Helpers/PromptCacheScopeRecordingModel.swift:85` `completeness/invariant-propagation` — The copy outcome is handled at one site only. copyPromptCache (lines 216-221) records a copy and returns copyOutcome, which can be .sourceNotFound or .sourceInUse. promptCacheUsage (line 85) ignores that outcome and treats any recorded copy as a copy that changed the cache, so usageAfterCopy is reported after a copy that did not copy. A later test that combines a non-copied outcome with a budget check would see a budget change that the model never made. Record the outcome with the copy (for example, store the outcome in PromptCacheCopyCall or in the log) and have promptCacheUsage change only when the recorded outcome is .copied. Alternatively, document in the doc comment that any copy call changes usage, and keep the behaviour explicit.
- [x] `Tests/FoundationModelsRouterTests/ForkPromptCacheCopyTests.swift:178` `driver-check/tests-guard-real-behavior` — The tests `aForkWhoseSourceHasNoCacheAnswers` (line 178) and `aForkWhoseSourceCacheIsInUseAnswers` (line 191) do not make sure that the copy ran and gave the non-copied outcome. They passed before the code existed, and they pass now if the fork does not copy. Also, no test guards `guard outcome == .copied` in `takePromptCacheCopy(of:through:)` (`Sources/FoundationModelsRouter/Session/RoutedSessionActorPromptCache.swift:78`): if the fork sends the budget again after `sourceNotFound` or `sourceInUse`, all tests pass. In each of the two tests, expect `fixture.log.recordedCopies == [Self.copyBeforeTheFirstPass(of: source, to: fork)]`. Add an expectation that a non-copied outcome sends no new budget (this needs the fix of the finding above, so that the fake usage changes only for `.copied`).

Driver checks with no finding: (1) the copy ends before `fork(_:)` mails the first prompt on the default path and on the launcher path, because both build through `ForkBuild` and `launchFork` returns before the mail. (2) The new `await` in `makeFork(id:seed:tools:)` reads no state of the source after the suspension, and it does not use the generation queue or a lock. The copy goes from `source.promptCacheSessionID` to the id of the fork, and the fork backend is over the same raw model (`container.makeSession` of the source handle). (3) Only the Router holds `PromptCacheSizing` strongly, and `footprintsTask` captures the resizer and not the sizing, so the weak sender sends no budget after the router is gone. (4) A launcher that throws after the copy, or a build that ends after the close, goes to `ForkBuild.discard(_:)`, which calls `close()` of the fork, and `close()` calls `releasePromptCache()` with no condition, so the copy is released. (5) `aBackendOverAModelThatDoesNotCopyGivesNoOutcome`, `aClosedForkReleasesOnlyItsOwnKey` and `aClosedSourceDoesNotReleaseTheKeyOfTheFork` guard real behavior of the spec; the other two of the 5 tests have the finding above.