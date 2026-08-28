---
assignees:
- claude-code
position_column: todo
position_ordinal: '9080'
title: Repair the DocC links to internal runners in the Hosting doc comments
---
## What

Two source doc comments link the internal types `BackgroundToolRunner` and `RunToCompletionRunner`. DocC cannot resolve either name, because the symbol graph holds public symbols only. Task ^hhtc4v7 repaired the same two names in `RoutedSession.md`; these two files stayed outside its scope.

- `Sources/FoundationModelsRouter/Hosting/ToolInvocationRecord.swift`, the type doc comment: ``RunToCompletionRunner`` and ``BackgroundToolRunner``.
- `Sources/FoundationModelsRouter/Hosting/ToolMounting.swift`, the doc comment of `makeWrapped(tool:sessionID:mailbox:sink:op:configuration:)`: ``BackgroundToolRunner`` and ``RunToCompletionRunner``.

Rewrite each as plain code text, or link the public equivalent. ``ToolMount/Mode/background`` and ``ToolMount/Mode/runToCompletion`` carry the same meaning; `RoutedSession.md` now uses them. Do not widen the access level of the two runner types. They are correctly internal.

## Acceptance Criteria
- [ ] Neither file has a symbol link to an internal symbol.
- [ ] No source file changed its access level.

## Tests
- [ ] Build the documentation and confirm the four warnings for these two names are gone. The package has no DocC plugin, so use `xcrun docc convert` over the catalog with a symbol graph. Comment 1 of ^hhtc4v7 gives the three commands.
- [ ] Run `swift build`. It succeeds.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #docs