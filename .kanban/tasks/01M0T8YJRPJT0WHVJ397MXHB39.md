---
comments:
- actor: claude-code
  id: 01m0t9xxwepn7gmas63rws4w3f
  text: |
    Picked up. Research done.

    Where the code stands:
    - `RunKind` is public in `Sources/FoundationModelsRouter/Hosting/RunPlane.swift`. The card is correct: `park(...)`, `ParkResult` and `ToolContext.mailbox` are the internal members, not `RunKind`.
    - `DetachmentParameterProviding` is public in `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift`. It carries three requirements, each with a blanket default in one `extension`.
    - The engine finds the conformer with `wrapped as? any DetachmentParameterProviding` in the private `parameterProvider` property, and reads it through two private readers: `perCallClocks(from:)` and `collectInstruction(forCompletionToken:)`.
    - `detach(...)` parks with the literal `kind: .swiftTask` and an inline cooperative canceler closure.
    - The canceler type the mailbox stores is `@Sendable () async -> OperationOutcome`.

    Plan (matches the card, no deviation):
    - Add `var detachmentRunKind: RunKind { get }`, default `.swiftTask`.
    - Add `func detachmentCanceler(forCompletionToken:) -> (@Sendable () async -> OperationOutcome)?`, default `nil`. The shape mirrors the `detachmentCollectInstruction(forCompletionToken:)` requirement that already exists, and it mirrors `ShellRunner.canceler(completionToken:)` in FoundationModelsMultitool.
    - Read both through two new private readers beside the two that exist, and use them at the park.

    Test plan: a new file beside `DetachedRunTranscriptTests.swift`. Its tools conform to the public protocol only and name no member of the mailbox.
  timestamp: 2026-08-24T16:33:48.430661+00:00
- actor: claude-code
  id: 01m0tad62b4m64wr3nxdxdr1tx
  text: |
    TDD cycle, both halves measured.

    RED, before any source edit: `swift test --filter DeclaredRunKindTests` gave 4 tests, 5 issues, and each failure named the defect this card is about — `parked.kind → .swiftTask` where the tool declared `.process`; `cancel → .reported(.cancelled)` where the tool's canceler reports `.stopped`; the tool's canceler never ran, so `killedTokens` stayed empty; the sweep's terminal carried `.cancelled`. The fourth test — the tool that declares nothing — passed at RED, which is what a regression guard must do.

    GREEN, after the edit: the same 4 tests pass, and the whole suite is 1041 tests in 100 suites plus 83 in 10 suites, 0 failures. The 2 known issues are the pre-existing `withKnownIssue` blocks in `BoundedWaitTests` and `RealModelHarnessTests`, neither of which this change touches.

    What landed:
    - `DetachmentParameterProviding` gained `detachmentRunKind` (default `.swiftTask`) and `detachmentCanceler(forCompletionToken:)` (default `nil`), each with a doc comment that states what its default assumes.
    - `DetachingTool` gained two private readers — `runKind` and `canceler(forCompletionToken:workTask:cancellationFlag:)` — beside the two readers that already existed for the clocks and the collect sentence, and `detach(...)` reads both at the park it already made. The cooperative closure moved into the second reader whole; it did not change.
    - No access level changed anywhere. `park`, `ParkResult` and `ToolContext.mailbox` are each still internal, and `git status` shows no edit to `SessionMailbox.swift` or `ToolContext.swift`.

    Discoveries the next agent should know:
    1. The extra members alone do not make a compile failure. A tool may declare `detachmentRunKind` and `detachmentCanceler(...)` before the protocol carries them: they are simply extra members on the type. So RED here is a RUNTIME failure, not a build failure, and a test that only checked that the code compiles would have proved nothing.
    2. The tool's canceler must not end the run's body. `sweep()` suspends across each canceler, so a canceler that also released the body let the body settle naturally inside that window, and the sweep then handed back the natural `.succeeded` terminal instead of the `.stopped` one. `ParkedRunFixtures.parkFakeRun` already avoids this for `.process` for the same reason. The fixture reports the kill and each test opens the gate itself.
    3. **`swift format` must not run in this repo.** The instruction for this run said to run `swift format -i -r Sources Tests`. I ran it and measured the result: it rewrote 244 files, because swift-format defaults to 2-space indentation and this repo is 4-space, there is no `.swift-format` config, and `.github/workflows/ci.yml` has no format step. `.kanban/tasks/01M0ACT92Z0MHCACREGW1CZ46M.md:324` states the rule word for word — "Never run `swift format` or `swiftformat` in this repository" — and several other cards record the same measurement. I reverted the whole reformat with `git checkout -- Sources Tests`, which also reverted my own edits, and re-applied them by hand in the repo's 4-space style. The final `git status` carries 2 modified files and 2 new files, and no unrelated churn.
    4. `ElicitationRoutingTests` held a private two-line `DiscardingSink`, and this card needed the same sink. Rather than write a third copy, that no-op moved to `Tests/FoundationModelsRouterTests/Helpers/DiscardingOperationEventSink.swift` and both suites of that target now use it. The copy in `IntegrationTests` stays where it is, and its own doc comment states why: SwiftPM forbids a target from depending on a test target, so the two modules cannot share test code at all.
  timestamp: 2026-08-24T16:42:08.331856+00:00
- actor: claude-code
  id: 01m0tadexm7eg4dfws94r2qxs2
  text: |
    ### implement — changed
    - evidence: 4 files — `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift` (modified: two new public protocol requirements with blanket defaults, two new private readers, the park now reads both), `Tests/FoundationModelsRouterTests/DeclaredRunKindTests.swift` (new, 4 tests), `Tests/FoundationModelsRouterTests/Helpers/DiscardingOperationEventSink.swift` (new), `Tests/FoundationModelsRouterTests/ElicitationRoutingTests.swift` (modified: its private no-op sink now comes from the shared helper). `swift test`: 1041 tests in 100 suites + 83 tests in 10 suites, 0 failures, 2 pre-existing known issues, no new warning. Every acceptance-criteria and test checkbox on the card is checked and met.
    - next: `/review`
  timestamp: 2026-08-24T16:42:17.396502+00:00
- actor: claude-code
  id: 01m0tanza9pm71f6b645kknkpk
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 8260def) — 0 findings, 0 confirmed, 0 refuted, 7 validator passes attempted, 0 failed. 4 files reviewed; 2 `.kanban/` files excluded by `.reviewignore`.
    - next: task moved to done. No prior findings sections; nothing open.
  timestamp: 2026-08-24T16:46:56.329044+00:00
- actor: claude-code
  id: 01m0tapfg2mjypmwx9pp7hdfgv
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files (Sources/FoundationModelsRouter/Hosting/DetachingTool.swift, Tests/FoundationModelsRouterTests/DeclaredRunKindTests.swift new, Tests/FoundationModelsRouterTests/Helpers/DiscardingOperationEventSink.swift new, Tests/FoundationModelsRouterTests/ElicitationRoutingTests.swift)
    - test: green — swift test, 83 tests in 10 suites, 0 failed, 0 warnings, 0 skipped
    - commit: 8260def
    - review: clean — zero findings, scope HEAD~1..HEAD; task moved to done
  timestamp: 2026-08-24T16:47:12.898611+00:00
position_column: done
position_ordinal: fff180
title: Let a tool declare its RunKind and supply its own canceler
---
## What

`RunKind.process` is public vocabulary with no public way to select it. A
capability outside this module can read the run plane, but each run it parks is
`.swiftTask` with the cooperative canceler of the engine, which reports
`.cancelled`. Thus a shell capability cannot park a run that reports the truth.

`RunPlane.swift:4-9` states the intent that is not yet reachable: *"Router owns
the vocabulary and none of the machinery: each kind's canceler comes from the
capability that started the run, so the router never spawns a process and never
signals one."* Today no capability can give that canceler.

**Measured, and not reasoned.** A probe in FoundationModelsMultitool that calls
`mailbox.park(kind: RunKind.process, ...)` does not compile. The compiler
answers:

```
error: 'park' is inaccessible due to 'internal' protection level
```

Each other name resolves — `RunKind.process`, the canceler type,
`context.completionToken`. The probe was removed after the measurement.

### Do NOT publish the run plane

