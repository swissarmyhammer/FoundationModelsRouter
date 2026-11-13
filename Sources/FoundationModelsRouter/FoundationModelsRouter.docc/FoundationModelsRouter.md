# ``FoundationModelsRouter``

Resolve local language models into resident, recorded sessions on Apple silicon.

## Overview

A ``ProfileDefinition`` lists candidate models for each slot: `standard`,
`flash`, `embedding` and `decision`. ``Router/resolve(profile:reporting:)``
measures the memory budget of the host, picks the first candidate that fits
each slot, and gives a ``LanguageModelProfile``. The profile has one handle for
each slot. Pass a handle into the initializer of a tool.

The `decision` slot answers questions about a state with probabilities. When
no decision candidate fits the memory that the other three slots leave, the
slot uses the `flash` model. A GGUF decision model whose
`<arch>.decision.type` llama.cpp supports answers with the decision code of
llama.cpp. Another model gets the prompt format of its `decider_config.json`
file, or the generic format. The repository file `docs/decision.md` gives the
full rules.

## Topics

### Profiles

- ``ProfileDefinition``
- ``LanguageModelProfile``
- ``ModelSlot``

### Model handles

- ``RoutedModel``
- ``RoutedLLM``
- ``RoutedEmbedder``
- ``RoutedDecider``

### Loaded containers

- ``LoadedLLMContainer``
- ``LoadedEmbeddingContainer``
- ``LoadedDecisionContainer``

### Sessions

- ``RoutedSession``
- <doc:GuidedGeneration>
- <doc:SessionObserver>
