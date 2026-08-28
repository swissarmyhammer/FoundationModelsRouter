---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
title: Add an example that binds SessionProjection
---
## What

`SessionProjection` (Sources/FoundationModelsRouter/Session/SessionProjection.swift:33) is public, `@Observable`, and documented for SwiftUI binding — but no example, tool, or README line uses it. It is the largest public surface with no external exercise (~34 members). Keep it public, and give it a consumer.

- Add an offline example to `Tests/FoundationModelsRouterTests/ExamplesTests.swift`, in the style of the examples already there: drive a scripted session, feed `streamEvents(to:)` into `SessionProjection.apply(eventsFrom:)`, and read the projected transcript rows and phase.
- The example is the documentation: write it as display-quality code with a doc comment, as the other examples in that file are.
- Add a short section to the DocC catalog (Sources/FoundationModelsRouter/FoundationModelsRouter.docc/) that shows the binding pattern and links `SessionProjection`.
- Do not add a runnable GUI target; the offline example plus DocC is the scope.

## Acceptance Criteria
- [ ] `ExamplesTests` holds a projection example that a reader can copy into a SwiftUI app.
- [ ] The example uses only public API, with a plain `import FoundationModelsRouter` (no `@testable`).
- [ ] The DocC catalog links `SessionProjection` from the binding section.

## Tests
- [ ] The example is itself a test: it asserts the projected rows and the end phase after the scripted turn.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #examples #docs