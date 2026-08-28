---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
title: Add an example that binds SessionProjection
---
## What

`SessionProjection` (Sources/FoundationModelsRouter/Session/SessionProjection.swift:33) is public, `@Observable`, and documented for SwiftUI binding — but no example, tool, or README line uses it. It is the largest public surface with no external exercise (~34 members). Keep it public, and give it a consumer.

- Add the example in a NEW file, `Tests/FoundationModelsRouterTests/ProjectionExampleTests.swift`, with a plain `import FoundationModelsRouter`. Do not put it in `ExamplesTests.swift`: that file's line 5 is `@testable import FoundationModelsRouter`, which is file-scoped and cannot be opted out of per declaration, so the plain-import proof would be impossible there.
- Drive a scripted session, feed `streamEvents(to:)` into `SessionProjection.apply(eventsFrom:)`, and read the projected transcript rows and phase.
- The example is the documentation: write it as display-quality code with a doc comment, in the style of the examples in `ExamplesTests.swift`.
- Create a new DocC page `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/SessionProjection.md` that shows the binding pattern and links `SessionProjection`. A new file, so it does not collide with the tasks that edit `RoutedSession.md`.
- Do not add a runnable GUI target; the offline example plus DocC is the scope.

## Acceptance Criteria
- [ ] `ProjectionExampleTests.swift` exists, uses a plain `import FoundationModelsRouter`, and holds an example a reader can copy into a SwiftUI app.
- [ ] The example compiles against the public surface only, which the plain import proves.
- [ ] `SessionProjection.md` exists and links `SessionProjection`.

## Tests
- [ ] The example is itself a test: it asserts the projected rows and the end phase after the scripted turn.
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #examples #docs