# FoundationModelsRouter

[![CI](https://github.com/swissarmyhammer/FoundationModelsRouter/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsRouter/actions/workflows/ci.yml)

Resolve local MLX language models into resident, recorded sessions on Apple silicon.

List candidate models for each role (`standard`, `flash`, `embedding`) in a
`ProfileDefinition`. `Router.resolve` measures the real RAM and GPU budget of
the host, picks the biggest candidate that fits each slot, and hands back a
resident profile. Each session of that profile records its transcript to disk.
Residency is pooled: profiles that name the same model share one loaded copy.

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
    embedding: ["erjigit17/embeddinggemma-300m-ane-coreml"]
)

let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

let session = profile.standard.makeSession(instructions: "You are a terse Swift expert.")
let answer = try await session.respond(
    to: "Which Swift keyword marks a class that cannot be subclassed?"
)
print(answer)
```

The embedding model runs on the Apple Neural Engine.

## Install

The package needs macOS 27 or later. Add it to `Package.swift`, with the floor:

```swift
platforms: [.macOS("27.0")],
dependencies: [
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsRouter", branch: "main"),
],
// In your target:
// .product(name: "FoundationModelsRouter", package: "FoundationModelsRouter"),
```

## Documentation

- [Installation details](docs/installation.md): the macOS floor, the model cache folder, the Hugging Face token.
- [Models, residency and tools](docs/residency.md): why `standard` and `flash` are two different models, the process-wide model pool, tool hosting.
- [ANE embedding models](docs/ane-embedding.md): the default CoreML embedding model, and how the router will detect it.
- [Tests](docs/testing.md): hermetic and real-model tests, and where the worked examples are.
- [`Examples/MultiModelGeneration`](Examples/MultiModelGeneration): a runnable demo with two models.

## License

No license file is published in this repository yet.
