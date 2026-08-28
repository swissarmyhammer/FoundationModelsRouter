---
assignees:
- claude-code
position_column: todo
position_ordinal: 8d80
title: Repair the DocC links that point at internal symbols
---
## What

Three symbol links in Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md name symbols that are `internal`, so they cannot resolve when DocC builds:

- ``BackgroundToolRunner``
- ``RunToCompletionRunner``
- ``ToolContext/isCancelled`` (internal at Sources/FoundationModelsRouter/Hosting/ToolContext.swift:40)

Rewrite each as plain text, or link a public symbol that carries the same meaning. Do not widen access to make a link resolve; the symbols are correctly internal.

This is one concern on one file, split out from the Hosting demotion task because four tasks touch this catalog and this repair must land first.

## Acceptance Criteria
- [ ] `RoutedSession.md` has no symbol link to an internal symbol.
- [ ] No source file changed access level for this task.

## Tests
- [ ] Run `swift package generate-documentation` (or `xcrun docc convert` over the catalog) and confirm it reports no unresolved-symbol warning for the three names above.
- [ ] Run `swift build`. It succeeds.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #docs