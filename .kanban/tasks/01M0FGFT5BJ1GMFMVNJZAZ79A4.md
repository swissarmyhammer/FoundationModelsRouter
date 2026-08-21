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
- actor: claude-code
  id: 01m0hejhm3fxphg1ajm4nw1s6x
  text: |-
    Research, 2026-08-21. The authority moved since the earlier comments named it. `swissarmyhammer/workflows` at `origin/main` is now `283418a`. Commit `611cd23` made the README a landing page, and it put the contract in `docs/swift-ci.md`. Read that file, not the README. The README now shows only one example call.

    Three things the earlier comments do not state, and that the contract now does:

    1. Shape 2 has TWO requirements, not one. The `needs:` edge is the second. The first is "The unit job builds the integration package on EVERY run", and the document says that a repository which writes its own CI steps must obey both itself. This repository does not obey the first one in the letter. See the part "The gap" in the description.
    2. The `swift-test` action fails a run that matched no test. Thus a conversion changes the behaviour of the present `--skip CompactionEvalFullDataset` step: today a renamed suite runs the 7-minute tier and stays green; through the action the job goes red.
    3. `swift-ci.yaml` has two new inputs the earlier comments do not name: `integration-artifacts-path`, which uploads the forensic files of the integration job in all conditions, and `integration-metallib-glob`, which now searches the nested package's `.build`.

    The conversion is NOT done here. The user did not confirm the direction. It is filed as card ^h56as4j, with both ways to close the gap.
  timestamp: 2026-08-21T06:01:48.419689+00:00
- actor: claude-code
  id: 01m0hejtjjtgnv0584ayv9rxcz
  text: |-
    ### implement — no-change
    - evidence: no source file and no workflow file was changed. The verification record is in the description, part "Verification, 2026-08-21". All four expectations of the contract HOLD: root `swift test` gives `1025 tests in 96 suites` plus `77 tests in 9 suites`, with no integration suite, no `.enabled(if:)`, no `.disabled(`, no `XCTSkip`, and no root test that loads a model; `swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests` gives `2 tests in 1 suite passed after 18.262 seconds`; `rg 'FM_ROUTER_'` gives no hit; `.github/workflows/ci.yml` states `needs: test` on the `real-model` job. Builds: `swift build --build-tests -Xswiftc -warnings-as-errors` is clean in BOTH packages (`Build complete!`, exit 0 each). `actionlint .github/workflows/ci.yml` exits 0. Every path and every name inside `ci.yml` resolves in the tree, thus this pass found no wrong fact to correct.
    - next: the one gap — the unit job does not build the nested package, which requirement 1 of Shape 2 asks for — is recorded as a deliberate deviation with its reason, and filed as card ^h56as4j. The user must decide between the shared workflow and one more build step before that card starts.
  timestamp: 2026-08-21T06:01:57.586034+00:00
- actor: claude-code
  id: 01m0hetwctnrezshf7mky0qsd2
  text: |-
    ### review — clean
    - evidence: `review sha e665028~1..e665028` gives 0 findings, 0 confirmed, 0 refuted. The commit changes 6 files, and all 6 are in `.kanban/`, which `.reviewignore` excludes. Thus no source file and no workflow file was in the scope, as the card says.
    - the recorded evidence was checked again: `rg FM_ROUTER_` exits 1 with no hit; the 4 hits of `.enabled(if:)` are all doc comment lines that start with `///`; there is no `.disabled(` and no `XCTSkip`; `IntegrationTests/Package.swift` declares `FoundationModelsRouterIntegrationTests` and `FoundationModelsRouterEvalIntegrationTests`; `ci.yml` gives `real-model` the edge `needs: test`, and both jobs use the same triggers (push to main, pull request, manual start). The test counts of the two suite runs were not measured again, because the card records them and a real-model run is not permitted here.
    - the deviation was judged on its merits and it is ACCEPTED. `docs/swift-ci.md` gives the reason for the requirement in its own words: "The root build does not compile these tests. Without this build step, the tests can break between runs, and no run shows the breakage." In this repository the `real-model` job is not optional, it uses the same triggers as the unit job, and its first step is `swift build --build-tests --package-path IntegrationTests`. Thus a break in the nested package makes a job red on the same run. The harm the requirement prevents does not occur here. Acceptance criterion 2 permits a recorded deviation with its reason, and the reason holds.
    - one point of the record is not exact, and it does not change the result: when the `test` job is red, `needs: test` makes the `real-model` job stop, thus that run does not compile the nested package. That run is red for another cause, and the next run with a green unit job shows the break. The card says the cost correctly in its own words.
    - next: none for this card. Card ^h56as4j holds the decision to call the shared `swift-ci.yaml`. Do not start it before the user confirms it.
  timestamp: 2026-08-21T06:06:21.594605+00:00
- actor: claude-code
  id: 01m0hew4gnkj5dw3tkch14kedq
  text: |-
    ### finish iteration — clean
    - implement: no-change — all four org expectations hold; every name in `ci.yml` still resolves and `actionlint` exits 0; no source and no workflow file changed
    - test: green — root swift test 1025 in 96 suites plus 77 in 9 suites; `swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests` 2 tests in 18.3 s; both packages build with -warnings-as-errors
    - commit: e665028 (board state only)
    - review: clean — 0 findings; the Shape-2 deviation was judged sound against the contract's own stated purpose; task moved to `done`
    - filed: ^h56as4j holds the deviation decision, which must not start before the user confirms the shared-workflow direction
  timestamp: 2026-08-21T06:07:02.677336+00:00
position_column: done
position_ordinal: ffda80
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

- [x] Each of the four documented expectations is verified against the current tree, with the command and its output recorded on this card
- [x] Any gap between the shipped state and the final README is fixed, or recorded as a deliberate deviation with the reason

## Tests

- [x] Root `swift test` — green at the unit-only baseline, zero integration suites listed in the run
- [x] `swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests` — green, proving the integration package is selectable and runs
- [x] `rg 'FM_ROUTER_' --glob '!.build' --glob '!.kanban'` — zero matches

## Workflow

- Use `/tdd` for any code gap found — write the failing check first, then fix.

## Verification, 2026-08-21

The document moved. `swissarmyhammer/workflows` at `origin/main` is `283418a`. Commit `611cd23` made the README a landing page and put the contract in `docs/swift-ci.md`. The four expectations are in the part "The test contract". This repository uses "Shape 2: a nested integration package".

No file of this repository was changed. Four expectations hold. One requirement of Shape 2 does not hold in the letter, and the part "The gap" below gives the reason and the decision that the user must make.

### Expectation 1 — the root `swift test` runs all the unit tests, and only the unit tests

Command and result:

```
$ swift test
✔ Test run with 1025 tests in 96 suites passed after 5.456 seconds with 1 known issue.
✔ Test run with 77 tests in 9 suites passed after 0.669 seconds.
```

HOLDS. The two counts are the two test targets of the root package, `FoundationModelsRouterTests` and `FoundationModelsRouterEvals`. No integration suite is in the run, because the root `Package.swift` declares no integration target.

No part of the configuration skips a test:

- `rg '\.enabled\(if:' Sources Tests IntegrationTests` — four hits, and all four are doc comments that record the absence of a gate. No trait.
- `rg '\.disabled\(' Tests IntegrationTests/Tests` — no hit.
- `rg 'XCTSkip|throw SkipTest' Tests IntegrationTests/Tests` — no hit.
- `rg 'RealModelContainer\.|\.load\(ref:|HubApi|snapshot\(' Tests` — no hit. Thus no root test loads a model.

The one known issue is not a skipped test. The test "a condition that never holds ends the wait, and never before a late change would have landed" records an expected failure with `withKnownIssue` at `BoundedWait.swift:114`. The test ran, and it passed.

### Expectation 2 — the integration tests run as a separate target, and the command names that target

Command and result:

