---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3m9rczsy2wwzh2zsj679vfh
  text: |-
    ### Research (implement, iteration 1)

    - The Extras checkout is at 4a733cd. `Package.resolved` is ignored by git and `Package.swift` follows `branch: "main"`, so the resolved revision is the pin. This repository has no pin line to change.
    - Extras: `ToolMounting.call(_:arguments:site:mount:)` asks `BackgroundTool.mount(for:)` for each call. A background call runs `BackgroundToolRunner` on `site.postingToSession`, so the funnel of EACH background run (top-level or nested) posts its terminal to the SESSION sink under its own token. `ToolContext.mount(_:op:as:)` makes a site whose `sessionSink` is the sink of the session.
    - Router: `makeSessionMounted` makes `MountSite(sessionID:runPlane:sink:)`; that init sets `sessionSink = sink` = the `SessionOutbox`. Thus a nested background run posts its terminal to the outbox: `post(event:)` stages it one time, journals it (claim), and wakes the pump. `deliver(settledTerminal:)` then journals only (the claim refuses the second write) and wakes the pump.
    - Expectation from the code: the nested terminal is already staged one time and starts a submission. The session tests will prove it or show the defect.
    - `OperationTool` (Extras `Operations` product) is a `BackgroundTool`; `mount(for:)` gives the mount of the called operation, `.synchronous` for an unknown operation. The router test target does not depend on `Operations` yet; the tests will add that product to the test target only.
  timestamp: 2026-09-28T15:22:26.169252+00:00
- actor: claude-code
  id: 01m3manr4wmctv8qqds1fq458h
  text: |-
    ### Implementation record (implement, iteration 1)

    **Result of the failing-test-first step:** the router already stages the terminal of each settled background run one time, also for a nested run. The new session tests passed on their first run with NO source change. Reason: the Extras mount layer (4a733cd) runs each background call on `site.postingToSession`, so the funnel of each run posts its terminal to the session sink (the `SessionOutbox`). `SessionOutbox.post(event:)` stages it and wakes the pump. `deliver(settledTerminal:)` only journals, and `claimJournalWrite(for:)` refuses that second write. Thus the router change is the tests only, plus one corrected doc comment. No fallback staging was added: no public path starts a background run without a funnel, so that code would be dead.

    **Proof that the tests can fail:** a temporary mutation changed `deliver(settledTerminal:)` from `journalWithoutStaging` to `post(event:)` (stage two times). Then 3 of the 4 new tests failed on `PerCallMountSessionTests.swift:216` (each terminal line must be in the prompts one time). The mutation was reverted; `git diff` of Sources shows only the doc comment.

    **Files**
    - `Tests/FoundationModelsRouterTests/PerCallMountSessionTests.swift` (new, 4 tests): synchronous call in band while the body is held (the run plane has no run) and longer than `inlineSettleGrace`; background call returns a pending envelope when the body ends at once, and its terminal starts one delivery submission; `OperationTool` with `start agent` (background) and `list agents`, `check agent`, `cancel agent` (synchronous); nested `ToolContext.mount(_:op:as: .background)` from a synchronous call gives a token, its terminal is journaled one time and starts one delivery submission. Each background test counts the terminal line over all prompts (one time), checks that exactly 2 prompts came and that the outbox is empty.
    - `Tests/FoundationModelsRouterTests/Helpers/MountCallingBackendFixtures.swift` (new): `MountCallingBackend` (the first submission calls the composed, model-facing tools by name with JSON arguments) and `MountCallingLLMContainer`.
    - `Tests/FoundationModelsRouterTests/Helpers/AgentOperationFixtures.swift` (new): the four `@Operation` fixtures and the `OperationTool`. This file imports `Operations` and not the router module, because both modules declare a `ToolMount` alias.
    - `Package.swift`: the unit test target links `.product(name: "Operations", package: "FoundationModelsExtras")`. The router target does not.
    - `Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift`: doc comment of `deliver(settledTerminal:)` only. It said "top-level run"; now it states that a nested background run has a funnel too.

    **Verification so far**
    - `swift test --skip-build --filter PerCallMountSessionTests`: "Test run with 4 tests in 1 suite passed".
    - Clean build in a new scratch path (`swift build --build-tests --scratch-path <scratchpad>/clean-scratch`): "Build complete! (121.50 sec)", zero warnings from this package; only the 4 vendored mlx-swift C++ warnings and the known mlx bundle "missing creator" warning.
    - `swift build --build-tests --package-path IntegrationTests`: "Build complete!".
    - A loop in another terminal (s006) runs `swift-test --filter ExtrasNameClash --parallel --num-workers 8` again and again in the same `.build`. It is not from this session. `swift package clean` in `.build` was therefore not a clean build; the separate scratch path was used.

    **Not done, by direction:** the card asks for 20 repeated parallel runs of the background-run and cancellation tests. The orchestrator for this run says "Do not run loops of repeated runs" (the same user decision is recorded on ^nxke7g0). The full `swift test` runs one time in the test step.
  timestamp: 2026-09-28T15:38:27.868459+00:00
- actor: claude-code
  id: 01m3mantj240t295d343rsaqpt
  text: |-
    ### implement — changed
    - evidence: 5 files — Package.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift (doc comment only), Tests/FoundationModelsRouterTests/PerCallMountSessionTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/MountCallingBackendFixtures.swift (new), Tests/FoundationModelsRouterTests/Helpers/AgentOperationFixtures.swift (new). `swift test --skip-build --filter PerCallMountSessionTests`: 4 tests in 1 suite passed. Clean build: zero warnings from this package.
    - next: test
  timestamp: 2026-09-28T15:38:30.338191+00:00
