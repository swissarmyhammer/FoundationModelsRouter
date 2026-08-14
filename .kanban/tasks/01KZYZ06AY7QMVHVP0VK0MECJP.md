---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzyzkakh8v8nyk55471arq6c
  text: |-
    ### research

    Picked up the card and read the run plane.

    What is there now:
    - `SessionMailbox` holds the run-plane vocabulary as nested internal types: `RunKind`, `RunStatus`, `WaitResult`, `CancelResult`, `ParkResult`, plus the internal constants `terminalDetailTailLimit`, `waitSecondsCeiling`, `settledTerminalEventRetentionLimit`.
    - The internal run-plane methods are `park`, `updateProgress`, `status()`, `wait`, `cancel`, `sweep`.
    - In-package readers of the plane: `RoutedSessionActorCompaction.fold` (`mailbox.status()`), `RoutedSessionActorForking` (`sweep()`), `DetachingTool` (`park`, `updateProgress`), `SessionTreeRestoration` (`SessionMailbox.terminalDetailTailLimit`), `CompactionSegment` (doc link to `RunStatus`), `PendingRunEnvelope` (doc links to `WaitResult`).

    Decisions for one vocabulary, not two:
    1. Move the vocabulary OUT of `SessionMailbox` into a new file `Hosting/RunPlane.swift` as public top-level types: `RunKind`, `ParkedRun`, `WaitOutcome`, `CancelOutcome`. The nested internal names go away, so no name is published twice. `ParkResult` stays nested and internal — it is park-side wiring, not host vocabulary.
    2. `SessionMailbox`'s private bookkeeping struct is also named `ParkedRun` today, so it becomes `ParkedRunEntry`, and its private dictionary becomes `runsByToken` (a method named `parkedRuns()` cannot stand beside a property of the same name).
    3. `status()` becomes `parkedRuns()`, so the mailbox and the host capability use one name for one operation.
    4. `waitSecondsCeiling` and `terminalDetailTailLimit` become public statics on `ToolContext` — one declaration each, and every run-plane member of `SessionMailbox` stays internal. The mailbox and `SessionTreeRestoration` read them from there.

    The `ToolDetachment.wrapping(tool:inheriting:sink:configuration:)` overload reads `context.sessionID` and `context.mailbox` and forwards to the mailbox-taking overload. It is correct. Its committed test drives only the non-String-output (binding-only) route with a fresh mailbox, so it never proves the mailbox forwarding. A second test covers the String-output route: the parked run must settle in the mailbox the inherited context carries, and the run's ambient `sessionID` must be the inherited one.
  timestamp: 2026-08-14T01:53:45.585320+00:00
- actor: claude-code
  id: 01kzz2vkqjq4rjcs9n95r1ahna
  text: |-
    ### implement — changed

    - evidence: 14 files. New: Sources/FoundationModelsRouter/Hosting/RunPlane.swift (public `RunKind`, `ParkedRun`, `WaitOutcome`, `CancelOutcome`), Tests/FoundationModelsRouterTests/Helpers/ParkedRunFixtures.swift (the `RunLatch`/`CancelCounter`/`FakeRun`/`parkFakeRun` scaffolding, lifted out of `SessionMailboxTests` so both run-plane suites share one copy). Changed: Hosting/ToolContext.swift (three capabilities plus the two public bounds), Hosting/SessionMailbox.swift (vocabulary removed, `status()` → `parkedRuns()`, private `ParkedRun` → `ParkedRunEntry`, private `parkedRuns` → `runsByToken`, new Audience paragraph), Hosting/DetachingTool.swift and Compaction/CompactionSegment.swift (doc links), Session/RoutedSessionActorCompaction.swift and Recording/SessionTreeRestoration.swift (call sites), FoundationModelsRouter.docc/RoutedSession.md (third audience), and five test files.
    - test run: one bare `swift test` — 933 tests in 87 suites passed with 1 known issue (the pre-existing `BoundedWait` `withKnownIssue`), plus 27 tests in 11 suites and 24 tests in 5 suites in the other two targets. Exit 0. `swift build --build-tests` clean.
    - new tests: seven in `ToolContextTests` (`parkedRuns()` listing and progress, `wait()` settled / deadline elapsed / unknown token, `cancel()` reported / already settled / unknown token), all against a real `SessionMailbox` holding a fake parked run — no live model. One in `DetachingToolTests` for `ToolDetachment.wrapping(tool:inheriting:sink:configuration:)` over a String-output tool: the run parks in the mailbox the inherited context carries, and its terminal detail is the inherited `sessionID`.
    - TDD: the new tests were written first; `swift build --build-tests` reported the missing members (`'parkedRuns' is inaccessible due to 'private' protection level`) before the implementation landed.
    - note for the review step: `status()` still appears in `CompactionSegment` and `RoutedSessionCompactTests`. That is the model-facing sandbox builtin the compaction boundary text names, not the mailbox method, and `RoutedSessionCompactTests` asserts on that rendered text. It is deliberately unchanged.
    - next: /review
  timestamp: 2026-08-14T02:50:42.802152+00:00
