---
assignees:
- claude-code
position_column: todo
position_ordinal: 9d80
title: Delete the docs directory
---
The user asked to delete the docs. The `docs/` directory holds one file, `docs/Usage.md` (8 KB), which describes `respond`, the run plane, and drain behavior.

## What

- Delete `docs/Usage.md` and the `docs/` directory in /Users/wballard/github/swissarmyhammer/FoundationModelsRouter.
- Before the deletion, search the repository for references to `docs/` and `Usage.md` (exclude `.build/` and `.kanban/`). Remove or repoint each reference.
- Do not move the content into README.md. The deletion is the request.

## Acceptance Criteria

- [ ] The `docs/` directory does not exist
- [ ] `rg -l "docs/Usage" --glob '!.build' --glob '!.kanban' .` finds no match
- [ ] The hermetic suite stays green

## Tests

- [ ] `rg -l "Usage.md" --glob '!.build' --glob '!.kanban' .` exits with no matches after the deletion
- [ ] `Scripts/swift-test.sh --skip IntegrationTests` (or the current hermetic command) passes with the same counts as before
- [ ] `swift build --build-tests -Xswiftc -warnings-as-errors` exits 0

## Workflow
- Use `/tdd` where a failing check is possible; this card is a deletion, so the reference search is the check.
#docs #cleanup