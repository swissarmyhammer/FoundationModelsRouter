---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0jcb8d1yc09wqp8t2w5pmtk
  text: |-
    ### Probe measurement (2026-08-21)

    **Outcome: the probe ABORTS without the bootstrap. The bootstrap stays (branch 2b of the card).**

    Revisions in `IntegrationTests/.build/checkouts`:
    - mlx-swift: `0bb916c67f4b9e5c682cbe02a42c701c93ab5021` (tag 0.31.6, "guard use of Process (#437)", 2026-07-01)
    - mlx-swift-lm fork (`stable`): `ba8ff43b9040ceec43c84f28637a250f33590633` ("Merge branch 'main' into stable", 2026-08-18)

    Steps:
    1. Removed the line `_ = MetalLibraryTestBootstrap.ensureColocatedMetallib` from `GatedRealModelSuiteTrait.provideScope` (local only).
    2. Deleted the two stale symlinks that earlier runs left in place: `IntegrationTests/.build/out/Products/Debug/FoundationModelsRouterIntegrationTests.xctest/Contents/MacOS/mlx.metallib` and the same file in the `...EvalIntegrationTests.xctest` bundle. Without this step the probe reads an old symlink and proves nothing.
    3. Ran `swift test --package-path IntegrationTests --filter MetalLibraryBootstrapIntegrationTests`.

    Result without the bootstrap (exit 1, process aborted inside the test):
    ```
    MLX error: Failed to load the default metallib. library not found library not found library not found library not found  at .../IntegrationTests/.build/checkouts/mlx-swift/Source/Cmlx/mlx-c/mlx/c/array.cpp:232
    Note: Some test targets reported failures:
      - FoundationModelsRouterIntegrationTests (Swift Testing)
    ```

    Control: restored the line and ran the same command. Result: `Test run with 1 test in 1 suite passed after 0.407 seconds`, and the symlink `FoundationModelsRouterIntegrationTests.xctest/Contents/MacOS/mlx.metallib` was present again.

    Conclusion: mlx-swift 0.31.6 under a plain `swift test` of the nested package still finds no shader library by itself. `load_default_library` in `mlx/backend/metal/device.cpp` probes the colocated `mlx.metallib` first, then the SwiftPM bundle, and all probes miss from `<Target>.xctest/Contents/MacOS`. The model-loading suite was not run, because the card runs it only when the cheap probe passes.

    Next: keep the bootstrap, write the revision, the date and the failure text into the header of `MetalLibraryTestBootstrap.swift`, and update the `ci.yml` header paragraph that says the card "probes whether" so it states the measured result.
  timestamp: 2026-08-21T14:42:06.881893+00:00
- actor: claude-code
  id: 01m0jcdz9mhxavr36b1fe72ej6
  text: |-
    ### implement — changed
    - evidence: probe ABORTED without the bootstrap ("MLX error: Failed to load the default metallib. library not found ..." at mlx-c/mlx/c/array.cpp:232) against mlx-swift 0bb916c67f4b9e5c682cbe02a42c701c93ab5021 (0.31.6) and mlx-swift-lm fork ba8ff43b9040ceec43c84f28637a250f33590633 (stable); control with the bootstrap restored passed (1 test in 1 suite, 0.407 s). Branch 2b taken: the bootstrap stays and its call in `GatedRealModelSuiteTrait` is unchanged. 2 files changed — `Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift` (header gains the "Measured on 2026-08-21" section with revision, command and failure text), `.github/workflows/ci.yml` (header paragraph now states the measured result instead of "probes whether"). Root `swift test`: 1031 tests in 98 suites passed (2 pre-existing known issues) plus 77 tests in 9 suites passed, exit 0. `swift build --build-tests --package-path IntegrationTests`: Build complete, exit 0. The whole integration suite was not run, by instruction of the dispatcher, so the third acceptance box stays open: its root half is green, and its integration half holds the one probe suite only.
    - next: /review. The card says "close this card with the measurement in a comment" for this branch; the card stays in `doing` for the review gate.
  timestamp: 2026-08-21T14:43:35.860066+00:00
