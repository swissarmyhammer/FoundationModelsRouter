---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzgc7mzcv71m0kmkjwwves5z
  text: |-
    Picked up. Found this card's work already largely landed by commit `159aada` ("fix(test): port metallib bootstrap to unblock gated suites on real hardware"), which was committed BEFORE the card was moved out of `todo` — so the card's checkboxes were never flipped and no comment thread existed. Verifying each acceptance criterion against the actual tree rather than trusting the commit message.

    Verified so far:

    **Port fidelity.** `Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift` exists. Diffed against the MultiTool original at `../FoundationModelsMultitool/Tests/FoundationModelsMultitoolIntegrationTests/Support/MetalLibraryTestBootstrap.swift`: every non-comment difference is one of (a) `enum`/`static let` raised to `public` so two test targets can import it, (b) the literal `"mlx.metallib"` extracted to a named `colocatedMetallibName` constant, (c) `resourceBundleName` interpolated into an error message instead of hardcoded. Mechanism — probe order, `Bundle.allBundles`/`allFrameworks` fallback scan, idempotence, best-effort error handling — is identical. The card's "keep the mechanism identical" instruction is honored.

    **Placement.** It lives in a new non-test `.target` `FoundationModelsRouterTestSupport` (`Package.swift`), depended on by both `FoundationModelsRouterIntegrationTests` and `FoundationModelsRouterEvals`. Correct: `swift test` builds one `.xctest` per test target and runs each in its own process, and the symlink is installed beside the *running binary*, so it must be installed in each process; SwiftPM cannot share source between two `.testTarget`s. The target is deliberately in no `product`, so it does not leak out of the package.

    **Ungated `swift test`: green.** 735 tests / 69 suites, 20 / 8, 12 / 4 — exactly the documented baseline, zero failures. Only warning is the known pre-existing `mlx-swift_Cmlx.bundle` bundle-root "missing creator for mutated node" warning.

    **Retired a recorded gotcha (discovery worth keeping).** Several older cards on this board warn: "IMPORTANT: remove the copied mlx.metallib before any subsequent build — codesign fails on the stray unsigned file inside Contents/MacOS." That warning came from *copying* the metallib. This bootstrap creates a *symlink*, and the warning does not reproduce: with both `.xctest/Contents/MacOS/mlx.metallib` symlinks in place I touched a source file in each gated target and ran `swift build --build-tests` — "Build complete!", exit 0, no codesign failure, and both symlinks survived the rebuild. So the bootstrap does not need a teardown step and does not poison subsequent builds. Future agents can stop deleting the metallib before building.
  timestamp: 2026-08-08T09:45:57.996386+00:00
