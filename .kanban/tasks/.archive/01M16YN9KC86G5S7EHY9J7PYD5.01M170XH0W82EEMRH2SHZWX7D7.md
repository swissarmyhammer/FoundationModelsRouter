---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m170xcag6wkvt3dj0g8jb26x
  text: |-
    Archived as a duplicate of ^3t0mbb1.

    Two agents in the same /finish batch found the same defect from two sides: this card from ^jp93e7c, and ^3t0mbb1 from ^tf6dwx1. ^3t0mbb1 is the wider card — it holds `LanguageModelSessionBackend` as well as `LoadedLLMContainer`.

    The content of this card is merged into ^3t0mbb1: the sibling protocols named here (`LoadedModelContainer`, `LoadedEmbeddingContainer`, `ModelLoader`) are now a stated acceptance item there, and the `GuidedPublicSurfaceTests.swift` test this card asked for is a test item there. Nothing is lost. Do the work on ^3t0mbb1.
  timestamp: 2026-08-29T15:06:20.880319+00:00
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