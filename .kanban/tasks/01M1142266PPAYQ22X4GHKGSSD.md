---
comments:
- actor: claude-code
  id: 01m11j7gny0rf4jhbjwwbdzj6s
  text: |-
    Picked up. Research done.

    Findings:
    - `ToolRun.inBandFacts(for:)` in `Sources/FoundationModelsRouter/Hosting/ToolRun.swift` holds the three mappings: `CancellationError` -> `.cancelled`, `ToolMountError.timedOut` -> `.timedOut`, else `.failed`. This is the one place to add the `.lost` branch.
    - `terminalFacts(for:stoppedAs:)` sits above it: an authoritative stop outcome replaces the in-band one and keeps the in-band detail. The new branch goes in `inBandFacts`, so a stop still wins.
    - Both `BackgroundToolRunner` and `RunToCompletionRunner` call `ToolRun.execute(arguments:)`, so one branch serves both. `RunToCompletionRunner.call` ends with `try settlement.result.get()`, so the error still reaches the caller unchanged.
    - No `ARCHITECTURE.md` and no `eventplan.md` in this repository; the plan text is quoted on the card.
    - Test fixtures: `MountFixtures` in `Tests/FoundationModelsRouterTests/Helpers/ToolMountFixtures.swift` supplies `backgroundHarness`, `runToCompletionHarness`, `decodeEnvelope` and `settledTerminal`. The new suite reuses them and adds only the two probe tools it needs.
  timestamp: 2026-08-27T12:13:32.222793+00:00
- actor: claude-code
  id: 01m11jh9hjvvqpcx87x1d14rr5
  text: |-
    Implementation landed, by `/tdd`.

    RED: wrote `Tests/FoundationModelsRouterTests/LostRunErrorTests.swift` first. `swift test --filter LostRunErrorTests` broke the build with "cannot find type 'LostRunError'", which is the missing feature and not a typo.

    GREEN: added `Sources/FoundationModelsRouter/Hosting/LostRunError.swift` and one branch in `ToolRun.inBandFacts(for:)`, directly above the `.failed` fallback. The order is now cancellation, timeout, lost, failed. `swift build` succeeds and the four tests of the suite pass.

    The suite holds four tests, not three. The card's Tests section names three; acceptance criterion 2 asks for a fourth — a run-to-completion call must still hand the error to its caller — so the suite carries that case as well.

    Discovery: the full `swift test` run of this repository has a pre-existing timing flake, and it is NOT this change.
    - With the change: 1065 tests, 1 failure — `GenerationStallDiagnosticTests` "a streaming turn reports the stall against the fragments it counted", which times out in `BoundedWait.swift:114`.
    - The change was then taken off the tree whole (the two new files moved aside, `git checkout` on `ToolRun.swift`) and the full suite run again: 1061 tests, the SAME one failure. So the clean tree fails the same way.
    - The same test passes alone in 0.083 s (`swift test --filter GenerationStallDiagnosticTests`), against 6.7 s under the full parallel run, so it is load-sensitive.
    - One earlier run also failed `HumanWaitGateTests` "a human wait overlapping a turn it is not part of leaves the gate at exactly one permit" at the same `BoundedWait.swift:114`. The failing set moves from run to run.
    - The fix belongs to those two test files, which existed before this task, so it is out of scope here.

    The change cannot reach either test: the new branch fires only for an error that conforms to `LostRunError`, and nothing in the repository conforms to it apart from the private probe type in the new suite.
  timestamp: 2026-08-27T12:18:52.594780+00:00
- actor: claude-code
  id: 01m11jhf1znsbv3w7mkhq6c3e8
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Hosting/LostRunError.swift (new), Sources/FoundationModelsRouter/Hosting/ToolRun.swift (one `.lost` branch in `inBandFacts(for:)`), Tests/FoundationModelsRouterTests/LostRunErrorTests.swift (new, 4 tests). `swift build` succeeds; `swift test --filter LostRunErrorTests` passes 4 of 4.
    - next: review. One open item stands on the card: the full `swift test` carries a pre-existing flake in `GenerationStallDiagnosticTests`, reproduced on the unmodified tree.
  timestamp: 2026-08-27T12:18:58.239252+00:00
position_column: doing
position_ordinal: '80'
title: Map a transport-drop error to OperationOutcome.lost (LostRunError)
---
## What
`OperationOutcome.lost` exists, and nothing produces it. `Sources/FoundationModelsRouter/Hosting/ToolRun.swift` maps a thrown error three ways: `CancellationError` → `.cancelled`, `ToolMountError.timedOut` → `.timedOut`, all else → `.failed`. eventplan.md § "Background tools and the completion token" states: "A transport drop is `.lost`" and "This is the only place where `.lost` appears outside an MCP transport drop." MultiTool's MCP capability (phase 4, task `w7vk7sv` on the FoundationModelsMultitool board) throws a transport-drop error from `MCPServer.call`, and the engine must report it as `.lost`, not `.failed`.

Add a marker protocol in `Sources/FoundationModelsRouter/Hosting/LostRunError.swift`:

```swift
/// An error that means the work is gone with no observer: a transport dropped under an in-flight request. The run plane reports it as ``OperationOutcome/lost``.
public protocol LostRunError: Error {}
```

In `ToolRun.swift`, add one branch before the `.failed` fallback: `if error is any LostRunError { return (.lost, String(describing: error)) }`. Keep the order: cancellation, timeout, lost, failed.

## Acceptance Criteria
- [x] A background run whose body throws an error that conforms to `LostRunError` settles with `OperationOutcome.lost`, and the terminal event's `detail` carries the error description.
- [x] A run-to-completion call that throws such an error still throws it to the caller (the mapping is the engine's, not the call's).
- [x] The three existing mappings are unchanged.
- [x] `swift build` succeeds.

## Tests
- [x] Add `Tests/FoundationModelsRouterTests/LostRunErrorTests.swift`: a probe tool throws a `LostRunError`; the mailbox's terminal event is `.lost`. A second case throws a plain error and settles `.failed`. A third throws `CancellationError` and settles `.cancelled`.
- [x] `swift test --filter LostRunErrorTests` passes.
- [ ] Full `swift test` in Router passes. One test fails: `GenerationStallDiagnosticTests` "a streaming turn reports the stall against the fragments it counted". It fails the same way on the unmodified tree, so it is not this change. See the comments.

## Workflow
- Use `/tdd` — write the three-outcome test first, then add the protocol and the branch. #eventplan #multitool-phase-4