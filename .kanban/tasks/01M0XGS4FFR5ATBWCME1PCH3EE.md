---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0y7mdf3yk07fz4nx2a2wark
  text: |-
    Research: at HEAD b3c9d3c the Hosting/ engine files (BackgroundTool, RunToCompletionTool, ToolRun, ToolDetachment, DetachConfiguration, SessionMailbox, ToolContext, PendingRunEnvelope) hold no text that narrates the removed race. `rg -i 'waitSeconds|soft deadline|two clocks|outlives the window|detaches at'` in Hosting/ returns no match. `PendingRunEnvelope.defaultCollectInstruction` already states the push contract ("The session reports the result when the run settles"), so its test assertions did not need a change.

    Stale text found and changed:
    - eventplan/Elevation citations: RoutedLLM.swift (makeSessionToolWiring doc), RoutedSessionActorTurnExecution.swift (runCancellableModelCall comment), Recording/SessionTreeRestoration.swift (crash-edge comment).
    - "safety net" drain narration: RoutedSession.swift (respond doc) and RoutedSessionActorGeneration.swift (respond doc). Both now say the drain is the usual path and the model does not poll; `wait` is an earlier look.
    - "call status() for the live view": CompactionSegment.swift (PendingRunSummary doc, renderedPendingRuns doc and string, boundaryEntry comment) and RoutedSessionActorCompaction.swift (fold comment).
    - RoutedSession.md: new "Long-running tools" section that states the contract. README.md has no text on this subject; no change.

    TDD: RoutedSessionCompactTests "compact() with a background run ..." now asserts the rendering contains "The session reports each run when it settles" and not "live view". Watched it fail (2 issues) before the string change, then pass.
  timestamp: 2026-08-26T05:10:37.283440+00:00
- actor: claude-code
  id: 01m0y7mrsnfwyfnp0kyj4zc8n4
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md, Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift. Gate 1: `rg -i 'waitSeconds|soft deadline|two clocks|eventplan|elevat' Sources README.md` -> no match (exit 1). Gate 2: `rg 'call status' Sources` -> one hit, CompactionSegment.swift renderedPendingRuns, in a string that first states "The session reports each run when it settles". `swift build --build-tests` -> Build complete, 0 errors, 0 warnings from our code (one build-system warning about the mlx bundle, not our code). `swift test` -> 1056 tests in 104 suites passed with 2 known issues (pre-existing withKnownIssue), plus 83 tests in 10 suites passed.
    - next: /review
  timestamp: 2026-08-26T05:10:48.885339+00:00
depends_on:
- 01M0XGRJD4TZTZAFTCSBZEKMFD
position_column: doing
position_ordinal: '80'
title: Purge dual-mode language and stale eventplan citations
---
## What
The documentation and every model-facing string must state the new contract plainly: a tool declares ahead of time that it is long-running; such a tool always returns a handle; all other tools run to completion; `timeout` bounds the work; the session pushes settlement — the model never polls.

- [x] Rewrite doc comments that narrate the removed race ("soft deadline", "two clocks", "a call that outlives the window", "detaches at waitSeconds") in the new `Hosting/` engine files.
- [x] Remove every "eventplan.md § …" and "Elevation" citation from `Sources/` (`RoutedSessionActorTurnExecution.swift`, `RoutedLLM.swift`, `Recording/SessionTreeRestoration.swift`, the engine files).
- [x] Correct the drain narration in `Sources/FoundationModelsRouter/Session/RoutedSession.swift:281-295` and `RoutedSessionActorGeneration.swift:70-84`: backgrounding is now the USUAL path for shell and agent calls, and delivery-on-settlement is the usual path too — not "a safety net".
- [x] `Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift:199-206` (`renderedPendingRuns`) writes model-visible text that says "call status() for the live view" — that tells the model to poll. Rewrite: the session reports each run when it settles; `status`/`wait` are available for an earlier look.
- [x] Update `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` and check `README.md`.

## Acceptance Criteria
- [x] `rg -i 'waitSeconds|soft deadline|two clocks|eventplan|elevat' Sources README.md` returns no match.
- [x] No model-facing string tells the model to poll. `rg 'call status' Sources` shows only text that also states the push contract.
- [x] `swift build --build-tests` is green.

## Tests
- [x] Behavior does not change, except rendered strings: update the string assertions that cover `renderedPendingRuns` and the `PendingRunEnvelope` text. Run `swift test` — green.

## Workflow
- Use `/tdd` — update the string-assertion tests first, then the strings.