---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1eq3gkndbrrg602t9b74kgm
  text: |-
    ### Measurement — the limit reads the box, not the work

    I measured the test six ways. The test code did not change.

    | condition | box load | test wall clock |
    |---|---|---|
    | alone, `--filter secondRespondSeesPriorTurn` | 4.6 | 37.9 s |
    | whole integration package | 5.1 | 35.8 s |
    | alone, direct test bundle | 3.3 | 37.0 s |
    | four copies at the same time, one GPU | 6.3 | 39.8, 40.5, 41.2, 41.4 s |
    | 16 CPU hogs | 23.6 | 38.6 s |
    | 32 CPU hogs | 23.0 | 60.8 s |
    | 64 CPU hogs | 65.5 | limit exceeded, failed at 120.8 s |

    The box is a Mac Studio, `Mac15,14`, 32 cores, 512 GB.

    ### The failure reproduces from CPU load alone

    At 64 CPU hogs the same test recorded the same issue the card quotes:

    ```
    ✘ Test "a second respond() call on the same backend sees the first turn's
      content in context" recorded an issue at
      LanguageModelSessionBackendTests.swift:141:6:
      Time limit was exceeded: 120.000 seconds
    ```

    No code changed. No model changed. Only the load changed. So the limit
    measures the box.

    ### Four copies on the GPU cost 10 percent

    Four copies of the test ran at the same time on one GPU. Each copy took 40
    seconds against 37 seconds alone. A token decode waits on latency, not on GPU
    throughput, so a second decoder costs little. GPU contention is therefore NOT
    the cause.

    CPU contention is the cause. At 32 hogs the test is 1.6 times slower. At 64
    hogs it passes the limit. The curve has no ceiling.

    ### The twin test proves the same point from the failing run

    `secondTurnReusesFirstTurnsKVCache` drives the same instructions, the same two
    prompts and the same reply ceiling as the failing test. The two do identical
    model work. In the failing run the twin passed and this test took 348 seconds.
    Identical work, different result, same process. That is the box.

    ### The product is not slower

    The 13-run table in `integrationTestBudgetMinutes` measures this test at 36.5
    to 63.6 seconds. Today it measured 35.8 seconds inside the whole package. There
    is no regression.

    ### Other test processes share this box

    `pgrep` found two `swiftpm-testing-helper` processes from a different
    repository, `FoundationModelsMultitool`, during my measurements. The box runs
    more than one agent. That is the load source the card's run met.
  timestamp: 2026-09-01T14:48:51.573335+00:00
- actor: claude-code
  id: 01m1erf3ffvaze86pzpr17t9rn
  text: |-
    ### Verification — three whole-package runs

    | run | this test | package total | issues |
    |---|---|---|---|
    | 1 | 35.8 s | 571.1 s | 2 |
    | 2 | 38.0 s | 574.3 s | 2 |
    | 3 | 37.1 s | 559.1 s | 2 |

    This test passed 3 of 3. It used 30 percent of its limit in the worst run.

    The package is red 3 of 3, and never for this test. The two issues are the
    compaction smoke fold, which now fails deterministically. I raised ^erv2vxz
    for it. That failure blocks this card's second acceptance criterion.

    Root package: `swift test` — 1159 tests in 128 suites passed, 83 tests in 10
    suites passed, exit 0, 2 known issues.
    `swift build --package-path IntegrationTests --build-tests` — exit 0.

    ### The answer: (a), and the remedy needs a person

    The card asks whether the limit is wrong or the test is. Measurement says
    neither, and that is why I am stopping.

    **The test is not wrong.** It drives two turns. Both turns are the proof: turn
    1 states the fact, turn 2 must recall it. Its twin
    `secondTurnReusesFirstTurnsKVCache` drives byte-identical prompts for a
    different assertion, so this test does no work its proof does not need.

    **The product is not slower.** The 13-run table measures this test at 36.5 to
    63.6 seconds. It measures 35.8 to 38.0 today.

    **The limit is not wrong in purpose.** It is card ^k0d30s4's budget. It caught
    a compaction round trip at 541.6 seconds, 4.5 times the budget. Every suite of
    both real-model targets reads the one value.

    **The limit is wrong in kind.** It is a wall clock over work whose speed
    depends on the box. I proved that: 64 CPU hogs made this exact test exceed 120
    seconds, with no change to any file. The same finding as ^bqj719z.

    ### No number for the limit is defensible

    I cannot raise the limit from measurement, and I will not pick a round figure.

    - 3 minutes does not cover the 348 seconds the card reports.
    - 6 minutes does. But the whole 29-test package costs 559 to 574 seconds. One
      test would then be allowed to cost more than the whole quiet run, and the
      budget would no longer catch the 541-second test it exists to catch.
    - The load curve has no ceiling. Any value fails at some load.

    ### The decision a person must make

    1. **Keep 2 minutes.** Treat a contended run as a run artifact, and re-run.
       CI already runs the tier alone, and CI passed twice after the failing run.
       Cost: the failure returns whenever another agent loads this box.
    2. **Raise the budget.** This changes ^k0d30s4's decision for both real-model
       targets. No measurement supports a number.
    3. **Make the run quiet.** State that the real-model tier runs alone, with no
       second test process on the box. This is a workflow rule, not code.
    4. **Cut the suite's cost.** Cards ^6ww73dm and ^s49ya8p moved two other
       suites onto a 4B model for exactly this reason, and each states what the
       move no longer proves. This suite would need the same treatment, its own
       measurement table, and its own card.

    I did not guess between these. Options 2 and 4 change what the repository
    proves, and that is not mine to decide.

    ### One fact I could not explain

    The card's run recorded the limit at 120 seconds, then ended at 347.98
    seconds. The body needed 228 more seconds after the cancellation. My
    reproduction ended at 120.8 seconds, so it unwound in 0.8 seconds. A model
    load reads 18 GB and cannot be cancelled, which would fit. I could not
    reproduce the long unwind, so I state it as open rather than as a cause.
  timestamp: 2026-09-01T15:12:39.919755+00:00
- actor: claude-code
  id: 01m1erfrtt9m763z8hh6t0mhy5
  text: |-
    ### implement — stuck
    - evidence: 0 source files changed. The overrun is (a): the limit measures box load, not the work. The same test, unchanged, costs 35.8 to 41.4 s on a quiet box (8 samples), 38.6 s under 16 CPU hogs, 60.8 s under 32, and exceeds the 120 s limit under 64. It passed 3 of 3 whole-package runs at 35.8, 38.0 and 37.1 s. `swift test`: 1159 tests in 128 suites and 83 tests in 10 suites passed, exit 0, 2 known issues. `swift build --package-path IntegrationTests --build-tests`: exit 0. `swift test --package-path IntegrationTests`: red 3 of 3, never for this test — the compaction smoke fold fails, raised as ^erv2vxz.
    - next: a person chooses between the four options in the conclusion comment. Options 2 and 4 change what the repository proves.
  timestamp: 2026-09-01T15:13:01.786659+00:00
- actor: claude-code
  id: 01m1et6t8mzn5va2ymbyy8wv7w
  text: |-
    ### The decision: keep the limit. Close this card.

    The user decided on 2026-09-01. Keep `integrationTestBudgetMinutes` at 2
    minutes. Change no test.

    ### Why the measurement does not apply

    The user supplied the facts this card lacked:

    - This box runs this work alone.
    - CI queues the tests and runs them one at a time.

    So the contention that made the test slow does not happen in CI. The 64-hog
    condition is not a real state of the machine. A limit that only fails under a
    load the system never applies is not a defect.

    ### What the 348-second run actually was

    Two agent sessions ran real-model tests on this workstation at the same time.
    The measurement found `swiftpm-testing-helper` processes from
    `FoundationModelsMultitool` on this box. That is a development artifact, and
    CI's serial queue prevents it.

    ### On the stress runs

    The CPU hogs were a diagnostic, and they were never a test. They were shell
    loops in the scratchpad. No stress code entered the repository. `rg` over
    `Tests`, `IntegrationTests` and `Sources` finds none.

    The user's direction is explicit: the integration tests prove that the system
    works from end to end. They do not measure the machine under load. Do not add
    a stress test here.

    ### What stands

    The measurement itself stays useful, and this card keeps it: the test costs 36
    to 41 seconds on a quiet box, and 35.8 seconds inside the whole package. The
    2-minute limit gives about a 3x margin over the real cost. It still catches a
    test that hangs, which is what it is for.
  timestamp: 2026-09-01T15:43:05.492369+00:00
position_column: done
position_ordinal: ffffb580
title: A real-model backend test exceeds its 120-second limit when the whole integration package runs
---
## What

The whole integration package failed one test on 2026-09-01:

```
✘ Test "a second respond() call on the same backend sees the first turn's content in context"
  recorded an issue at LanguageModelSessionBackendTests.swift:141:6:
  Time limit was exceeded: 120.000 seconds
✘ Test ... failed after 347.982 seconds with 1 issue.
✘ Test run with 29 tests in 14 suites failed after 958.437 seconds with 1 issue.
```

The test ran for 348 seconds against a limit of 120 seconds. The other 28 tests
passed.

The suite is `Gated real-model coverage: MLXFoundationModelsSessionBackend
(milestone 7)`. It drives `RealModels.standard`, which is
`Muse-Glimmer-30B-4bit`, 18 GB of weights.

## What to do

- State why the test takes more than 120 seconds. Two generations against an
  18 GB model may simply cost more than the limit allows on a loaded box.
- Decide whether the limit is wrong, or the test is.
- Do not raise the limit alone if the test does more work than it needs.

## Acceptance Criteria
- [x] The cause of the overrun is stated, with a measurement.
- [ ] The whole integration package passes three times in a row.

## Tests
- [x] Run `swift test --package-path IntegrationTests` three times.

## The cause, measured

The limit measures the box, not the work. The test costs 35.8 to 41.4 seconds
in eight measurements on a quiet box. It exceeds 120 seconds under 64 CPU
hogs, with no file changed. The load curve has no ceiling. See the measurement
comment for the table and the reproduction.

## Blocker

The second acceptance criterion cannot be met, and this test is not the
reason. The compaction smoke fold fails on every package run. It is a separate
defect, raised as ^erv2vxz.

The remedy for the limit needs a person. Measurement rules out both options
the card offers: the test does no work its proof does not need, and no number
for the limit is defensible. The four options and their costs are in the
conclusion comment.

## Note

Found while working task ^49dy082 (a compaction fold defect). The compaction
path is not involved: every compaction suite of the package passed in the same
run. #router #defect #flaky-test #real-model #ci