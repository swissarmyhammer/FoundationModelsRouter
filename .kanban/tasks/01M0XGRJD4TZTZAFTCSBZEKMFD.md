---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0y27hvzkhdmmak6mkhegxgk
  text: |-
    Picked up. Research done.

    Discovery on the RED step: a test "a background body that completes instantly still returns the envelope" does not go red against the old `DetachingTool` by timing. The old defect window is between the work task start and `funnel.markDetached`, which is less than one actor hop. A body that returns at once, and a body that reads `mailbox.backgroundRuns()` at its start, both lose that race in every run (3 runs each). The defect is structural, not reproducible by schedule. The test keeps the strong form of the contract: the run is tracked in the mailbox before the body runs, so the body can never settle first. The new `BackgroundTool` makes this true by construction: it tracks the run, then releases the body through a start gate.

    Plan for the split (all in Sources/FoundationModelsRouter/Hosting/):
    - `RunToCompletionTool.swift`: runs the body in band, optional timeout -> `DetachingToolError.timedOut`.
    - `BackgroundTool.swift`: posts the handle, tracks the run, releases the body, returns the envelope on every call.
    - `ToolRun.swift`: the shared per-call correlation and body (funnel, flag, timeout watcher, terminal facts).
    - `DetachConfiguration.swift`, `PendingRunEnvelope.swift`, `ToolDetachment.swift`, `ContextBindingTool.swift`: the public types that stay, moved out of the old engine file.
    - `DetachingTool.swift` deleted. `DetachingToolError`, `DetachConfiguration`, `DetachmentParameterProviding`, `ToolDetachment` keep their names: the card asks for no "detach" in NEW names only, and the sibling repo documents `DetachingToolError`.
  timestamp: 2026-08-26T03:36:12.927613+00:00
- actor: claude-code
  id: 01m0y2rj7sdmvgxwgmv8cj4m7v
  text: |-
    Implementation landed in Sources (build: 0 errors, 0 warnings from our code):
    - `Hosting/RunToCompletionTool.swift` (91 lines) and `Hosting/BackgroundTool.swift` (158 lines) replace the 1,570-line `DetachingTool.swift`, which is deleted.
    - `Hosting/ToolRun.swift` (367 lines) holds the shared per-call body: token, flag, funnel, context, invocation records, the natural-settlement-versus-timeout race, and `RunEventFunnel`. The funnel lost `Phase`, `hasTimedOut`, `beginTimeout()`, and `markDetached(postingIfSilent:)` — the claim arbitration is gone.
    - `BackgroundTool.call` order: open record, synthesized progress through the funnel, start the work task behind a `RaceGate<Void>` start gate, `mailbox.track(...)`, release the gate, return the envelope. The body cannot settle before the mailbox knows the run, so every call returns the envelope.
    - `DetachConfiguration.swift`, `PendingRunEnvelope.swift` (new `next` text), `ToolDetachment.swift` (the factory picks the type from the declared mount), `ContextBindingTool.swift`: moved out, docs cut to 1-5 lines per member.
    - Doc-only `waitSeconds` mentions removed (RaceGate, ToolContext, SessionMailbox); `rg waitSeconds Sources` is empty. All `DetachingTool` prose mentions in Sources now name the new types.

    Tests: `DetachingToolTests.swift` split into `PendingRunEnvelopeTests`, `RunToCompletionToolTests`, `BackgroundToolTests`, `ToolDetachmentTests`, with the fixtures in `Helpers/ToolMountFixtures.swift`. The two funnel claim tests are deleted with the arbitration. Wiring suites cast to the new types; `detachAtOnceMount`-style fixtures simplified.
  timestamp: 2026-08-26T03:45:30.361885+00:00