- actor: claude-code
  id: 01m000xa42d1pe1qt3jkabc47h
  text: |
    ### review — findings

    - evidence: `review sha HEAD~1..HEAD` (commit 3aac832). Engine counts: 5 findings, 5 confirmed, 4 refuted, 32 attempted, 0 failed. 1 finding recorded: Tests/FoundationModelsRouterTests/Helpers/ParkedRunFixtures.swift:11.
    - dropped: 4 findings fell under the skill's blanket exception for test code that already existed at HEAD~1 — `eventually(_:)` and the five stubs in SessionMailboxTests.swift, `makeTempDir()` and `makeRouter(container:cacheDir:recorder:)` in SessionOutboxToolWiringTests.swift. `git show HEAD~1` proves each helper predates the commit, so each finding asks to refactor a pre-existing test. The kept finding cites Helpers/ParkedRunFixtures.swift, a file this commit adds, so the exception does not cover it.
    - next: /implement the open finding — remove the third copy of the gate/latch, and leave one canonical version the run-plane suites share.
  timestamp: 2026-08-14T11:35:55.778542+00:00
- actor: claude-code
  id: 01m000y68ntsd8wcr715h7j88b
  text: |-
    ### finish iteration 1 — findings
    - implement: skipped — the work was already committed as 3aac832, and the tree held no code change
    - test: skipped — the implement comment records one bare `swift test`, exit 0
    - commit: 3aac832 (the checkpoint this review scoped to)
    - review: findings — Tests/FoundationModelsRouterTests/Helpers/ParkedRunFixtures.swift:11 (engine: 5 findings, 5 confirmed, 4 refuted; 4 dropped as refactors of tests that already existed)
  timestamp: 2026-08-14T11:36:24.597333+00:00
- actor: claude-code
  id: 01m001fpdyscqnf2xaprvgzk24
  text: |-
    ### finding round 2 — worked the open finding

    The finding named three copies of the gate/latch. A sweep of the whole test target found a FOURTH: `private actor ToolGate` in `SessionOutboxToolWiringTests.swift`. The rule says a finding names one example of a cause and the cause comes out of the whole file, so all three copies went, not the two the finding lists.

    What the four copies were:
    - `Helpers/ParkedRunFixtures.swift` — `actor RunLatch` (the canonical one, kept)
    - `DetachingToolTests.swift` — `private actor ToolGate`, method `waitUntilOpened()`
    - `SessionOutboxToolWiringTests.swift` — `private actor ToolGate`, method `waitUntilOpened()`
    - `RoutedSessionCompactTests.swift` — `private actor RunLatch`, plus a second copy of `parkFakeRun` and its own `parkedRunOp` constant

    What landed:
    - `RunLatch` in `Helpers/ParkedRunFixtures.swift` is the one gate the test target declares. Its doc now names every suite that uses it, and says the body it holds may be a fake parked run OR a gated tool's `call(arguments:)`.
    - `DetachingToolTests` and `SessionOutboxToolWiringTests` dropped their `ToolGate` and call `RunLatch.waitUntilOpen()`. The `ToolGate` open()/waitUntilOpened() body was equivalent to `RunLatch`'s, so no behavior moved; the `let gate:` fixture properties keep their names because the tool fixtures around them are `GatedTool`, `GatedZeroWaitTool` and `GatedSessionIdentityTool`.
    - `RoutedSessionCompactTests` dropped its `RunLatch`, `parkedRunOp` and `parkFakeRun` and now calls the shared `parkFakeRun(on:latch:)` with `FakeRun.op`. Its local copy stamped tool `"fake"`, op `"run task"`, detail `"done"` and canceler outcome `.cancelled` — exactly the shared function's `FakeRun.tool`, `FakeRun.op` and its two defaults — so the fixture is identical.
    - `DetachingToolTests`'s `// MARK: - Sink and gate fixtures` became `// MARK: - Sink fixtures`, because the gate no longer lives there.

    Proof the cause is gone: `sah tool code_context duplication find` over all six run-plane test files (the four changed, plus `SessionMailboxTests` and `ToolContextTests`) reports nothing, one file at a time and all six at once.

    No production source changed — this round touched test scaffolding only.
  timestamp: 2026-08-14T11:45:58.206480+00:00
