---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0ja4dty7zskrghcwyghgge7
  text: |-
    ## Decision recorded 2026-08-21

    The user confirmed Way 1: call the shared `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main`, in the same style as the sibling FoundationModels repositories. This card is no longer blocked.

    ### Inputs to pass

    - `integration-package-path: IntegrationTests` — yes.
    - `integration-skip` — NO. Task ^k0d30s4 deleted `CompactionEvalFullDataset`. No reference is left, and the current `ci.yml` passes no `--skip`. The "rename turns the job red" risk in the card text is stale.
    - `integration-metallib-glob` — NO. The shared workflow's copy is not needed here. The user also thinks `MetalLibraryTestBootstrap` itself is not needed; a separate card probes that. Either way this card passes no glob.
    - `integration-artifacts-path` — NO for now. The integration tests record into `FileManager.default.temporaryDirectory`, not a stable path. A move to a stable path is a separate card if CI transcripts are wanted.
    - `integration-no-parallel` — NO for now. The current CI runs in parallel, and each target holds its own in-process permit. A change here changes the timing that ^bpwfbyz measures.
    - `docc-target` — NO. The root package does not depend on `swift-docc-plugin`.

    ### Scope added, same style as the siblings

    - Job name `ci:`.
    - A header comment block in `ci.yml` that states the structural split: the root package declares no integration target, `swift test` at the root cannot reach the nested package, no environment variable selects a suite, and the shared workflow builds the nested package in its unit job and orders its integration job after it.
    - A `CIWorkflowTests` unit test in the root package that pins the `uses:` line and the `integration-package-path` input, as Multitool, ACPClient and MetadataRegistry do.

    ### Acceptance criteria, updated

    - [x] The user states which way to take — Way 1
    - [ ] `.github/workflows/ci.yml` calls the shared workflow with `integration-package-path: IntegrationTests` and no other integration input
    - [ ] `ci.yml` carries the header comment block
    - [ ] `CIWorkflowTests` pins the call and the input
    - [ ] `actionlint .github/workflows/ci.yml` is clean
    - [ ] The root `swift test` and `swift test --package-path IntegrationTests` still select the same tests as before the change
  timestamp: 2026-08-21T14:03:25.918560+00:00
- actor: claude-code
  id: 01m0jabyey223gmtt0r3wmkqr5
  text: |-
    ## Research, 2026-08-21

    - Read the two sibling `ci.yml` files. Multitool carries a long header and four inputs; MetadataRegistry carries a shorter header, two inputs, and names the LEGACY `integration-gate-env` input that it does not pass. This repository passes one input, `integration-package-path: IntegrationTests`, as the decision says.
    - Read the two sibling `CIWorkflowTests.swift` files. Both use Swift Testing, `@Suite("CI workflow")`, and a private static `workflowLines()` helper that reads `.github/workflows/ci.yml`. Multitool reads through a `RepositoryFile` helper; MetadataRegistry resolves the repository root from `#filePath` with three `deletingLastPathComponent()` steps. This repository has no `RepositoryFile` helper and no test that reads a repository file by `#filePath`, so the new test uses the `#filePath` shape and needs no new helper type.
    - `actionlint` 1.7.12 is installed at `/opt/homebrew/bin/actionlint`.
    - The nested package holds `FoundationModelsRouterIntegrationTests` and `FoundationModelsRouterEvalIntegrationTests`. `MetalLibraryTestBootstrap.swift` is at `Tests/FoundationModelsRouterTestSupport/`. Card ^q8gkngy exists and probes whether the bootstrap is needed.
    - Plan: write `Tests/FoundationModelsRouterTests/CIWorkflowTests.swift` first and watch it fail against the current two-job `ci.yml`; then rewrite `ci.yml`; then run `actionlint`, the root `swift test`, and `swift build --build-tests --package-path IntegrationTests`.
  timestamp: 2026-08-21T14:07:32.318042+00:00