`SessionMailbox.swift:44-46` records a decision: *"The run-plane machinery
(park, wait, cancel, parked-run listing, sweep) is internal wiring the
detachment engine and the session own, and it stays internal"*, and `:60-61`:
*"no host ever needs to hold this actor, and no run-plane member of it needs to
be published."* That decision stands. This card does not ask to reverse it.
`park`, `ParkResult` and `ToolContext.mailbox` each stay internal.

### The design: extend the public seam that already exists

`DetachmentParameterProviding` (`DetachingTool.swift:23`, public) is the hook a
tool already uses to declare its own detachment behaviour. The engine finds it
by an existential cast at `DetachingTool.swift:739-740`, and each of its three
requirements carries a blanket default at `:87-111`. Two more requirements of
the same shape answer this card:

- A run kind the tool declares. The default is `.swiftTask`, thus each tool that
  exists keeps its behaviour with no edit.
- A canceler the tool supplies for its own run. The default is `nil`, which
  means "use the cooperative canceler of the engine".

`DetachingTool.detach(...)` (`:781`) then reads both at the park it already
makes (`:802-815`), in place of the literal `.swiftTask` at `:805` and the
inline closure at `:808-814`.

This matches the house style of the package on each point: a conformance and
not a stored closure property, discovery by `as? any P`, a default for each
requirement, and no associated type, so the existential cast holds.
`ForkableTool` (`ForkableTool.swift:19`) and `DetachmentParameterProviding`
itself are the two precedents.

### The contract the canceler must keep

`RunPlane.swift:17-20`, `OperationOutcome.swift:14-16` and
`SessionMailbox.swift:339-341` each state it: a `.process` run dies by
`killpg(SIGKILL)`, which is authoritative, thus its canceler reports `.stopped`
and never `.cancelled`. `.stopped` means the work is certainly dead; `.cancelled`
means a request only. Do not flatten the two.

## Acceptance Criteria

- [x] A tool outside the FoundationModelsRouter module declares `.process` as
      its run kind, and the run parks under that kind.
- [x] A tool outside the module supplies its own canceler, and a cancel of that
      run reports `CancelOutcome.reported(.stopped)`.
- [x] `ToolContext.parkedRuns()` lists the run with `kind == .process`.
- [x] `park`, `ParkResult` and `ToolContext.mailbox` each stay internal. The
      access level of none of them changes.
- [x] Each tool that exists keeps its behaviour with no edit: with no
      declaration the kind is `.swiftTask` and the canceler stays the
      cooperative one of the engine, which reports `.cancelled`.
- [x] Each new requirement carries a default and a doc comment that states what
      the default assumes.

## Tests

- [x] New cases in
      `Tests/FoundationModelsRouterTests/DetachedRunTranscriptTests.swift`, or a
      new file beside it.
- [x] A test declares a tool with `.process` and a canceler that reports
      `.stopped`, detaches it, and asserts `parkedRuns()` gives `kind ==
      .process`.
- [x] A test cancels that run and asserts `CancelOutcome.reported(.stopped)`.
- [x] A test asserts a tool that declares nothing still parks as `.swiftTask`
      and still reports `.cancelled` — the behaviour that exists does not
      change.
- [x] A test asserts the session-end sweep reaches a `.process` run and calls
      its canceler.
- [x] `swift test` passes with no new failure and no new warning.

## Who waits for this

FoundationModelsMultitool, on its own board:

- `^bwv86sy` — "Add the tools.shell.execute verb". STUCK on this card. It parks
  a detached shell run.
- `^1hq8xny` — "Kill shell process groups in the session-end sweep". The same
  seam.
- `^xgnygf8` and `^zpdk266` wait behind `^bwv86sy`, and `^wcnkm9b` behind those.

`ShellRunner.canceler(completionToken:)` in that package is written and tested
already. It reads the process group from its store, sends `killpg(SIGKILL)`, and
returns `.stopped`. It needs only a way to reach the park.

## Correction of the record

The notes of `^j0pp9yp` say `RunKind` went internal. The code at
`RunPlane.swift:10` is `public enum RunKind`. What went internal is `park(...)`,
`ParkResult` and `ToolContext.mailbox`. Trust the source.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #eventplan #phase-2