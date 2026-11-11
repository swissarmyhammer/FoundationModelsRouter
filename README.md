# FoundationModelsRouter

[![CI](https://github.com/swissarmyhammer/FoundationModelsRouter/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsRouter/actions/workflows/ci.yml)

Resolve local MLX language models into resident, recorded sessions on Apple silicon.

List candidate models for each role (`standard`, `flash`, `embedding`,
`decision`) in a `ProfileDefinition`. `Router.resolve` measures the real RAM
and GPU budget of the host, picks the biggest candidate that fits each slot,
and hands back a resident profile. Each session of that profile records its
transcript to disk. Residency is pooled: profiles that name the same model
share one loaded copy.

```swift
import Foundation
import FoundationModelsRouter

let router = Router(
    recordingsDir: URL.documentsDirectory.appending(path: "RouterTranscripts"),
    loader: LiveModelLoader()  // downloads a model from Hugging Face when the cache lacks it
)

let coding = ProfileDefinition(
    name: "coding",
    description: "Local coding assistant.",
    standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
    flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
    embedding: ["erjigit17/embeddinggemma-300m-ane-coreml"],
    decision: ["Mapika/decider-4b-GGUF/decider-4b-v3-Q4_K_M.gguf"]
)

let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

let session = profile.standard.makeSession(instructions: "You are a terse Swift expert.")
let answer = try await session.respond(
    to: "Which Swift keyword marks a class that cannot be subclassed?"
)
print(answer)
```

The embedding model runs on the Apple Neural Engine.

## Decisions

The `decision` slot gives the probability of an answer to a question about a
state. It reads the probabilities from the model, and it generates no text:

```swift
import FoundationModelsDecision

let ticket = "The checkout page is down for all customers."
let urgency = try await profile.decision.makeSession(state: .text(ticket))
    .probability(of: "Does this convey urgency?")
print(urgency)  // The probability of "yes", from 0 to 1.
```

When no `decision` candidate fits the memory that the other slots leave, the
slot uses the `flash` model. See [Decisions](docs/decision.md).

## Local models

A candidate can name a folder on the disk instead of a Hub repository. Give an
absolute path, or a path that starts with `~` or `./`:

```swift
let profile = ProfileDefinition(
    name: "local", description: "Models from the disk",
    standard: [ModelRef(repo: "~/models/standard")],
    flash: [ModelRef(repo: "~/models/flash")],
    embedding: [ModelRef(repo: "./models/embedder")])
```

The router finds the format of the folder (MLX or Core ML) by itself, and it
sizes the folder from its files. It makes no Hub call and no download. See
[ANE embedding models](docs/ane-embedding.md) for the rules.

## Install

The package needs macOS 27 or later. Add it to `Package.swift`, with the floor.
Add `FoundationModelsDecision` too, for the `DecisionState` and
`DecisionSession` types of the `decision` slot:

```swift
platforms: [.macOS("27.0")],
dependencies: [
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsRouter", branch: "main"),
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsDecision", branch: "main"),
],
// In your target:
// .product(name: "FoundationModelsRouter", package: "FoundationModelsRouter"),
// .product(name: "FoundationModelsDecision", package: "FoundationModelsDecision"),
```

## Documentation

- [Installation details](docs/installation.md): the macOS floor, the model cache folder, the Hugging Face token.
- [Models, residency and tools](docs/residency.md): why `standard` and `flash` are two different models, the process-wide model pool, tool hosting.
- [Decisions](docs/decision.md): the `decision` slot, its default model, the prompt format, the memory rule and the flash fallback.
- [ANE embedding models](docs/ane-embedding.md): the default CoreML embedding model, how the router detects it, and models in a local folder.
- [Tests](docs/testing.md): hermetic and real-model tests, and where the worked examples are.
- [`Examples/MultiModelGeneration`](Examples/MultiModelGeneration): a runnable demo with two models.

## License

No license file is published in this repository yet.
