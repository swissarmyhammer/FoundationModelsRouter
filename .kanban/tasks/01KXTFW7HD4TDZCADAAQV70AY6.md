---
assignees:
- claude-code
depends_on:
- 01KXTFVEAQCJSE7CXA8RJVRGT9
position_column: todo
position_ordinal: 8b80
title: 'DocC: compaction guide with proactive/reactive patterns'
---
## What
Document compaction (compaction_plan.md §6.10) in the package's DocC (follow the existing documentation convention — DocC catalog if one exists, otherwise rich doc comments on the public API):

- `compact(prompt:budget:)`, `contextFill`, `TokenBudget`, `CompactionPrompt`, `CompactionResult`, `Compactor`, `noteCompaction` — full doc comments with the invariants (append-only recording, checkpoint restore, stable session id).
- The **proactive pattern** as the inline example: check `contextFill >= budget.trigger` between turns — turns never die.
- The **reactive pattern** as the documented recovery path: catch `exceededContextWindowSize`, compact with a lowered target, retry once.
- The bare-session recipe: `Compactor.compact` + `noteCompaction` + rebuild `LanguageModelSession(model: same handle, tools:, transcript:)`.
- Custom prompts: passing a named `CompactionPrompt`, and that the name is recorded in the `CompactionSegment` for eval attribution.

## Acceptance Criteria
- [ ] Every new public symbol has a doc comment; the proactive and reactive patterns appear as compilable inline examples
- [ ] `swift build` emits no documentation-related warnings for the new symbols

## Tests
- [ ] Doc example snippets are mirrored by (or extracted into) test cases in `Tests/FoundationModelsRouterTests/ExamplesTests.swift` so they cannot rot; `swift test --filter Examples` passes
- [ ] If the repo has a docs build step (e.g. `swift package generate-documentation`), it completes without errors

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction