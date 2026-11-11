---
assignees:
- claude-code
depends_on:
- 01M746AWW5JWZK2017CJMC5VMJ
- 01M746B9WYHASZZGR6P8SC4C1K
- 01M746BHT4HMJY6R5ZFA9DKCBK
position_column: todo
position_ordinal: 8a80
title: 'R11: document the decision slot (README, docs/decision.md, DocC)'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R11. Write all text in ASD-STE100 Simplified Technical English.

- `README.md`: add `decision` to the profile example, and a short example of `profile.decision.makeSession(state: .text(ticket)).probability(of: "Does this convey urgency?")`.
- New `docs/decision.md`: the slot (`ModelSlot.decision`, pool role `.llm`); the default candidate `Mapika/decider-4b-GGUF/decider-4b-v3-Q4_K_M.gguf`; the prompt-format rule (a repository with `decider_config.json` → `DeciderPromptFormat`; no such file → `GenericPromptFormat`); the memory rule (only the memory left after embedding, standard and flash; a candidate equal to an allocated model costs 0 bytes); the flash fallback and how to read the rejections in the resolution; no transcript entry; the `decide` span and its three attributes; the integration test model `decider-2b`.
- DocC catalog `Sources/FoundationModelsRouter/FoundationModelsRouter.docc`: add `RoutedDecider` and `LoadedDecisionContainer` to the topics page next to `RoutedEmbedder`.
- `docs/residency.md`: one line for the decision slot, if it lists the slots.

## Acceptance Criteria
- [ ] `README.md`, `docs/decision.md` and the DocC topics name the decision slot, and each symbol that they name exists in the code.
- [ ] The README example compiles: copy it into a test.

## Tests
- [ ] Add the README example to `Tests/FoundationModelsRouterTests/ExamplesTests.swift` with a stub decider, so that the example compiles and runs.
- [ ] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
- `Sources/FoundationModelsRouter/Tools.swift` says "Pass `profile.flash`, `profile.standard`, or `profile.embedding` in". Add `profile.decision`, and add a `DecideTool` example next to `EmbedTool` (a tool that takes a `RoutedDecider` and answers one yes/no question). Add a test for it in `Tests/FoundationModelsRouterTests/ExamplesTests.swift` with the stub decider.