```
$ swift test --package-path IntegrationTests --filter CompactionSmokeIntegrationTests
✔ Test "one fold against a real model: ..." passed after 14.206 seconds.
✔ Test "a fact planted at the very end of the folded span is still in the summary the fold stores" passed after 18.261 seconds.
✔ Test run with 2 tests in 1 suite passed after 18.262 seconds.
```

HOLDS. The nested package is at `IntegrationTests/Package.swift`. It declares the two real-model targets, `FoundationModelsRouterIntegrationTests` and `FoundationModelsRouterEvalIntegrationTests`. Both tests stayed below `integrationTestBudgetMinutes`, which is 2.

### Expectation 3 — an environment variable does not select a test

Command and result:

```
$ rg -n 'FM_ROUTER_' --glob '!.build' --glob '!.kanban' --glob '!IntegrationTests/.build' .
$ echo $?
1
```

HOLDS. No hit in the repository. `rg 'ProcessInfo.processInfo.environment' Tests IntegrationTests` also gives no hit, thus no test reads an environment variable by another name.

### Expectation 4 — CI runs the unit job before the integration job

Command and result:

```
$ python3 -c "import yaml;d=yaml.safe_load(open('.github/workflows/ci.yml'));print(list(d['jobs'].keys()));print(d['jobs']['real-model'].get('needs'))"
['test', 'real-model']
test
```

HOLDS. This repository writes its own CI steps, and the contract tells such a repository to set its own `needs:` edge. The `real-model` job states `needs: test`.

The file also parses and lints:

```
$ actionlint .github/workflows/ci.yml
$ echo $?
0
```

### The facts inside `ci.yml` are correct

Each path and each name that the file gives resolves in the tree today:

| the file says | the tree says |
| --- | --- |
| the root package declares no integration target | correct — the root test targets are `FoundationModelsRouterTests` and `FoundationModelsRouterEvals` |
| the nested package holds `FoundationModelsRouterIntegrationTests` and `FoundationModelsRouterEvalIntegrationTests` | correct — `IntegrationTests/Package.swift` declares both |
| the guard script is gone | correct — `.github/` holds only `ci.yml`, and no file reads the string `No matching test cases were run` |
| ask for the opt-in tier with `--filter CompactionEvalFullDataset` | correct — the suite `CompactionEvalFullDatasetIntegrationTests` is in `CompactionEvalRealModelTests.swift` |
| `MetalLibraryTestBootstrap` installs the metallib symlink in the process | correct — `Tests/FoundationModelsRouterTestSupport/MetalLibraryTestBootstrap.swift`, and `MetalLibraryBootstrapIntegrationTests` proves the shaders load |

Thus this pass found no wrong fact to correct, and `ci.yml` was not touched.

### The gap: the unit job does not build the nested package

`docs/swift-ci.md` gives two requirements for Shape 2, and it says that a repository which writes its own CI steps must obey both itself:

1. "The unit job builds the integration package on EVERY run."
2. "The integration job runs after the unit job, through `needs:`."

Requirement 2 holds. Requirement 1 does NOT hold in the letter. The `test` job runs `swift build --build-tests` for the root package only. The command `swift build --build-tests --package-path IntegrationTests` is in the `real-model` job.

The purpose of the requirement is met, and here is the reason. The requirement exists because `integration-package-path` is an OPT-IN input of the shared workflow: a caller that does not set it never compiles the nested package. In this repository the `real-model` job is not opt-in. It runs on each push, on each pull request and on each manual start. Thus each CI run compiles the nested package, and a compile failure in it makes the run red.

The deviation still costs one thing: the run learns of a compile failure in the nested package only after the whole hermetic suite passes, and not in the same job.

**This is recorded as a deliberate deviation, and it is not corrected here.** The user must first decide if `ci.yml` calls the shared `swift-ci.yaml`. That decision reached this board only through peer agent sessions, and the user did not confirm it. The conversion satisfies requirement 1 in the letter, because the shared workflow builds the nested package in its unit job. Card ^h56as4j holds that decision, the two ways to close the gap, and the conversion.
#ci #test-debt #tests