- actor: claude-code
  id: 01m0jcp934e4drshv9pepcjjgb
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 94b12c4); counts findings 0, confirmed 0, refuted 0; 2 files reviewed (`Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift`, `.github/workflows/ci.yml`); 4 `.kanban/` files skipped by `.reviewignore`
    - next: none. The card moved doing → review → done. The third acceptance box stays open because the full integration suite did not run; only the bootstrap probe suite ran and passed.
  timestamp: 2026-08-21T14:48:08.036430+00:00
- actor: claude-code
  id: 01m0jcpva3yn892d35emvhea6g
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — probe aborted without the bootstrap ("Failed to load the default metallib", mlx-swift 0bb916c6 / 0.31.6, fork ba8ff43b); control with the bootstrap passed 1/1; 2 doc files changed (MetalLibraryTestBootstrap.swift header, ci.yml header)
    - test: green — root swift test exit 0; swift build --build-tests --package-path IntegrationTests exit 0; MetalLibraryBootstrapIntegrationTests 1/1 passed
    - commit: 94b12c4
    - review: clean — 0 findings on HEAD~1..HEAD; task moved to done
    - open box: the whole integration suite was not run (real models); only the probe suite ran
  timestamp: 2026-08-21T14:48:26.691243+00:00
position_column: done
position_ordinal: ffe180
title: Prove whether MetalLibraryTestBootstrap is still necessary, and delete it if a plain GPU probe loads the shaders without it
---
The user said on 2026-08-21 that the metallib bootstrap is probably a red herring and not needed. The repository records disagree, so this card measures before it deletes.

## What the repository records today

- `Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift` installs a metallib symlink beside the test binary. `GatedRealModelSuiteTrait.swift:218` calls `MetalLibraryTestBootstrap.ensureColocatedMetallib` for every gated suite.
- `MetalLibraryBootstrapIntegrationTests.swift` says that without the symlink the first GPU-device `MLXArray` evaluation aborted the process with "Failed to load the default metallib".
- Two sibling repositories record the same: FoundationModelsMultitool measured that mlx probes `<binary-dir>/mlx.metallib` first, and FoundationModelsMetadataRegistry says the bootstrap was verified necessary even after the shared workflow copies the file.
- Those records may be stale. The root package and the nested package both pin the `stable` branch of the controlled mlx-swift-lm fork, and a newer mlx-swift can resolve its metallib on its own.

## The probe

1. Disable the call at `GatedRealModelSuiteTrait.swift:218` locally (do not commit this step).
2. Run `swift test --package-path IntegrationTests --filter MetalLibraryBootstrapIntegrationTests`. This suite evaluates one GPU-device `MLXArray` and nothing else, so it is the cheapest possible probe. Record the result with the mlx-swift revision from `IntegrationTests/.build/checkouts`.
3. If the probe passes, also run one model-loading suite, for example `CompactionSmokeIntegrationTests`, to show a real model generates without the symlink.

## If the probe passes without the bootstrap

- Delete `MetalLibraryTestBootstrap.swift`, the call in `GatedRealModelSuiteTrait`, and `MetalLibraryBootstrapIntegrationTests.swift`.
- Remove every doc comment that names the bootstrap or the metallib symlink. `rg -n "metallib|MetalLibraryTestBootstrap" Sources Tests IntegrationTests` must return nothing.
- State in the commit the mlx-swift revision that resolves the metallib on its own.

## If the probe aborts without the bootstrap

- Keep the bootstrap. Add the mlx-swift revision and the probe date to the header of `MetalLibraryTestBootstrap.swift`, so the next person does not ask again.
- Close this card with the measurement in a comment.

## Acceptance Criteria

- [x] The probe ran, and its result is in a comment with the mlx-swift revision
- [x] The bootstrap is deleted, or its header states why it stays
- [ ] `swift test` at the root and `swift test --package-path IntegrationTests` are green

Relation: independent of ^h56as4j. The shared CI call passes no `integration-metallib-glob` in either outcome.
#integration #real-model #test-debt