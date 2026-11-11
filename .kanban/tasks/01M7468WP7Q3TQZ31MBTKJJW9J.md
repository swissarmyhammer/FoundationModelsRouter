---
assignees:
- claude-code
depends_on:
- 01M7467X77633VE23P71VC8XXV
position_column: todo
position_ordinal: '8280'
title: 'R5: decision container, RoutedDecider handle and prompt-format selection'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R5, and decision D13. The model is `PooledEmbeddingContainer` / `RoutedEmbedder`.

1. `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift`: add
   `public protocol LoadedDecisionContainer: LoadedModelContainer { var decisionModel: any DecisionModel { get } }`.
2. New `Sources/FoundationModelsRouter/Resolution/PooledDecisionContainer.swift`:
   `struct PooledDecisionContainer: LoadedDecisionContainer` with `init(hold: ModelHold, format: any DecisionPromptFormat) throws`, which makes `PooledDecisionModel(hold:format:)`. It throws `PooledLogitsModelError.notLogitsCapable` when the container of the hold does not conform to `PooledLogits`.
3. `PooledLogits` on the router container. The pool container of a router `.llm` hold is `LiveLLMContainer` (`Resolution/LiveModelLoader.swift`), not the `LlamaLanguageModel` or `MLXLanguageModel`. Thus `PooledDecisionModel(hold:)` fails on a router hold. Make `LiveLLMContainer` conform to `PooledLogits`: each requirement forwards to the model ONLY through `model as? any PooledLogits` (no runtime-specific code, so MLX and llama.cpp both work); when the model does not conform, the calls throw `PooledLogitsModelError.notLogitsCapable(ref)`. Put the conformance in a new file `Sources/FoundationModelsRouter/Resolution/LiveLLMContainerLogits.swift`.
4. Prompt-format selection (D13), new `Sources/FoundationModelsRouter/Resolution/DecisionFormatSelection.swift`: a pure function `static func format(deciderConfiguration: Data?) throws -> any DecisionPromptFormat`. Data present → `DeciderPromptFormat(configuration: JSONDecoder().decode(DeciderConfiguration.self, from: data))`. Data `nil` → `GenericPromptFormat()`. The rule is: a repository with a `decider_config.json` uses the decider format; a repository with no such file uses the generic format. The fetch of the file is in the R7a task.
5. New `Sources/FoundationModelsRouter/RoutedDecider.swift`:
   - In `LanguageModelProfile.swift`, next to `RoutedEmbedder`: `public typealias RoutedDecider = RoutedModel<any LoadedDecisionContainer>`.
   - `extension RoutedModel where Container == any LoadedDecisionContainer { public func makeSession(state: DecisionState) -> DecisionSession }`. It makes `DecisionSession(model: container.decisionModel, state: state)`. The span (R10) and the profile property (R6) come later.
   - DocC: a decision writes nothing to the transcript, the same as an embed call.

## Acceptance Criteria
- [ ] `PooledDecisionContainer(hold:format:)` over a hold whose container conforms to `PooledLogits` gives a `decisionModel` whose `modelID` is the ref of the hold.
- [ ] Over a hold whose container does not conform, the init throws `PooledLogitsModelError.notLogitsCapable`.
- [ ] `LiveLLMContainer` forwards `tokenize`, `renderChatTemplate`, `logProbabilities` and `maximumPromptTokens` to a model that conforms, and throws `notLogitsCapable` for a model that does not.
- [ ] `DecisionFormatSelection.format(deciderConfiguration:)` gives `DeciderPromptFormat` for config data and `GenericPromptFormat` for `nil`; malformed data throws.
- [ ] `makeSession(state:)` on a decider over a stub container answers through the stub model.
- [ ] Flash fallback on a reasoning model (request from the FoundationModelsDecision session): a `PooledDecisionContainer` with `GenericPromptFormat()` over a stub `PooledLogits` whose chat template cannot turn reasoning off (it renders a thinking prefix also for `reasoning: false`) makes a decision throw `DecisionError.unsupportedModel`, and gives no probabilities.

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift`: stub `PooledLogits` container in a `ModelPool` with a stub loader (no model download); the throwing case; the `LiveLLMContainer` forwarding with a stub `LanguageModel` that conforms to `PooledLogits` and one that does not; the reasoning-template case that throws `DecisionError.unsupportedModel` (read `GenericPromptFormat` in ../FoundationModelsDecision to find what template output it rejects).
- [ ] New `Tests/FoundationModelsRouterTests/DecisionFormatSelectionTests.swift`: the three cases, with a small `decider_config.json` fixture string.
- [ ] New `Tests/FoundationModelsRouterTests/RoutedDeciderTests.swift`: `makeSession(state:)` with a stub `DecisionModel` container; `probability(of:)` gives the stub value.
- [ ] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
## Changes from the board check
- `maximumPromptTokens` is a property that cannot throw. For a model that does not conform to `PooledLogits`, it gives `nil`. The criterion "throws `notLogitsCapable`" applies only to `tokenize`, `renderChatTemplate` and `logProbabilities`.
