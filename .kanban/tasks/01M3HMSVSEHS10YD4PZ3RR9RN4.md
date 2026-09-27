---
assignees:
- claude-code
depends_on:
- 01M3FPCADD0GTFAV2RANXKE7G0
position_column: todo
position_ordinal: a580
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