- actor: claude-code
  id: 01kzgd5c8y2xek3e42njfv1t4c
  text: |-
    Completed the verification. All four acceptance criteria were already satisfied by commit `159aada`; nothing was missing, so no source file was touched this pass.

    **AC 2 — every gated suite touches the bootstrap before live resolution: verified by line-by-line audit, not grep presence.** All 22 gated live tests reach `ensureColocatedMetallib` through exactly three chokepoints, and nothing can run inference ahead of them:
    - `FoundationModelsRouterIntegrationTests` — 8 gated suites, 20 gated `@Test`s. Every one of the 20 bodies takes the gate as its literal first statement (19 via `try await GatedSuiteSerialGate.shared.withPermit { … }`; `IntegrationTests.endToEnd` via `await …shared.wait()` + `defer { …signal() }` — either form reads `.shared` before the permit, so the bootstrap runs first). Ruled out every pre-body path: no `init`/`deinit` on any suite type, no suite-level stored properties beyond `static let` scalars, no `@Test(arguments:)` anywhere in the target, no `TestScoping`/`CustomExecutionTrait`/XCTest `setUp`/`tearDown` anywhere under `Tests/`, and the file-scope `ModelRef` globals are `String`-backed with no I/O. The 8 `.enabled(if:)` conditions are pure `ProcessInfo` env reads.
    - `FoundationModelsRouterEvals` — 2 gated suites, 1 `@Test` each. `.evaluates(` appears exactly twice, and each subject closure funnels into one runner whose `run(...)` opens with `let container = try await self.container()`; both `container()` implementations touch the bootstrap immediately after their `if let loaded` cache check and before constructing `LiveModelLoader`. There are exactly two `*RealSubjectRunner` types, and `LiveModelLoader`, `#hubDownloader()`, `#huggingFaceTokenizerLoader()` and `loadLLM(` appear nowhere else in the target. The hermetic suites use fakes and never build a container.
    - `FoundationModelsRouterTests` (the always-on target) correctly does NOT depend on `TestSupport` — it cannot reach the bootstrap and does not need to. Every `LanguageModelSession`/`loadLLM` call site there takes stub conformers; zero real `MLXArray`/`GPU.`/`Device(` usage exists under `Tests/`.

    **AC 3 — stale comments: verified none remain.** Grepped `metallib` across all `.swift`/`.md`/`.yml`. Every surviving mention in source now either explains the fix or is the fix. The five corrected claims read accurately, and I checked the central one against the actual dependency: `.build/checkouts/mlx-swift/…/backend/metal/device.cpp` says "First try the colocated mlx.metallib", which is exactly the probe the bootstrap targets — so the doc comments' account of the root cause is true, not just plausible. Remaining `metallib` hits are historical comments on older cards (append-only history, deliberately left alone) and `.github/workflows/ci.yml`'s `integration-metallib-glob` input, which is a separate CI-side copy step, not a stale claim.

    **AC 1 — gated run: PASS on the metallib criterion.** `git status` was clean of source edits first (only untracked `.kanban/` files), so the run measured `159aada`'s tree exactly. One command, `FM_ROUTER_INTEGRATION_TESTS=1 swift test`, 647s wall. **Zero metallib output of any kind** — no `MLX error`, no `Failed to load`, and none of the bootstrap's own three diagnostic messages, meaning it found the bundle and installed the symlink cleanly in both gated processes. Real inference ran throughout (integration 123s; evals 299.8s + 511.4s). The abort this card exists to remove is gone.

    **AC 4 — ungated `swift test` green:** 735/69, 20/8, 12/4, exit 0. Exactly the documented baseline. Only the known pre-existing `mlx-swift_Cmlx.bundle` bundle-root warning.

    **The gated run exits 1 on genuine behavioral assertions, all newly reachable for the first time.** None is a metallib failure and none is in this card's scope; I changed no assertion. Filed as four new `phase-1` cards rather than silently absorbed:
    - `^5m97h14` — three suites failing from ONE cause: compaction never fires live. `fillBeforeCompaction` 0.413 vs the 0.80 trigger, so `fillAfterCompaction` actually *grew* to 0.428, recall returned "I do not have access to the project brief or its vault code.", and `checkpointedWindow.count` equalled `fullHistory.count` at 19. Evals agree: `foldOccurred` mean 0.0, `factRetention` mean 0.083. The card's lead is the contradiction that the hermetic sizing tests asserting the fixtures exceed the threshold PASS in the same run — a ~2x disagreement between hermetic accounting and live `contextFill` that must be diagnosed before any fixture or threshold is touched.
    - `^f9zt7c5` — `PropagationProbeIntegrationTests` "MLX path" fails on empty `observations`: the tool was never called, so the probe cannot answer its own question. Likely the zero-tool-call class that `^s4405wc` targets; the card notes the possible dependency.
    - `^86fff75` — from the audit: `FoundationModelsRouterEvals` has no cross-suite serialization, no `.timeLimit`, and two independent runner actors each caching a container for the SAME 27B model, so two copies can be resident at once. Also `evictIfLoaded()` sits in the `@Test` body after the `.evaluates` trait and is skipped when an `#expect` traps — which is happening today.
    - `^d48rmth` — the bootstrap's correctness now depends on 20 test bodies each remembering the gate line. Forgetting it does not fail an assertion; it crashes the whole process on first GPU eval with an mlx-flavored error. Proposes making the trigger structural.

    **Discovery for future agents (also in the earlier comment): stop deleting the metallib before builds.** The board's repeated warning that a stray `mlx.metallib` in `Contents/MacOS` breaks codesign came from *copying* the file. The bootstrap symlinks, and it does not reproduce — with both symlinks in place I touched a source file in each gated target and `swift build --build-tests` completed clean, symlinks surviving. No teardown step is needed.
  timestamp: 2026-08-08T10:02:12.126607+00:00
- actor: claude-code
  id: 01kzgd5mj6gd7e0r6zkrfv7vh1
  text: |-
    ### implement — no-change
    - evidence: no files touched. Commit `159aada` already satisfied all four acceptance criteria; verified each empirically rather than from the commit message. Ungated `swift test` 735/69, 20/8, 12/4, exit 0. Gated `FM_ROUTER_INTEGRATION_TESTS=1 swift test` (647s, one run): zero metallib output — no `MLX error`, no `Failed to load`, no bootstrap diagnostics — with 123s + 299.8s + 511.4s of real inference. Line-by-line audit confirms all 22 gated live tests reach `ensureColocatedMetallib` via `GatedSuiteSerialGate.swift`, `CompactionEvalRealSubjectRunner.container()`, and `CompactionContinuityEvalRealSubjectRunner.container()`, with no `init`/trait/parameterized-argument path able to run inference first. All 5 checkboxes flipped to `- [x]`; card progress 1.0, `phase-1` tag re-verified intact after `update task`.
    - next: `/review`. Note for the reviewer: the gated run exits 1 on behavioral assertions unrelated to this card (compaction never reaches the 0.80 trigger; the tool-context probe records zero tool calls). No assertion was modified; all filed as `^5m97h14`, `^f9zt7c5`, `^86fff75`, `^d48rmth`.
  timestamp: 2026-08-08T10:02:20.614264+00:00
