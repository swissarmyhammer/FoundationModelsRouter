---
assignees:
- claude-code
depends_on:
- 01M0XGRJD4TZTZAFTCSBZEKMFD
position_column: todo
position_ordinal: '8580'
title: Purge dual-mode language and stale eventplan citations
---
## What
The documentation and every model-facing string must state the new contract plainly: a tool declares ahead of time that it is long-running; such a tool always returns a handle; all other tools run to completion; `timeout` bounds the work; the session pushes settlement — the model never polls.

- [ ] Rewrite doc comments that narrate the removed race ("soft deadline", "two clocks", "a call that outlives the window", "detaches at waitSeconds") in the new `Hosting/` engine files.
- [ ] Remove every "eventplan.md § …" and "Elevation" citation from `Sources/` (`RoutedSessionActorTurnExecution.swift`, `RoutedLLM.swift`, `Recording/SessionTreeRestoration.swift`, the engine files).
- [ ] Correct the drain narration in `Sources/FoundationModelsRouter/Session/RoutedSession.swift:281-295` and `RoutedSessionActorGeneration.swift:70-84`: backgrounding is now the USUAL path for shell and agent calls, and delivery-on-settlement is the usual path too — not "a safety net".
- [ ] `Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift:199-206` (`renderedPendingRuns`) writes model-visible text that says "call status() for the live view" — that tells the model to poll. Rewrite: the session reports each run when it settles; `status`/`wait` are available for an earlier look.
- [ ] Update `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` and check `README.md`.

## Acceptance Criteria
- [ ] `rg -i 'waitSeconds|soft deadline|two clocks|eventplan|elevat' Sources README.md` returns no match.
- [ ] No model-facing string tells the model to poll. `rg 'call status' Sources` shows only text that also states the push contract.
- [ ] `swift build --build-tests` is green.

## Tests
- [ ] Behavior does not change, except rendered strings: update the string assertions that cover `renderedPendingRuns` and the `PendingRunEnvelope` text. Run `swift test` — green.

## Workflow
- Use `/tdd` — update the string-assertion tests first, then the strings.