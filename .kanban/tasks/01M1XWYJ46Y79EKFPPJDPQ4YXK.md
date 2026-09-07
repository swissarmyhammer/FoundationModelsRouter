---
comments:
- actor: claude-code
  id: 01m1y17dgtjr6vknpa3v162cwg
  text: |-
    Picked up. Research notes before the edit:

    - `ResolutionProgress.Phase` (Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift) has `sizing`, `downloading`, `loading`, `ready`, `failed(String)`. Only one `switch` over `Phase` is in the package: `yieldPhaseTransitions` in the same file, which finishes the `phases` stream at `.ready, .failed`. `SlotProgress.progressFraction` switches over `SlotProgress.State`, a different type, so it does not change.
    - `runResolve` (Router.swift) can throw `CancellationError` from three places: `poolLock.waitUnlessCancelled()` before the `defer`, the `Task.checkCancellation()` calls before the inner `do`, and the checks inside the inner `do`. The inner `catch` today calls `recordLoadFailure`, which sets `.failed(String)`. So the cancel must be caught around the whole body, not only in that inner `catch`.
    - Existing coverage: `ResolveCancellationTests` already cancels at four stages and while queued on the pool lock, and asserts `progress.phase != .ready`. It is the natural home for the `.cancelled` assertion, because it holds the `StageGate` machinery.
  timestamp: 2026-09-07T13:34:21.722421+00:00
- actor: claude-code
  id: 01m1y1e1xbc4z0kt3706cx0gne
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift (new `public case cancelled` with a doc comment; the `phases` terminal switch now finishes at `.ready, .failed, .cancelled`, with no `default` arm), Sources/FoundationModelsRouter/Router.swift (`runResolve` keeps the pool-lock acquire and the `defer`, and splits the stages into a new private `runResolvePipeline`; a `CancellationError` from the queue or from any stage boundary now goes to the new `recordCancellation`, which sets `.cancelled`; the pipeline's own `catch` no longer calls `recordLoadFailure` for a cancel, so a cancel never becomes `.failed`), Tests/FoundationModelsRouterTests/ResolveCancellationTests.swift (all five cancel scenarios now assert `phase == .cancelled` in place of `phase != .ready`), Tests/FoundationModelsRouterTests/ResolveTests.swift (the loader-failure test now binds the message and asserts it is kept), README.md (the `phases` example comment names the third terminal phase).
    - TDD: the `.cancelled` assertions failed to compile first (`swift build --build-tests`: "cannot convert value of type 'ResolutionProgress.Phase'" at ResolveCancellationTests.swift lines 168 and 238), then passed after the case was added.
    - verification: `swift test --filter 'ResolveCancellationTests|ResolveTests|ResolutionProgressPhasesTests'` ran 29 tests in 3 suites, all passed. Full `swift test` ran 1232 tests in 134 suites and 83 tests in 10 suites, all passed, 0 failures, 0 new warnings. `swift build --package-path IntegrationTests --build-tests` also compiles, so the nested package sees no missing switch arm.
    - discovery: only one `switch` over `Phase` exists in the package. `SlotProgress.State` has its own `failed(String)` and its own switch; it is a different type and the card does not touch it. Slot states are left as they were at the cancel, so a host can still show how far the attempt got.
    - next: ready for `/review`.
  timestamp: 2026-09-07T13:37:59.211297+00:00
depends_on:
- 01M1XWYD9XFBXWGPP11H59152D
position_column: doing
position_ordinal: '80'
title: Add a cancelled phase to ResolutionProgress
---
## What

`ResolutionProgress` has no phase for a cancelled resolve. Add one.

1. `ResolutionProgress.Phase` (Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift:74-85) has the cases `sizing`, `downloading`, `loading`, `ready` and `failed(String)`. The `phase` property is at ResolutionProgress.swift:88.

2. Thus a host that binds to `ResolutionProgress` cannot tell a cancelled resolve from a failed resolve. `failed(String)` shows a diagnostic message for an operation that the user stopped.

3. Add a `cancelled` case to `Phase`. `runResolve` (Sources/FoundationModelsRouter/Router.swift:254) sets `.cancelled` when it throws `CancellationError`, and does not set `.failed`.

4. `Phase` is `public` and `Equatable`. The new case is thus an addition to the public API. Write a doc comment on the case, because a public declaration must have one.

5. Each `switch` over `Phase` in the package must have an arm for the new case. Do not add a `default` arm, because the compiler must find the next missing arm.

## Test shape

- A test cancels a resolve and shows that the phase is `.cancelled` and not `.failed`.
- A test makes a resolve fail and shows that the phase stays `.failed(String)` with its message.
- A test shows that a resolve that completes stays `.ready`.

## Why

FoundationModelsACPAgent card ^54ay5s0 shows the resolve phase to the user in the agent CLI. A cancelled resolve that shows as a failure is wrong: the user made the cancel. This card depends on the cancellation card, because the `.cancelled` phase has no source until `runResolve` obeys the cancel.