---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: The unit CI job does not build the nested IntegrationTests package — the user must decide if ci.yml calls the shared swift-ci.yaml
---
Found by the verification pass of ^zaz79a4 on 2026-08-21.

**Do NOT start this card before the user confirms the direction.** The direction came to this board from peer agent sessions only. The user did not confirm it.

## The gap

The org test contract is in `swissarmyhammer/workflows`, file `docs/swift-ci.md`, at `origin/main` = `283418a`. It gives two requirements for "Shape 2: a nested integration package", and it says that a repository which writes its own CI steps must obey both itself:

1. "The unit job builds the integration package on EVERY run. The root build does not compile these tests. Without this build step, the tests can break between runs, and no run shows the breakage."
2. "The integration job runs after the unit job, through `needs:`."

In `.github/workflows/ci.yml` today:

- Requirement 2 HOLDS. The `real-model` job states `needs: test`.
- Requirement 1 does NOT hold in the letter. The `test` job builds only the root package. The command `swift build --build-tests --package-path IntegrationTests` is in the `real-model` job.

The purpose of requirement 1 is met, because the `real-model` job is not opt-in here: it runs on each push, on each pull request and on each manual start. Thus each run compiles the nested package. The cost of the deviation is that a compile failure in the nested package shows only after the whole hermetic suite passes.

## The two ways to close it

### Way 1 — the shared workflow (the direction the peer sessions give)

Replace the two repo-local jobs with one call:

```yaml
jobs:
  ci:
    uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main
    with:
      integration-package-path: IntegrationTests
      integration-skip: CompactionEvalFullDataset
```

The shared workflow then builds the nested package in its unit job, and it keeps the `needs:` edge itself.

Two behaviour changes come with this way, and the user must accept both:

- The `--skip` run goes through the `swift-test` action. That action FAILS a run which matched no test. If `CompactionEvalFullDataset` is renamed away, the job goes red. The plain `--skip` step of today stays green and silently runs the 7-minute tier.
- The repo-local step comments, which record why no metallib is copied and why the two jobs are ordered, go away. `swift-ci.yaml` also offers `integration-artifacts-path` and `integration-metallib-glob`, and the card must state if this repository wants them.

### Way 2 — one more step in the repo-local unit job

Add `swift build --build-tests --package-path IntegrationTests` to the `test` job. This obeys requirement 1 in the letter and keeps the two repo-local jobs.

## Acceptance Criteria

- [ ] The user states which way to take
- [ ] `.github/workflows/ci.yml` obeys both Shape 2 requirements in the letter
- [ ] `actionlint .github/workflows/ci.yml` is clean
- [ ] The root `swift test` and `swift test --package-path IntegrationTests` still select the same tests as before the change

#ci #test-debt