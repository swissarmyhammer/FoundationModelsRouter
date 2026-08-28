---
assignees:
- claude-code
position_column: todo
position_ordinal: '9180'
title: Publish the RoutedSession convenience extension members
---
## What

`extension RoutedSession` (Sources/FoundationModelsRouter/Session/RoutedSession.swift:317) carries no access modifier, so the members that do not state one are `internal`. The extension is a mix:

Public today: `respond(to:)` (line 334), `streamResponse(to:)` (line 339), `streamEvents(to:)` (line 344).

Internal today, and the defect: `compact()` (line 320), `compact(budget:)` (line 329), `enqueue(prompt: String)` (line 351), `cancelPrompt(id:)` (line 365).

The four internal members are convenience wrappers over public requirements of the same public protocol — `compact(prompt:budget:)`, `enqueue(prompt: Transcript.Prompt)`, `cancel(id:)` and `cancelCurrentTurn()` — exactly as their three public siblings are. The protocol's own doc comments present them as caller surface: `cancelCurrentTurn()` points the reader at ``cancelPrompt(id:)`` for the combined behavior. A consumer with a plain import can call `respond(to:)` but not `compact()`, which is not a defensible boundary.

Make the four members `public`, so the extension matches the protocol it extends.

This also repairs five DocC warnings in `FoundationModelsRouter.docc/RoutedSession.md` that task ^hhtc4v7 could not fix: the `## Topics` entries for `compact()`, `compact(budget:)` and `cancelPrompt(id:)`, and the disambiguation warning on `enqueue(prompt:)`. One Topics entry names `compact(prompt:)`, which exists in no form — correct it to the protocol requirement `compact(prompt:budget:)` or remove it.

If the audit shows any of the four was made internal deliberately, do not widen it: record the reason on this task and leave that one member as it is.

## Acceptance Criteria
- [ ] `compact()`, `compact(budget:)`, `enqueue(prompt: String)` and `cancelPrompt(id:)` are callable through a plain `import FoundationModelsRouter`.
- [ ] The `RoutedSession.md` Topics entries for those members resolve, and no entry names a method that does not exist.
- [ ] The DocC warning count falls by the five named warnings, with no new warning.

## Tests
- [ ] Add the calls to `Tests/FoundationModelsRouterTests/GuidedPublicSurfaceTests.swift`, or a new plain-import test file if that one does not exist yet. A plain `import FoundationModelsRouter` (no `@testable`) makes the compiler itself prove the surface is public.
- [ ] Assert each of the four members runs against the scripted fixtures, not only that it compiles.
- [ ] Rebuild the documentation by the symbol-graph route in ^hhtc4v7 and compare the warning list before and after.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api