- actor: claude-code
  id: 01m0jahr0vrcks4g56yhtevsey
  text: |-
    ## Implementation landed, 2026-08-21

    ### What changed

    - `.github/workflows/ci.yml`: the two repo-local jobs (`test`, `real-model`) are gone. One job `ci:` calls `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main` with the single input `integration-package-path: IntegrationTests`. No `integration-skip`, `integration-metallib-glob`, `integration-artifacts-path`, `integration-no-parallel`, `docc-target` or `integration-gate-env`. The `on:` and `concurrency:` blocks are unchanged. The header comment states the structural split (root package declares no integration target; `swift test` at the root cannot reach the nested package; no environment variable selects a suite and none may start to), what the shared workflow does (builds the nested package in its unit job on every run; orders its integration job after the unit job with its own `needs:`), why the two jobs are ordered (model resident on the GPU; a hermetic failure is cheap to learn first), and why no metallib input is passed (`MetalLibraryTestBootstrap` covers it in-process today; card ^q8gkngy probes whether even that is needed).
    - `Tests/FoundationModelsRouterTests/CIWorkflowTests.swift` (new, Swift Testing, not `@MainActor`): three tests. (1) the `uses:` line equals `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main`; (2) `integration-package-path: IntegrationTests` is set; (3) no line starts with `integration-gate-env:`. The file reads `ci.yml` relative to `#filePath`, the same shape as the MetadataRegistry sibling.

    ### TDD record

    - RED: `swift test --filter CIWorkflowTests` against the old two-job `ci.yml`: tests 1 and 2 failed for the expected reason (no `uses:` line, no input); test 3 passed, because it is a negative pin (no gate-env input exists today and none may appear).
    - GREEN after the `ci.yml` rewrite: 3 tests in 1 suite passed.

    ### Verification

    - `actionlint .github/workflows/ci.yml`: clean, exit 0 (actionlint 1.7.12).
    - Root `swift test`: `FoundationModelsRouterTests` 1029 tests in 97 suites passed (2 known issues, both pre-existing `withKnownIssue` sites in `RealModelHarness.swift` and `BoundedWait.swift`); `FoundationModelsRouterEvals` 77 tests in 9 suites passed. Exit 0. The only build warning is the pre-existing SwiftPM `missing creator for mutated node` line about the mlx bundle, present before this change too.
    - `swift build --build-tests --package-path IntegrationTests`: Build complete, exit 0. Not run (needs a real model).
    - `swift test list --package-path IntegrationTests`: lists 31 tests (29 in `FoundationModelsRouterIntegrationTests`, 2 in `FoundationModelsRouterEvalIntegrationTests`) without running them. No `Package.swift` changed, so the selection is the same as before the change; the root run above shows the root selection plus the 3 new tests.

    ### Acceptance criteria (mirror of the updated list in the description)

    - [x] The user states which way to take — Way 1
    - [x] `.github/workflows/ci.yml` calls the shared workflow with `integration-package-path: IntegrationTests` and no other integration input
    - [x] `ci.yml` carries the header comment block
    - [x] `CIWorkflowTests` pins the call and the input
    - [x] `actionlint .github/workflows/ci.yml` is clean
    - [x] The root `swift test` and `swift test --package-path IntegrationTests` still select the same tests as before the change

    ### Not done on purpose

    - No `swift format` / `swiftformat` run (no config in this repo).
    - The integration tests were not executed; they need a real model and take many minutes.

    ### implement — changed
    - evidence: 2 files — `.github/workflows/ci.yml` (rewritten), `Tests/FoundationModelsRouterTests/CIWorkflowTests.swift` (new). `swift test --filter CIWorkflowTests` 3/3 pass; root `swift test` 1029 + 77 pass; `actionlint` clean; `swift build --build-tests --package-path IntegrationTests` complete.
    - next: `/review`
  timestamp: 2026-08-21T14:10:42.331246+00:00
position_column: doing
position_ordinal: '8180'
title: The unit CI job does not build the nested IntegrationTests package — replace the repo-local jobs with the shared swift-ci.yaml call
---
Found by the verification pass of ^zaz79a4 on 2026-08-21.

The user confirmed Way 1 on 2026-08-21 (see the comment "Decision recorded 2026-08-21"). The direction is no longer open.

## The gap

The org test contract is in `swissarmyhammer/workflows`, file `docs/swift-ci.md`, at `origin/main` = `283418a`. It gives two requirements for "Shape 2: a nested integration package", and it says that a repository which writes its own CI steps must obey both itself:

1. "The unit job builds the integration package on EVERY run. The root build does not compile these tests. Without this build step, the tests can break between runs, and no run shows the breakage."
2. "The integration job runs after the unit job, through `needs:`."

In `.github/workflows/ci.yml` before this card:

- Requirement 2 HELD. The `real-model` job stated `needs: test`.
- Requirement 1 did NOT hold in the letter. The `test` job built only the root package. The command `swift build --build-tests --package-path IntegrationTests` was in the `real-model` job.

The purpose of requirement 1 was met, because the `real-model` job was not opt-in here: it ran on each push, on each pull request and on each manual start. Thus each run compiled the nested package. The cost of the deviation was that a compile failure in the nested package showed only after the whole hermetic suite passed.

## The two ways to close it

### Way 1 — the shared workflow (the way the user chose)

Replace the two repo-local jobs with one call:

```yaml
jobs:
  ci:
    uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main
    with:
      integration-package-path: IntegrationTests
```

The shared workflow then builds the nested package in its unit job, and it keeps the `needs:` edge itself.

The decision comment records which other inputs this repository passes (none) and why.

### Way 2 — one more step in the repo-local unit job (not taken)

Add `swift build --build-tests --package-path IntegrationTests` to the `test` job. This obeys requirement 1 in the letter and keeps the two repo-local jobs.

## Acceptance Criteria

- [x] The user states which way to take — Way 1
- [x] `.github/workflows/ci.yml` calls the shared workflow with `integration-package-path: IntegrationTests` and no other integration input
- [x] `ci.yml` carries the header comment block
- [x] `CIWorkflowTests` pins the call and the input
- [x] `actionlint .github/workflows/ci.yml` is clean
- [x] The root `swift test` and `swift test --package-path IntegrationTests` still select the same tests as before the change #ci #test-debt