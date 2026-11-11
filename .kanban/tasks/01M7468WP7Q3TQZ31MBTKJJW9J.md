---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m75bnsxmrh0xfgfcanmhwdbw
  text: |-
    Research and discoveries:
    - The checkouts in .build/checkouts are the same as the sibling repositories (FoundationModelsDecision f157c41, FoundationModelsExtras ddf5bf7).
    - `GenericPromptFormat` rejects only one template output: `nil` (no chat template). It does NOT reject an open thinking block. With `closedThinkFallback: false` (the default) it tokenizes the rendered text as it is. Thus the flash-fallback criterion cannot pass from the Decision package alone. The Router now owns the check: new internal `Resolution/ReasoningOffPromptFormat.swift`. `PooledDecisionContainer.init` wraps the format with `ReasoningOffPromptFormat.guarding(_:)`. The wrapper wraps the source of the plan; when the format renders with `reasoning: false` and the text (with no whitespace at the end) ends with `<think>` or `<|channel>thought`, it throws `DecisionError.unsupportedModel(ReasoningOffPromptFormat.openThinkingMessage)` before any `logProbabilities` call.
    - Only a `GenericPromptFormat` with no closed-think fallback gets the check. `GenericPromptFormat(closedThinkFallback: true)` closes the block itself, and `DeciderPromptFormat` (chat layout) closes the three decider-ai blocks itself in `DeciderChatTemplate`. A check on those formats would refuse templates that they handle correctly.
    - If the Decision package later adds this check to `GenericPromptFormat`, the Router wrapper can go.
    - `MLXLanguageModel` already conforms to `PooledLogits` (Extras `MLXLogits.swift`), so `UnloadableMLXModel` is not a non-conforming model. The tests use new stubs in `Tests/FoundationModelsRouterTests/Helpers/StubLogits.swift`: `StubLogits`, `FixedContainerLoader` (with `llmHold(over:ref:)`), a generic `UndrivenExecutor`, `PlainStubLanguageModel` and `LogitsStubLanguageModel`.
    - `RoutedDeciderTests` builds the handle with slot `.flash`, because `ModelSlot.decision` comes with R2. The handle reads no slot.
    - Mutation check: with `PooledDecisionContainer` passing the format unchanged, the two open-thinking tests fail (3 issues).
  timestamp: 2026-11-11T13:10:09.076730+00:00
- actor: claude-code
  id: 01m75bnxtppthdfzman0zc6an0
  text: |-
    ### implement — changed
    - evidence: 10 files. New: Sources/FoundationModelsRouter/RoutedDecider.swift, Sources/FoundationModelsRouter/Resolution/PooledDecisionContainer.swift, Resolution/LiveLLMContainerLogits.swift, Resolution/DecisionFormatSelection.swift, Resolution/ReasoningOffPromptFormat.swift, Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift, DecisionFormatSelectionTests.swift, RoutedDeciderTests.swift, Helpers/StubLogits.swift. Changed: Resolution/ModelLoader.swift (LoadedDecisionContainer), LanguageModelProfile.swift (RoutedDecider typealias). `swift build --build-tests`: no compiler warning (only the SwiftPM "missing creator for mutated node" note for the mlx-swift_Cmlx bundle, which is not from this change). Filtered run: 19 tests in 3 suites passed. Full `swift test` once: 2550 tests in 298 suites, 38 in 23 suites, 19 in 3 suites, all passed.
    - next: /review. Task stays in doing.
  timestamp: 2026-11-11T13:10:13.079008+00:00
- actor: claude-code
  id: 01m75c52shdge5t762dkdb6wx5
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (da3a05c2); 1 finding (1 confirmed, 2 refuted) — Tests/FoundationModelsRouterTests/RoutedDeciderTests.swift:56 (test-integrity/no-hard-code)
    - next: Do the open item in "Review Findings (2026-11-11 07:13)". Then review again.
  timestamp: 2026-11-11T13:18:29.681872+00:00
- actor: claude-code
  id: 01m75c5mtqeh86c3fksp6mjn3w
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 9 new files, 2 changed (container, RoutedDecider, LiveLLMContainer logits, format selection, ReasoningOffPromptFormat, tests)
    - test: green — swift test, 2550 + 38 + 19 passed, 0 skipped
    - commit: da3a05c2
    - review: findings — Tests/FoundationModelsRouterTests/RoutedDeciderTests.swift:56
  timestamp: 2026-11-11T13:18:48.151179+00:00
- actor: claude-code
  id: 01m75cf25yw1c63c2b1p78g0yk
  text: |-
    Fix of the finding test-integrity/no-hard-code (RoutedDeciderTests.swift:56). The cause: a stub gives a constant that does not depend on its input, and the test asserts that same constant. I removed the cause from the three test files of this task:
    - RoutedDeciderTests: the stub executor reads the probability of each binary question from the table `answers` (two questions, 0.75 and 0.25), by the instructions of the question. An unknown question throws. The test has one argument for each question and expects the probability of that question. A session that gives one fixed value fails one argument.
    - StubLogits (Helpers): the chat template now renders the messages (ChatML) and then a suffix that changes with `reasoning` (`reasoningOffSuffix`, `reasoningOnSuffix`). Each log probability is `-(candidate + sum of the prompt token IDs)`. The `renderedTemplate` and `logProbability` init parameters are gone.
    - PooledDecisionContainerTests: the render and log-probability forwarding tests compare with the result of the stub for the same arguments (the same shape as the tokenize test). The prompt-limit test has two arguments (512, 2048), and the context window of the live container (4096) is different from each limit.
    - DecisionFormatSelectionTests has no stub; its expected temperature comes from the fixture input. No change.
    - Mutation check: with `LiveLLMContainer.renderChatTemplate` forcing `reasoning: true`, the render forwarding test fails (1 issue). Source restored.
    - Discovery: the sibling ../FoundationModelsDecision is now at 3571ec5 "fix(generic): throw unsupportedModel on open thinking block". The pinned checkout is still f157c41. When the Router takes that version, `ReasoningOffPromptFormat` can go (see the first comment).
  timestamp: 2026-11-11T13:23:56.734538+00:00
- actor: claude-code
  id: 01m75cf5894zcxwmm9smqwftp0
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsRouterTests/RoutedDeciderTests.swift, Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift, Tests/FoundationModelsRouterTests/Helpers/StubLogits.swift. `swift build --build-tests`: no compiler warning (only the SwiftPM "missing creator for mutated node" note for the mlx-swift_Cmlx bundle, not from this change). Filtered run: 19 tests in 3 suites passed. Full `swift test` once: 2550 tests in 298 suites, 38 in 23 suites, 19 in 3 suites, all passed, exit 0. Finding item checked.
    - next: /review. Task stays in doing.
  timestamp: 2026-11-11T13:23:59.881770+00:00
- actor: claude-code
  id: 01m75cmkxxay7r705s6bnse221
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (0261bd9c). 1 finding (1 confirmed, 0 refuted): Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift:178 `completeness/inverse-operation-coverage`.
    - next: Do the item in "Review Findings (2026-11-11 07:25)". Add a forwarding check for `reasoning: true` in `liveContainerForwardsRenderChatTemplate`. Then run the review again.
  timestamp: 2026-11-11T13:26:58.749482+00:00
- actor: claude-code
  id: 01m75cn2vpkwa31b9k11rvx0k6
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — RoutedDeciderTests.swift, PooledDecisionContainerTests.swift, Helpers/StubLogits.swift
    - test: green — swift test, 2550 + 38 + 19 passed, 0 skipped
    - commit: 0261bd9c
    - review: findings — Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift:178
  timestamp: 2026-11-11T13:27:14.038197+00:00
- actor: claude-code
  id: 01m75cw6tz75jeartfm7640wey
  text: |-
    Fix of the finding completeness/inverse-operation-coverage (PooledDecisionContainerTests.swift:178). The cause: a forwarding test sends only one of the argument variants that the stub tells apart. A container that drops or hardcodes that argument passes. I removed the cause from all four forwarding tests:
    - renderChatTemplate: the test is parameterized over `reasoningRequests = [false, true]`, and compares with the stub for the same request. New test `stubRendersEachReasoningRequestDifferently` asserts that the stub output for `false` and for `true` differ.
    - tokenize: the test tokenizes `texts = ["", text, "other text"]` in order through the container (helper `tokenizeEach(_:with:)`) and compares with the stub. New test `stubTokenizesEachTextDifferently` asserts that the stub gives a different result for each text. The old test used one text, and a container that tokenized a fixed text passed.
    - maximumPromptTokens: `promptLimits` is now `[512, 2048, nil]`. The `nil` case is a logits model with no fixed limit; a container that gives its context window in that case fails.
    - logProbabilities: no change. Its arguments already give four different values (each candidate and each prompt sum changes the value), and the plain-model tests already cover the throw.
    - Mutation check (all three at the same time in LiveLLMContainerLogits.swift: `reasoning: false` hardcoded, tokenize of the fixed text "some text", and `?? contextWindow` on the prompt limit): the filtered run of 16 tests failed with 3 issues, one for each mutation, at the argument `reasoning → true`, the tokenize test, and `promptLimit → nil`. The old tests pass with each of these mutations. Source restored from a scratch copy; `git status` shows no change in Sources.
  timestamp: 2026-11-11T13:31:07.487694+00:00
- actor: claude-code
  id: 01m75cw9dfckx1pcvmmhafn7tr
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift. `swift build --build-tests`: no compiler warning (only the SwiftPM "missing creator for mutated node" note for the mlx-swift_Cmlx bundle, not from this change). Mutation run (filter PooledDecisionContainerTests): 16 tests, 3 expected issues. Full `swift test --skip-build` once after restore: 2552 tests in 298 suites, 38 in 23 suites, 19 in 3 suites, all passed. Finding item "Review Findings (2026-11-11 07:25)" checked.
    - next: /review. Task stays in doing.
  timestamp: 2026-11-11T13:31:10.127210+00:00
depends_on:
- 01M7467X77633VE23P71VC8XXV
position_column: doing
position_ordinal: '80'
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
- [x] `PooledDecisionContainer(hold:format:)` over a hold whose container conforms to `PooledLogits` gives a `decisionModel` whose `modelID` is the ref of the hold.
- [x] Over a hold whose container does not conform, the init throws `PooledLogitsModelError.notLogitsCapable`.
- [x] `LiveLLMContainer` forwards `tokenize`, `renderChatTemplate`, `logProbabilities` and `maximumPromptTokens` to a model that conforms, and throws `notLogitsCapable` for a model that does not.
- [x] `DecisionFormatSelection.format(deciderConfiguration:)` gives `DeciderPromptFormat` for config data and `GenericPromptFormat` for `nil`; malformed data throws.
- [x] `makeSession(state:)` on a decider over a stub container answers through the stub model.
- [x] Flash fallback on a reasoning model (request from the FoundationModelsDecision session): a `PooledDecisionContainer` with `GenericPromptFormat()` over a stub `PooledLogits` whose chat template cannot turn reasoning off (it renders a thinking prefix also for `reasoning: false`) makes a decision throw `DecisionError.unsupportedModel`, and gives no probabilities.

## Tests
- [x] New `Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift`: stub `PooledLogits` container in a `ModelPool` with a stub loader (no model download); the throwing case; the `LiveLLMContainer` forwarding with a stub `LanguageModel` that conforms to `PooledLogits` and one that does not; the reasoning-template case that throws `DecisionError.unsupportedModel` (read `GenericPromptFormat` in ../FoundationModelsDecision to find what template output it rejects).
- [x] New `Tests/FoundationModelsRouterTests/DecisionFormatSelectionTests.swift`: the three cases, with a small `decider_config.json` fixture string.
- [x] New `Tests/FoundationModelsRouterTests/RoutedDeciderTests.swift`: `makeSession(state:)` with a stub `DecisionModel` container; `probability(of:)` gives the stub value.
- [x] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
## Changes from the board check
- `maximumPromptTokens` is a property that cannot throw. For a model that does not conform to `PooledLogits`, it gives `nil`. The criterion "throws `notLogitsCapable`" applies only to `tokenize`, `renderChatTemplate` and `logProbabilities`.
#decision

## Review Findings (2026-11-11 07:13)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsRouterTests/RoutedDeciderTests.swift:56` `test-integrity/no-hard-code` — The test stub executor returns the same constant, RoutedDeciderTests.stubProbability (0.75), that the test then asserts on at line 93. The assertion only proves that the session passes the executor's answer through unchanged. It does not prove that the session computes a probability from the model's answers, so a session that returned a fixed value would also pass. Make the stub answer depend on its input, for example by giving each question a distinct probability or by echoing a value derived from the question, and assert that the session returns the value for the specific question. Keep the routing assertion, but make the expected value come from the input rather than a constant that the stub also returns.

## Review Findings (2026-11-11 07:25)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/PooledDecisionContainerTests.swift:178` `completeness/inverse-operation-coverage` — The stub now takes a `reasoning` flag and gives a different suffix for `reasoning: true`, and its doc comment says a test sees when a caller forwards the wrong arguments. But `liveContainerForwardsRenderChatTemplate` only forwards `reasoning: false`. A `LiveLLMContainer.renderChatTemplate` that drops the flag or hardcodes `false` would still pass this test, so the `reasoning: true` input variant is never checked through the forwarding path. Add a second assertion, or a parameterized case, that calls `container.renderChatTemplate(Self.messages, reasoning: true)` and compares it with `logits.renderChatTemplate(Self.messages, reasoning: true)`. Confirm the two outputs differ, so the test fails if the flag is not forwarded.
