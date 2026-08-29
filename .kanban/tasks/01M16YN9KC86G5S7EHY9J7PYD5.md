---
assignees:
- claude-code
position_column: todo
position_ordinal: 8d80
title: A consumer outside the module cannot conform to LoadedLLMContainer
---
## What

`LoadedLLMContainer` is `public` (Sources/FoundationModelsRouter/Resolution/ModelLoader.swift:31), but the `extension LoadedLLMContainer` right below it (line 53) carries no access modifier, so its three default implementations are `internal`:

- `languageModel`
- `makeSession(instructions:tools:)`
- `makeSession(transcript:tools:)`

A module outside this package therefore sees three unfulfilled requirements it has no default for. A plain `import FoundationModelsRouter` consumer that writes its own container gets `type 'X' does not conform to protocol 'LoadedLLMContainer'`, and must hand-write all three — including a `languageModel` that can only trap.

Found while task ^jp93e7c wrote a plain-import test. That test worked around the gap by reusing an in-target container, so nothing is blocked today; the gap is only visible to a real consumer.

## Acceptance Criteria
- [ ] A module outside this package can declare a type that conforms to `LoadedLLMContainer` while implementing `makeSession(instructions:)` and `makeSession(transcript:)` alone.
- [ ] Check the sibling public protocols in the same file — `LoadedModelContainer`, `LoadedEmbeddingContainer`, `ModelLoader` — for the same defect, and correct each place the same cause appears.

## Tests
- [ ] Add a case to Tests/FoundationModelsRouterTests/GuidedPublicSurfaceTests.swift, or to a sibling plain-import suite, that declares a container with the two required factories only. The compiler proves the defaults reach outside the module.
- [ ] Run `swift test`. All tests pass. #router #api