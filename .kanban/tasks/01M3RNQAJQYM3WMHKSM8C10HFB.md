---
position_column: todo
position_ordinal: '8180'
title: RealModelContainer loads through MLXModelLoader(tokenizerLoader:)
---
**Wait for:** FoundationModelsExtras task 01M3RNQ6K5MBEN68C62VGNWW4Y ("MLXModelLoader takes an optional tokenizer loader") on the Extras board: done and pushed.

## What
- `Tests/FoundationModelsRouterRealModelSupport/RealModelContainer.swift`: for pinned chat-template date loads, use `LiveModelLoader(reporting:modelLoader: MLXModelLoader(tokenizerLoader: PinnedDateTokenizerLoader(...)))` in place of making its own `MLXLanguageModel`.
- Delete the code that only that path used.
- `swift package update`, confirm the new Extras revision; push to `origin main` when green.

## Acceptance Criteria
- [ ] No Router source or test support constructs an `MLXLanguageModel`.
- [ ] The pinned-date real-model tests still get the pinned date in the chat template.
- [ ] CI is green on the pushed commit.

## Tests
- [ ] The existing real-model tests that use the pinned date pass.
- [ ] `swift test` and `swift test --package-path IntegrationTests` pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool