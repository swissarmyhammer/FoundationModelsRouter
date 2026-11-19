---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7s3rdbz2hedvx6h1754kjmn
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — not started. mlx-swift-lm origin/stable is at 94ce7e2b and has no `copyPromptCache(fromSession:toSession:)` (checked 2026-11-18). Part 1 (^2qm6eas) is done.
    - next: start again when the mlx-swift-lm session sends the sha of the copy API on stable; then update the pin with `--manifest-cache local`.
  timestamp: 2026-11-19T05:16:34.559312+00:00
- actor: claude-code
  id: 01m7sf6k3v504g9hpr7pw1b66a
  text: |-
    Picked up. The blocker is gone: mlx-swift-lm is resolved at stable c1b3d5e with `MLXLanguageModel.copyPromptCache(fromSession:toSession:) -> PromptCacheCopyResult` (copied(tokenCount:), sourceNotFound, sourceInUse, refused(sameSession|destinationHasCache|destinationInUse|copyFailed)).

    Research:
    - The MLX executor checks the session cache out at the start of one executor call and checks it in before that call returns (MLXLanguageModel.swift, `checkIn` after `dispatchGeneration`). `ExecutorPassBoundaryIntegrationTests` shows that the pass that emits a tool call ends before the SDK runs the tool body. Thus at `.callingToolCall` the source holds no cache while the tool body runs, and the copy gives `.copied` (with the tokens of the tool call; the fork rewinds them). At `.lastCompletedTurn` while a turn runs, the result depends on the instant: during an executor call `.sourceInUse` (no wait), between calls (a tool body) `.copied`.
    - The store (`ExecutorPromptCacheStore.current`, default `.shared`) is process-wide. Its task-local override is internal. The Router unit target does no MLX GPU work and has no metallib bootstrap; other unit suites send budgets to the global store through `LiveModelLoader`, so a real-cache unit test would not be deterministic. MLXScriptedLM also has no tool calls yet (README: "Planned: tool calls"), so it cannot script `.callingToolCall`. Decision: the real-cache tests are an integration suite in IntegrationTests (`.exclusiveRealModel`, which also bootstraps the metallib), over small local models (Qwen2.5-3B-Instruct-4bit standard, Qwen3-1.7B-4bit flash/decision, the gated embedder). The mapping and the conformance get unit tests (no GPU).
  timestamp: 2026-11-19T08:36:33.531313+00:00
- actor: claude-code
  id: 01m7sfyac99tr2hpbehqkmy2da
  text: |-
    ### implement — changed
    - mapping: `MLXLanguageModel: SessionPromptCacheCopying` (Concurrency/SessionPromptCache.swift) calls the mlx-swift-lm copy and maps `PromptCacheCopyResult` to `PromptCacheCopyOutcome`: copied(tokenCount:) -> .copied, sourceNotFound -> .sourceNotFound, sourceInUse -> .sourceInUse, refused(r) -> .refused(PromptCacheCopyRefusal(r)) with the new `PromptCacheCopyRefusal` (sameSession, destinationHasCache, destinationInUse, copyFailed). `PromptCacheCopyOutcome` lost its String raw value; the log uses `logValue` ("refused.<reason>" for a refusal). A refused outcome sends no budget (guard `outcome == .copied` is unchanged; unit test row added).
    - doc: `takePromptCacheCopy(of:through:)` and `RouterSessionDirectory.fork(_:)` now state: at `.callingToolCall` the copy gets `.copied` (the executor call that emitted the tool call checked its cache in before the SDK ran the tool body); at `.lastCompletedTurn` while a turn runs it gets `.sourceInUse` during an executor call (no wait, the fork reads its whole prompt) and `.copied` between calls.
    - files: Sources/FoundationModelsRouter/Concurrency/SessionPromptCache.swift, Session/RoutedSessionActorPromptCache.swift, Directory/RouterSessionDirectory.swift, Tracing/RouterTelemetry.swift; Tests/FoundationModelsRouterTests/MLXPromptCacheCopyTests.swift (new), ForkPromptCacheCopyTests.swift; IntegrationTests/.../ForkPromptCacheCopyIntegrationTests.swift (new), Support/ForkPromptCacheCopySupport.swift (new), Support/AdjustableWorkingSetProbe.swift (moved out of PromptCacheBudgetIntegrationTests), Support/IsolatedPoolRouter.swift (`recordsDurably:`).
    - unit: `swift test --filter "FoundationModelsRouterTests.MLXPromptCacheCopyTests|FoundationModelsRouterTests.ForkPromptCacheCopyTests"` 16 tests in 2 suites passed (RED first: compile failure for the missing `.refused`, `logValue` and conformance).
    - integration (real prompt cache, local models Qwen2.5-3B-Instruct-4bit + Qwen3-1.7B-4bit + the gated embedder; no download on this host): IntegrationTests mlx-swift-lm updated to c1b3d5e with `--manifest-cache local`; `swift build --package-path IntegrationTests --build-tests` clean; `swift test --package-path IntegrationTests --skip-build --filter FoundationModelsRouterIntegrationTests.ForkPromptCacheCopyIntegrationTests` 11 tests passed in 32 s. Covers each card checkbox.
    - full suite: `swift test` once, 3103 tests in 353 suites passed (+50, +19 in the other targets), 0 failures; the only warning line is the build-system note "missing creator for mutated node ... mlx-swift_Cmlx.bundle" (not from the code). Output: scratchpad full-swift-test.txt.
    - why not MLXScriptedLM in unit tests: the store is process-wide (its override is internal), other unit suites send it budgets, the unit target has no metallib bootstrap, and the scripted model has no tool calls yet.
    - next: /review. Not committed, not pushed (the card "After" step is for the commit step).
  timestamp: 2026-11-19T08:49:31.017590+00:00
- actor: claude-code
  id: 01m7sg7m9xwt4rxy0djqftbhvc
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (3db3d2fd): 0 findings, 0 confirmed, 1 refuted, 14 attempted, 0 failed. The ignore rule excluded 4 .kanban files.
    - extra checks, all pass:
      - Mapping: each PromptCacheCopyResult case (copied, sourceNotFound, sourceInUse, refused with sameSession, destinationHasCache, destinationInUse, copyFailed) maps to the router outcome of the same name. This agrees with the mlx-swift-lm pin c1b3d5e.
      - Scope: each RoutedSessionActor binds its own id (promptCacheSessionID = id.description). The fork does not bind the scope of the source.
      - Doc: ExecutorPromptCacheStore.copy gives sourceInUse only while a pass has the source checked out. The executor call checks the cache in before it returns. The text about .callingToolCall and .lastCompletedTurn agrees with this. ExecutorPassBoundaryIntegrationTests exists.
      - Integration tests (read, not run): with the copy removed, the first call of the fork caches 0 tokens, so each "history less 16 tokens" bound fails. The memory and release tests fail on the byte checks. The no-copy test expects 0.
      - Public API: PromptCacheCopyOutcome and PromptCacheCopyRefusal are internal. No sibling package under swissarmyhammer/*/Sources uses them or the log key.
    - next: none. The task is in done.
  timestamp: 2026-11-19T08:54:36.093255+00:00
- actor: claude-code
  id: 01m7sg875nsdsmctxr476gz7q2
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — SessionPromptCache.swift, RoutedSessionActorPromptCache.swift, RouterSessionDirectory.swift, RouterTelemetry.swift; MLXPromptCacheCopyTests (new), ForkPromptCacheCopyTests; ForkPromptCacheCopyIntegrationTests (new, 11) and integration support files; mlx-swift-lm pin 31e5cfc9 → c1b3d5e
    - test: green — one full swift test run, 3103 tests in 353 suites (+50, +19), 0 failures; ForkPromptCacheCopyIntegrationTests 11/11, one run
    - commit: 3db3d2fd
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-19T08:54:55.413758+00:00
depends_on:
- 01M7S15T37N1RG9ECXB2QM6EAS
position_column: done
position_ordinal: ffffffffffbc80
title: 'A fork copies the MLX prompt cache: the mlx-swift-lm pin, the conformance, and real-cache tests (D205 (f), part 2)'
---
## Goal

The MLX part of the fork cache copy. Brief: `../.briefs/fork-kv/router-brief.md` (items 1, 2, 4, 6, 7); overview `overview.md`.

## Depends on

- Part 1 (the protocol and the copy at the fork).
- mlx-swift-lm on `stable`: the public `MLXLanguageModel.copyPromptCache(fromSession:toSession:)` and `PromptCacheCopyResult`. Today `stable` is pinned at `31e5cfc9`; `94ce7e2b` moves the cache store to new files. Do not start before the mlx-swift-lm session sends the sha. Then update the pin with `--manifest-cache local` (first stop a `sourcekit-lsp` whose cwd is this repo).

## Change

- `MLXLanguageModel` conforms to the copy protocol of part 1, and maps its `PromptCacheCopyResult` to the Router result.
- A running turn of the source: take the documented result of mlx-swift-lm (a wait or `sourceInUse`). For a fork at the calling tool call, find out if the source pass checked its cache in while the tool body runs, and write the result in the doc.

## Tests (a model with a real prompt cache)

Use the scripted model of mlx-swift-lm (`MLXScriptedLM`, `TranscriptKVCache`) if the Router tests can load it, else an integration test with a small model.

- [x] The first call of a fork reports `cachedInputTokenCount()` at least the tokens of the history up to the cut, less the tokens that the template changes at the end. For `.lastCompletedTurn`, `.callingToolCall` and `.historyPosition(n)`.
- [x] With no copy (no cache, or `sourceInUse`), the fork prefills the whole history and answers correctly.
- [x] Independence: a prompt to the fork does not change the cache of the source (the next turn of the source is a full hit), and the reverse.
- [x] Greedy output: the first answer of a fork with the copy equals the first answer of a fork with no copy.
- [x] Memory: after a fork, `promptCacheUsage` includes the copy, and the resident prompt-cache bytes stay at or below the budget that `PromptCacheBudget` sent.
- [x] Release: a close of the fork releases the copy and keeps the cache of the source; a close of the source keeps the copy.
- [x] A fork through the host launcher also gets the copy.

## After

Push when green. Send the sha to testudoapp-9a. #d205