- actor: claude-code
  id: 01kzgdfyh2q0y9jj6gheapfg6f
  text: |
    ### review — clean
    - evidence: scope `review sha HEAD~1..HEAD` (commit 159aada, 9 files / 256 insertions, 45 deletions); counts findings=0 confirmed=0 refuted=0 attempted=9 failed=0 skipped=0. Validators run (default fleet, no `validators` filter — the 9 that match `*.swift`): code-hygiene, code-security, completeness, complexity, duplication, missing-docs, reuse, swift, test-integrity. No acronym-casing (Ram/Json/Llm) findings were emitted, so the standing waiver was not needed. Chokepoints verified present: Tests/FoundationModelsRouterIntegrationTests/Support/GatedSuiteSerialGate.swift:33, Tests/FoundationModelsRouterEvals/Support/CompactionEvalRealSubjectRunner.swift:69, Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift:53; bootstrap at Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift:41 (`public enum`), :52 (`public static let ensureColocatedMetallib`), :78 (extracted `colocatedMetallibName`). Working tree holds only untracked `.kanban/` files, so HEAD~1..HEAD is the complete implementation delta.
    - next: none — zero new findings and every prior checklist item already `- [x]`; task moved to `done`. Newly reachable behavioral failures in the gated suite remain out of scope here, tracked on ^5m97h14, ^f9zt7c5, ^86fff75, ^d48rmth.
  timestamp: 2026-08-08T10:07:58.498909+00:00
- actor: claude-code
  id: 01kzgdk2rbssf14na5963j5zrx
  text: |-
    ### finish iteration 1 — clean
    - implement: no-change — commit 159aada already satisfied all 4 acceptance criteria; verified empirically, no files touched. 4 out-of-scope gated failures filed as ^5m97h14, ^f9zt7c5, ^86fff75, ^d48rmth
    - test: green — ungated `swift test` exit 0 (735/69, 20/8, 12/4), measured by the implement step on this exact unchanged tree; not re-run because implement touched no files, so a re-run could only reproduce it. Gated `FM_ROUTER_INTEGRATION_TESTS=1 swift test` 647s, zero metallib output, exits 1 only on the four filed pre-existing behavioral assertions
    - commit: no-change — no source delta this iteration; the card's implementation was already committed as 159aada, which is the verified-good checkpoint
    - review: clean — `review sha HEAD~1..HEAD` (159aada, 9 files); findings=0 confirmed=0 refuted=0 attempted=9 failed=0; validators code-hygiene, code-security, completeness, complexity, duplication, missing-docs, reuse, swift, test-integrity
    - next: task moved to done by the review gate. Note: review was run BEFORE committing kanban board state deliberately — committing the board first would have made a board-only commit into HEAD~1..HEAD and the code would never have passed the gate
  timestamp: 2026-08-08T10:09:41.131025+00:00
position_column: done
position_ordinal: f380
title: Port metallib test bootstrap so gated suites run on real hardware
---
THIS REPO's task (human-authorized 2026-08-07, unblocking the phase-1 exit card on the FoundationModelsMultitool board). `FM_ROUTER_INTEGRATION_TESTS=1 swift test` currently aborts with `MLX error: Failed to load the default metallib` — a condition this repo's own source documents as an environment limitation (see `Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift`). The MultiTool repo already solved exactly this: `../FoundationModelsMultitool/Tests/FoundationModelsMultitoolIntegrationTests/Support/MetalLibraryTestBootstrap.swift` provides `ensureColocatedMetallib`, which every gated suite there calls before any live model resolution.

## What
- Port `MetalLibraryTestBootstrap.swift` (the `ensureColocatedMetallib` mechanism) from `../FoundationModelsMultitool/Tests/FoundationModelsMultitoolIntegrationTests/Support/` into this repo's gated test targets (`FoundationModelsRouterIntegrationTests`, and `FoundationModelsRouterEvals` if it also does live resolution). Adapt paths/module names; keep the mechanism identical unless something here genuinely differs.
- Call it from every gated suite's setup before any live model resolution, mirroring the MultiTool pattern.
- Remove or update the "environment limitation" comments that describe the metallib failure as unfixable (e.g. in `CompactionRoundTripIntegrationTests.swift`) — after this card they describe a solved problem.

## Acceptance Criteria
- [x] `FM_ROUTER_INTEGRATION_TESTS=1 swift test` no longer aborts on `Failed to load the default metallib` (run it once, one shell command, after checking `git status` for concurrent-session edits)
- [x] Every gated suite in this repo touches the bootstrap before live resolution
- [x] Stale "environment limitation" comments updated
- [x] Ungated `swift test` stays green

## Tests
- [x] The gated suite run above IS the test; also `swift test` (ungated) green

## Workflow
- Mechanical port; implement, run the gated suite once, review, close. Gated runs: one at a time, one shell command per run.
#phase-1