- actor: claude-code
  id: 01m0y2vdrbkqasj6wavbzzjgt3
  text: |-
    ### implement — changed
    - evidence: new Sources/FoundationModelsRouter/Hosting/{RunToCompletionTool.swift (91 lines), BackgroundTool.swift (158 lines), ToolRun.swift (367), DetachConfiguration.swift (156), PendingRunEnvelope.swift (135), ToolDetachment.swift (105), ContextBindingTool.swift (106)}; deleted Hosting/DetachingTool.swift (1,570 lines). New tests: BackgroundToolTests, RunToCompletionToolTests, ToolDetachmentTests, PendingRunEnvelopeTests, Helpers/ToolMountFixtures.swift; deleted DetachingToolTests.swift. 14 wiring/helper test files and 14 Sources doc sites updated. `rg waitSeconds Sources` = no match. `swift build --build-tests`: 0 errors, 0 warnings from our code. `swift test`: 1047 tests in 104 suites passed + 83 in 10 suites passed; the 2 known issues are pre-existing `withKnownIssue` cases in RealModelHarness and BoundedWait. New suites (40 tests) passed 3 of 3 repeat runs.
    - next: /review. Note for the follow-up task: ../FoundationModelsMultitool still names `DetachingTool` and was not edited.
  timestamp: 2026-08-26T03:47:04.075235+00:00
- actor: claude-code
  id: 01m0y57g8p3eq4zt4q78n5pjkr
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (local) — 42 checks attempted, 0 findings, 0 confirmed, 2 refuted. All prior checklist items are checked.
    - next: none. The task is in done.
  timestamp: 2026-08-26T04:28:37.014133+00:00
- actor: claude-code
  id: 01m0y57wev5rj91k5pesppyabp
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — DetachingTool.swift (1,570 lines) deleted; BackgroundTool (158) + RunToCompletionTool (91) + shared ToolRun (367); tests split into four suites
    - test: green — swift test, 1047 + 83 tests, 0 failed (run inside implement)
    - commit: 42d23b2
    - review: clean — 43 files, 42 checks, 0 findings, 2 refuted; task moved to done
  timestamp: 2026-08-26T04:28:49.499154+00:00
depends_on:
- 01M0XGQCF19BT6PM14919C9VV4
- 01M0XH9NMH6DYRNZDR06858XAS
position_column: done
position_ordinal: fff680
title: Split the engine into two small wrappers; a background call always returns the handle
---
## What
`DetachingTool.swift` is ~1,600 lines because one type multiplexes two behaviors through a timing race. Replace it with two small, single-purpose types in `Sources/FoundationModelsRouter/Hosting/` (background vocabulary, no "detach" in new names):

- [x] `RunToCompletionTool` (thin): runs the wrapped tool's body, returns its value. `timeout` expiry throws one named error to the model. Owns correlation and event plumbing, nothing else.
- [x] `BackgroundTool`: `call(arguments:)` starts the body, tracks the run in `SessionMailbox` at once (`track(tool:op:kind:completionToken:settling:canceler:)`), and returns the `PendingRunEnvelope` immediately — on every call, also when the body completes in microseconds. Keeps: the timeout watcher (progress resets it, elicitation suspends it, expiry cancels and settles as `timedOut`), the canceler with `RunKind` honesty, and exactly one terminal event per run. Uses the generation-permit rule from task ^6858xas.
- [x] Delete the soft-deadline race and its claim arbitration (the `RaceGate` window use at the old `DetachingTool.swift:1001` area). Keep the natural-settlement-versus-timeout arbitration — that race is real.
- [x] Rewrite the `PendingRunEnvelope` `next` text: the run continues in the background; the session reports the result when the run settles; `wait` with the `completionToken` collects it earlier.
- [x] Keep `PendingRunEnvelope`, `SessionMailbox`, `ToolContext`, and the journal contract unchanged in shape — only their callers change. Update the doc-only `waitSeconds` mentions in `Concurrency/RaceGate.swift:16`, `Hosting/ToolContext.swift:45`, `Hosting/SessionMailbox.swift:309`.

## Acceptance Criteria
- [x] A background tool call returns a `PendingRunEnvelope` on every call. A test proves it, with a body that completes instantly.
- [x] `rg 'waitSeconds' Sources` returns no match at all.
- [x] The exactly-one-terminal-event invariant holds across natural settle, cancel, timeout, and `close()` sweep — existing tests stay green.
- [x] The two new files together are far smaller than the old engine; the old `DetachingTool` type is gone.
- [x] `swift build --build-tests` and the full suite are green.

## Tests
- [x] Rewrite the race cases in `Tests/FoundationModelsRouterTests/DetachingToolTests.swift` as immediate-handle cases; split the file to match the two new types.
- [x] Simplify fixtures that used `waitSeconds: 0` (`detachAtOnceMount` in `DeclaredRunKindTests.swift`, `RegisteredJournalOpTests.swift`) — background mode now does this always.
- [x] Run `swift test` — green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.