- actor: claude-code
  id: 01m3maqwswan4h0tp1zaxf17c4
  text: |-
    ### test — green
    - evidence: `swift test` (one full run), exit 0: "Test run with 1356 tests in 170 suites passed ... with 2 known issues" (1352 before + 4 new; the 2 known issues are the planned `withKnownIssue` checks in RealModelHarness and BoundedWait, the same as before), "17 tests in 8 suites passed", "19 tests in 3 suites passed", XCTest "Executed 0 tests" three times. No failure, no skipped test. The only warning is the known mlx bundle "missing creator" warning. SessionOutboxToolWiringTests, RespondRunPlaneDrainTests, BackgroundRunTranscriptTests and PendingEventInjectionTests are not changed and pass.
    - next: commit
  timestamp: 2026-09-28T15:39:38.172783+00:00
depends_on:
- 01M3FPCADD0GTFAV2RANXKE7G0
position_column: doing
position_ordinal: '80'
title: 'Router: a background run that a synchronous call starts delivers its terminal as mail, and each call chooses its mount'
---
## What
User direction (2026-09-27, relayed from the FoundationModelsAgents session): a tool chooses background or synchronous for EACH CALL, not for the whole tool. "list, check, cancel operations should be synchronous, meaning in their implementation you do not return until you get results. YOU have the choice to return a background token or not." FoundationModelsAgents task ^ggpyaem waits for this: its `agents` `OperationTool` has `start agent` (background: returns a token, and its result comes back as mail that starts the next submission) and `list agents`, `check agent`, `cancel agent` (synchronous: return the real result in-band).

Blocked by Extras tasks 01M3HMSR0XDGD54R903GZHCJP3 (^gzhcjp3) and 01M3HMSWFHGNG82AS532BY8WVB (^2by8wvb), which must be on Extras `main`: `BackgroundTool.mount(for arguments: GeneratedContent) -> ToolMount` (default `mount`), which `ToolMounting` asks for each call; an operation of an `OperationTool` declares its own mount; and a `ToolContext.mount(_:op:as: .background)` from inside a synchronous call posts its terminal to the sink as staged mail. Depends on router task 01M3FPCADD0GTFAV2RANXKE7G0 (the router uses the Extras tool hosting).

Final Extras API (Extras session, 2026-09-27; local commits, to be pushed): `BackgroundTool.mount(for arguments: GeneratedContent) -> ToolMount?`, where `nil` means the host mount; `ToolMounting.call` is the one decision point. `@Operation(verb:noun:description:mount:)` declares a mount for each operation (default `ToolMount.synchronous`); `OperationTool` is a `BackgroundTool` and chooses the mount of the called operation; an unknown operation runs synchronously. BREAKING: an `OperationTool` mounted as background now runs each call synchronously unless its operation declares `mount: ToolMount(mode: .background)`. `Operations` re-exports `ToolMount`. A nested background mount from `ToolContext.mount` posts its terminal to the session sink under its own token. The same Extras commits fix a FIFO defect in `GenerationQueue` (a later submitter could run before a job that was already counted). Update `Package.resolved` to the pushed Extras head for this task.

Router part:
- Today `RoutedSessionActor.deliver(settledTerminal:)` (`Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift:107`) only journals a settled terminal (`journalWithoutStaging`), because the funnel of a top-level background run stages its own copy. A background run that a synchronous call starts through `ToolContext.mount(... as: .background)` has no funnel of its own, so its terminal is never staged and never starts a submission. Make each settled background run's terminal staged one time: staged by its funnel, or by the settlement when no funnel staged it. Keep the rule that a terminal is not staged two times (`claimJournalWrite(for:)`), and keep the per-event hold (`SessionOutbox.PendingEvent.isHeld`).
- Only the terminal of a settled BACKGROUND run starts a submission by itself (`SessionOutbox.takeSubmissionBatch(deliveringRunsOf:)`). Keep that rule.
- Update the Extras pin to the commit of the Extras task.

## Acceptance Criteria
- [ ] Through a `RoutedSession`: a tool whose `mount(for:)` gives synchronous for one call returns its real output in-band, also when the call takes longer than `inlineSettleGrace`.
- [ ] Through a `RoutedSession`: a call that gets `.background` returns a pending envelope, also when it ends at once, and its terminal starts the next submission as mail.
- [ ] Through a `RoutedSession`: an `OperationTool` with one background operation and three synchronous operations behaves as above for each operation.
- [ ] A `ToolContext.mount(... as: .background)` from inside a synchronous call gives a token; its terminal is staged one time and starts a submission.
- [ ] No terminal is staged two times.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Add session tests in `Tests/FoundationModelsRouterTests/` for each criterion, with a scripted backend and real signals (no wall clock).
- [ ] The current background-run and outbox tests (`SessionOutboxToolWiringTests`, `RespondRunPlaneDrainTests`, `BackgroundRunTranscriptTests`, `PendingEventInjectionTests`) pass with no change to what they assert.
- [ ] Run the background-run and cancellation tests with parallel repetitions (`--parallel --num-workers 8`, 20 times); all runs pass.
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #cross-repo #hosting