---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0fggss1y79za6yh8qqpqdbs
  text: 'From the Multitool session, 2026-08-20: the contract does NOT require a call to the shared workflow. It documents the expectations and two accepted shapes; the shared swift-ci.yaml is a convenience, not a mandate. Repo-local jobs with `needs: test` satisfy expectation 4. The authority is the workflows README at commit f7b504f (origin/main 5f7e9a5). Verify against that document; do not chase a shared-workflow gap.'
  timestamp: 2026-08-20T11:57:19.521319+00:00
- actor: claude-code
  id: 01m0fn9dw4h4g0xt91kg4vgq8j
  text: 'Coordination from the Multitool session, 2026-08-20 (it reports a unified-CI directive from the user): do NOT convert to the shared workflow yet — swift-ci.yaml cannot run a nested integration package today. The workflows repo is adding an `integration-package-path` input: the integration job will build and run the nested package, the unit job will build it on every run, metallib colocation will search the package path, and `needs: test` stays. When that lands on workflows origin/main, convert this repo''s two repo-local ci.yml jobs to one shared call. Multitool''s card ^jjyqe1a (their board) is the model conversion. The directive reached this board second-hand — confirm with the user before the conversion commit.'
  timestamp: 2026-08-20T13:20:40.836166+00:00
- actor: claude-code
  id: 01m0fnwksy63nb8ekwgnz93r1a
  text: 'Landing signal from the Multitool session: workflows origin/main is 0580114 — `integration-package-path` landed. The interface: setting the input opts the integration job in (clean `<dir>/.build`, `swift build --package-path <dir> --build-tests`, then `swift test --package-path <dir>` through the swift-test action with `integration-filter`/`integration-skip`/`integration-no-parallel` and the no-match-fails-green check); the unit job builds the nested package on every run; `integration-metallib-glob` searches `<dir>/.build`; `needs: test` stays; combining `integration-gate-env` with the package path is an error. The conversion of this repo''s ci.yml to one shared call is now technically unblocked. It stays queued behind the user''s direct confirmation in this session.'
  timestamp: 2026-08-20T13:31:09.502433+00:00
- actor: claude-code
  id: 01m0fpg00r3p9da5994tbjmawg
  text: |-
    From the workflows session (the contract's author), 2026-08-20: the directive is that every Swift repo converges on the shared swift-ci.yaml for both jobs. The support is on workflows main at 20c0a0a. The conversion for this repo, verbatim:

    ```yaml
    jobs:
      ci:
        uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main
        with:
          integration-package-path: IntegrationTests
          integration-skip: CompactionEvalFullDataset
    ```

    Notes from the author: drop the repo-local real-model job and its `needs: test` edge (the ordering is internal); the `--skip` run goes through the swift-test action, which FAILS a run that matched no test — a deliberate behavior change from our current plain `--skip` step (if `CompactionEvalFullDataset` is renamed away, the job goes red); no metallib input is needed because `MetalLibraryTestBootstrap` places the library in-process.

    Execution note for this board: the conversion is queued behind the in-flight summarization card ^xx02yn6 (one agent at a time on the shared tree), and the push happens after the user confirms the directive in this session.
  timestamp: 2026-08-20T13:41:44.600794+00:00
position_column: todo
position_ordinal: '80'
title: Verify this package against the org test expectations after the workflows README lands
---
Filed on a request from the FoundationModelsMultitool session, on the user's directive: every sibling package must comply with the org's new test expectations, documented in the swissarmyhammer/workflows README (push imminent from the workflows-06 session).

This repository already shipped the nested-package shape on 2026-08-20 (tasks ^ryb01x7 and ^g5ghfgm, commits 1db2b56 and 731a7ba). This card verifies the shipped state against the FINAL documented expectations once the README lands, and closes any gap.

## What

Read the four expectations in the swissarmyhammer/workflows README (fetch the pushed version). Verify each against this repository:

1. Root `swift test` runs every unit test and only unit tests — currently 1023 tests in `FoundationModelsRouterTests` plus 77 in `FoundationModelsRouterEvals`, with zero integration suites in the run and zero `.enabled(if:)` gates.
2. Integration tests run as an explicit target — `swift test --package-path IntegrationTests` runs the nested package at `IntegrationTests/Package.swift`.
3. No environment-variable selection — `rg 'FM_ROUTER_'` over the repository finds nothing.
4. CI runs unit before integration — `.github/workflows/ci.yml` orders the real-model job after the unit job with `needs:`.

If the final README states an expectation the shipped state does not meet (for example a required use of the shared workflow's new `integration-filter`/`integration-skip` inputs instead of a repo-local job), fix exactly that gap.

## Acceptance Criteria

- [ ] Each of the four documented expectations is verified against the current tree, with the command and its output recorded on this card
- [ ] Any gap between the shipped state and the final README is fixed, or recorded as a deliberate deviation with the reason

## Tests

- [ ] Root `swift test` — green at the unit-only baseline, zero integration suites listed in the run
- [ ] `swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests` — green, proving the integration package is selectable and runs
- [ ] `rg 'FM_ROUTER_' --glob '!.build' --glob '!.kanban'` — zero matches

## Workflow

- Use `/tdd` for any code gap found — write the failing check first, then fix. #ci #test-debt #tests