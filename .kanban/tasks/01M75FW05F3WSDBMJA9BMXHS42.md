---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m75g9na7828aes373ycta897
  text: |-
    Research and work notes:
    - The wrapper had uses only in `PooledDecisionContainer` (both inits). No test tested the wrapper type alone, so no test was removed. The only test that named it was `openThinkingTemplateThrowsUnsupportedModel` (it used `ReasoningOffPromptFormat.openThinkingMessage`).
    - In Decision 48d53e9, `GenericPromptFormat.openThinkMessage` is `internal`. The router test cannot name it. A `DecisionLogitsSource` adapter for a `PooledLogits` stub (`PooledLogitsSource`) is also `internal`, so an oracle call to `GenericPromptFormat.plan` needs a copy of that adapter. Decision: the test keeps an exact `#expect(throws: DecisionError.unsupportedModel(...))` with a named constant `openThinkingMessage` that gives the text of Decision. A case-only match was tried first and removed: the no-test-cheating rule names "a specific error turned into 'an error'" as a weakened assertion.
    - `swift package --manifest-cache local resolve FoundationModelsDecision --revision f157c41` fails: "foundationmodelsdecision is required using two different revision-based requirements (f157c41... and main)". Another dependency pins Decision to `main`. What worked for the old-pin check: write f157c41 into the local `Package.resolved`, then `swift package --manifest-cache local resolve` checks it out. `swift package --manifest-cache local update FoundationModelsDecision` restores 48d53e9.
    - Old-pin check (one time, f157c41): 2 tests ran, both failed with "an error was expected but none was thrown". The new pin was restored after; both `Package.resolved` files agree on 48d53e9.
    - `swift build --build-tests` shows one warning only: "missing creator for mutated node: ... mlx-swift_Cmlx.bundle/Contents/MacOS". Earlier tasks record the same SwiftPM warning; it is not new.
  timestamp: 2026-11-11T14:30:54.023063+00:00
- actor: claude-code
  id: 01m75gbpdv9tzh8v1tb0z26j02
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Resolution/ReasoningOffPromptFormat.swift (deleted), Sources/FoundationModelsRouter/Resolution/PooledDecisionContainer.swift, Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift. Decision pin 48d53e9 in Package.resolved and IntegrationTests/Package.resolved (local, gitignored). `grep -r ReasoningOffPromptFormat Sources Tests`: no result. Old pin f157c41: 2 open-think tests ran and failed (no error thrown). New pin: `swift build --build-tests` exit 0, only the known mlx bundle SwiftPM warning; `swift test` one run: 2604 tests in 302 suites, 41 in 23, 19 in 3, all passed.
    - next: /review
  timestamp: 2026-11-11T14:32:00.699530+00:00
- actor: claude-code
  id: 01m75ggzneczw55rweefy9pa48
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (03f93274). 0 findings, 0 confirmed, 0 refuted. The engine reviewed 3 files. It did not review 4 files in .kanban/ because of .reviewignore. Five code-hygiene tool rules did not examine ReasoningOffPromptFormat.swift because the commit deleted that file.
    - next: none. The task is in done.
  timestamp: 2026-11-11T14:34:53.998570+00:00
- actor: claude-code
  id: 01m75ghc9nq1fxz1v94zcak1bq
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — ReasoningOffPromptFormat.swift deleted, PooledDecisionContainer.swift, PooledDecisionContainerTests.swift; Decision pin 48d53e9 (local Package.resolved)
    - test: green — swift test, 2604 + 41 + 19 passed, 0 skipped
    - commit: 03f93274
    - review: clean — 0 findings
  timestamp: 2026-11-11T14:35:06.933817+00:00
depends_on:
- 01M746A8SW146DW09CCNJPHQ4K
position_column: done
position_ordinal: fffffffffe80
title: 'Remove ReasoningOffPromptFormat: GenericPromptFormat now rejects an open thinking block'
---
## What
FoundationModelsDecision origin/main (head 48d53e9; commits 3571ec5 and f9b1d0e; CI run 43028999771 green) now has the check that the router added as a temporary wrapper in R5 (^tkjjw9j). When `closedThinkFallback` is false and the rendered chat template, with trailing whitespace trimmed, ends in `<think>\n`, `<think>` or `<|channel>thought\n`, `GenericPromptFormat` throws `DecisionError.unsupportedModel`.

- Update the Decision pin: `swift package --manifest-cache local update FoundationModelsDecision` (stop the sourcekit-lsp of this repository immediately before). Do the same in `IntegrationTests/` so that the two `Package.resolved` files agree (they are gitignored; they stay local).
- Delete `Sources/FoundationModelsRouter/Resolution/ReasoningOffPromptFormat.swift` and each use of it (`PooledDecisionContainer` wraps the format in it). Remove the DocC and comments that name it.
- Keep the router unit test: a fallback decider with `GenericPromptFormat()` over a stub reasoning template throws `DecisionError.unsupportedModel` (in `Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift`). Update its comments so that they say the check is in `GenericPromptFormat`.
- Remove each test that tests only the wrapper type itself.

## Acceptance Criteria
- [x] `grep -r ReasoningOffPromptFormat Sources Tests` gives no result.
- [x] The router test for the open thinking block passes with the new Decision pin (48d53e9 or later), and fails with the old pin f157c41 (check one time, then restore the new pin).
- [x] `swift build --build-tests` gives no new warning.

## Tests
- [x] `Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift`: the open-think test stays and passes.
- [x] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision