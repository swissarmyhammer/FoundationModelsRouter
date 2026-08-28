---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: Demote the mistakenly public Hosting plumbing to internal
---
## What

The audit found Hosting members that are public but have no consumer outside the module. All consumers are unit tests under `@testable import`, which crosses `internal`. Demote each to `internal`:

- `ToolMounting` and both `makeWrapped` (Sources/FoundationModelsRouter/Hosting/ToolMounting.swift:4, 8, 29).
- `OperationEventSink` and its default extension (Sources/FoundationModelsRouter/Hosting/OperationEventSink.swift:4, 16). Its one conformer is `SessionOutbox`.
- The two `ToolContext` initializers (Sources/FoundationModelsRouter/Hosting/ToolContext.swift:65, 104). The `ToolContext` type stays public; it is documented tool-authoring surface.
- `SessionMailbox.makeCompletionToken()` (Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift:60) and `SessionMailbox.init()` (line 121). The actor stays public for now; a later task hoists its nested types and demotes it.

Also repair the three DocC links in Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md that point at internal symbols and cannot resolve: ``BackgroundToolRunner``, ``RunToCompletionRunner``, and ``ToolContext/isCancelled``. Rewrite each as plain text or link a public symbol instead.

## Acceptance Criteria
- [ ] Each listed member is `internal`.
- [ ] `ToolContext` and `SessionMailbox` types are still public.
- [ ] `RoutedSession.md` has no symbol link to an internal symbol.

## Tests
- [ ] Run `swift build` and `swift test` at the root. All targets build and all tests pass; the plain-import support, example, and tool targets prove no demoted member was load-bearing.
- [ ] Run `swift build --package-path IntegrationTests`. It builds; its `@testable import` still reaches the demoted members.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #cleanup