- actor: claude-code
  id: 01m001fxwk5re4hvg0qncerw31
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterTests/Helpers/ParkedRunFixtures.swift, Tests/FoundationModelsRouterTests/DetachingToolTests.swift, Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift, Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift (64 insertions, 133 deletions). `swift build --build-tests` clean. One bare `swift test`: 933 tests in 87 suites, 27 tests in 11 suites, 24 tests in 5 suites — all passed, exit 0, with the one pre-existing `withKnownIssue` in the BoundedWait suite. `sah tool code_context duplication find` over the six run-plane test files reports nothing.
    - next: /review
  timestamp: 2026-08-14T11:46:05.843919+00:00
position_column: doing
position_ordinal: '80'
title: ToolContext gets the run-plane capabilities a tool host needs
---
## Why

`^j0pp9yp` moved the run plane inside the module. `Hosting/SessionMailbox.swift` now says:

> The run-plane machinery (park, wait, cancel, status, sweep) is internal wiring the detachment engine and the session own.

That audit counted two audiences: the engine and the session. There is a third. `FoundationModelsMultitool` is a **host that shows the run plane to a model**. Its `runCode` sandbox has the `status(completionToken)`, `wait(completionToken, seconds)` and `cancel(completionToken)` builtins, and it mounts a `wait` tool. Those builtins are the product, not internal wiring (`../FoundationModelsMultitool/eventplan.md`, "Elevation" and "The sandbox globals").

The consumer therefore cannot build. It reached the plane through `ToolContext.mailbox`, which is now internal, at 13 sites in `MultiTool+SandboxGlobals.swift`, `WaitTool.swift` and `Invocation/RunBinding.swift`.

**Do not make `SessionMailbox` public again.** The actor is a god object, and a host must never hold one. Add typed capabilities on `ToolContext`, beside the `elicit(_:)` and `progress(_:)` that are already there. The mailbox stays internal, and the host names three operations instead of an actor.

That set is small, and it gets smaller. `FoundationModelsMultitool` is moving to "every mounted call detaches and hands back a `completionToken`". After that move, these three are the **only** reason a host touches the plane: its tests stage a parked run by calling a real tool, not by parking one by hand.

## What to add

Three capabilities on `ToolContext`:

```swift
public func parkedRuns() async -> [ParkedRun]
public func wait(completionToken: String, seconds: Double) async -> WaitOutcome
public func cancel(completionToken: String) async -> CancelOutcome
```

Each forwards to the session mailbox the context already holds. Each carries public vocabulary, because a host renders it:

- `ParkedRun`: `completionToken`, `tool`, `op`, `kind`, `latestProgressDetail` — the five fields the JSON row carries
- `WaitOutcome`: `settled(OperationEvent)`, `deadlineElapsed`, `unknownToken`
- `CancelOutcome`: `reported(OperationOutcome)`, `alreadySettled(OperationEvent)`, `unknownToken`
- `waitSecondsCeiling`, which a host clamps a model-supplied deadline against, and `terminalDetailTailLimit`, which a host asserts its rendered output tail against

Keep the existing internal `RunStatus`/`WaitResult`/`CancelResult` as the internal shape, or rename them into the public vocabulary. Do not publish two names for one thing.

## Also in this change

`ToolDetachment.wrapping(tool:sessionID:mailbox:sink:configuration:)` is public but demands a `SessionMailbox`, which no caller outside this package can obtain. A public function whose arguments nobody can supply is unusable. An out-of-package binder wraps its own inner calls with it (`RunBinding.invoke`, elevation off).

An additive overload and one test are **already in this working tree**, written while diagnosing the break:

```swift
public static func wrapping(
    tool: any Tool,
    inheriting context: ToolContext,
    sink: any OperationEventSink,
    configuration: DetachConfiguration
) -> any Tool
```

Review it, keep it or replace it, and commit it with the rest. It obeys the same rule as the three capabilities above: a host names a context, never a mailbox.

## How it landed

- The run-plane vocabulary moved OUT of `SessionMailbox` into the new `Hosting/RunPlane.swift` as public top-level types: `RunKind`, `ParkedRun`, `WaitOutcome`, `CancelOutcome`. The nested internal names are gone, so no name is published twice. `ParkResult` stays nested and internal — it is park-side wiring, not host vocabulary.
- `SessionMailbox.status()` became `parkedRuns()`, its private bookkeeping struct became `ParkedRunEntry`, and its private dictionary became `runsByToken`. One name for one operation, end to end.
- `waitSecondsCeiling` and `terminalDetailTailLimit` are public statics on `ToolContext`. One declaration each; the mailbox and `SessionTreeRestoration` read them from there, and every run-plane member of `SessionMailbox` stays internal.
- The `inheriting:` overload was reviewed and kept. Its committed test drives only the non-String-output route, so a second test drives the String-output route: the run must park in the mailbox the inherited context carries, and the inner run's ambient `sessionID` must be the inherited one.
- The test target now declares ONE gate: `RunLatch` in `Tests/FoundationModelsRouterTests/Helpers/ParkedRunFixtures.swift`. The `ToolGate` copies in `DetachingToolTests` and `SessionOutboxToolWiringTests`, and the `RunLatch`, `parkedRunOp` and `parkFakeRun` copies in `RoutedSessionCompactTests`, are gone; each suite uses the shared latch, `FakeRun.op` and the shared `parkFakeRun`.

## Acceptance Criteria

- [x] `ToolContext` carries the three capabilities, and every run-plane member of `SessionMailbox` stays internal
- [x] The public vocabulary is one set of names, not two
- [x] `ToolDetachment.wrapping(tool:inheriting:sink:configuration:)` is reviewed and covered by a test
- [x] Unit tests drive each capability with no live model
- [x] The "Audience" paragraph in `Hosting/SessionMailbox.swift` names the host run-plane capability, so the next audit does not close this door again
- [x] `swift build` clean and `swift test` green



## Review Findings (2026-08-14 06:22)

- [x] `Tests/FoundationModelsRouterTests/Helpers/ParkedRunFixtures.swift:11` — The new `RunLatch` actor (lines 11–35) reinvents synchronization logic that already exists elsewhere. `ToolGate` in `DetachingToolTests.swift` (lines 54–70) and `RunLatch` in `RoutedSessionCompactTests.swift` (line 570, per probe evidence) are nearly identical implementations (0.96+ similarity). Rather than creating a third copy, consolidate into one shared version. Remove the duplicate `RunLatch` from ParkedRunFixtures.swift and instead import `ToolGate` from DetachingToolTests.swift, or better: move the canonical implementation to ParkedRunFixtures.swift with a shared name (e.g., `RunLatch` or `Gate`), then update DetachingToolTests.swift and RoutedSessionCompactTests.swift to reuse it. This consolidates the single canonical gate/latch abstraction the comment already promises ('the scaffolding lives in exactly one place'). #eventplan