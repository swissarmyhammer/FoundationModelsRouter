---
assignees:
- claude-code
depends_on:
- 01M746A8SW146DW09CCNJPHQ4K
position_column: todo
position_ordinal: 8b80
title: 'Remove ReasoningOffPromptFormat: GenericPromptFormat now rejects an open thinking block'
---
## What
FoundationModelsDecision origin/main (head 48d53e9; commits 3571ec5 and f9b1d0e; CI run 43028999771 green) now has the check that the router added as a temporary wrapper in R5 (^tkjjw9j). When `closedThinkFallback` is false and the rendered chat template, with trailing whitespace trimmed, ends in `<think>\n`, `<think>` or `<|channel>thought\n`, `GenericPromptFormat` throws `DecisionError.unsupportedModel`.

- Update the Decision pin: `swift package --manifest-cache local update FoundationModelsDecision` (stop the sourcekit-lsp of this repository immediately before). Do the same in `IntegrationTests/` so that the two `Package.resolved` files agree (they are gitignored; they stay local).
- Delete `Sources/FoundationModelsRouter/Resolution/ReasoningOffPromptFormat.swift` and each use of it (`PooledDecisionContainer` wraps the format in it). Remove the DocC and comments that name it.
- Keep the router unit test: a fallback decider with `GenericPromptFormat()` over a stub reasoning template throws `DecisionError.unsupportedModel` (in `Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift`). Update its comments so that they say the check is in `GenericPromptFormat`.
- Remove each test that tests only the wrapper type itself.

## Acceptance Criteria
- [ ] `grep -r ReasoningOffPromptFormat Sources Tests` gives no result.
- [ ] The router test for the open thinking block passes with the new Decision pin (48d53e9 or later), and fails with the old pin f157c41 (check one time, then restore the new pin).
- [ ] `swift build --build-tests` gives no new warning.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift`: the open-think test stays and passes.
- [ ] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision