# FoundationModelsRouter

[![CI](https://github.com/swissarmyhammer/FoundationModelsRouter/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsRouter/actions/workflows/ci.yml)

A Swift router for local MLX language models on Apple silicon. Author a
`ProfileDefinition` listing candidate models per role (`standard`, `flash`,
`embedding`); `Router.resolve` measures the host's real RAM/GPU budget, picks
the biggest candidate that fits each slot, and hands back a resident,
sessionable, transcript-recording profile — one active profile at a time, so
it never over-commits memory.

```swift
import FoundationModelsRouter
import MLXHuggingFace

let router = Router(
    recordingsDir: recordingsDir,
    loader: LiveModelLoader(
        downloader: #hubDownloader(),
        tokenizerLoader: #huggingFaceTokenizerLoader()
    )
)

let coding = ProfileDefinition(
    name: "coding",
    description: "Local coding assistant.",
    standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
    flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
    embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
)

let profile = try await router.resolve(coding, reporting: ResolutionProgress())

let session = profile.standard.makeSession(instructions: "You are a terse Swift expert.")
let answer = try await session.respond(
    to: "Which Swift keyword marks a class that cannot be subclassed?"
)
print(answer)

await profile.release()
```

A second, smaller `flash` model resolves alongside `standard` from the same
call, so cheap work (triage, classification) can route to it while `standard`
handles the heavy turns — see `Examples/MultiModelGeneration` for a runnable,
two-model demo.

## Install

Add the package to `Package.swift`:

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsRouter", branch: "main")
```

## Documentation

Every public API has a worked example in
[`Tests/FoundationModelsRouterTests/ExamplesTests.swift`](Tests/FoundationModelsRouterTests/ExamplesTests.swift) —
resolution, sessions, streaming, guided (grammar-constrained) generation,
embeddings, forking, and residency. A runnable, real-model demo lives in
[`Examples/MultiModelGeneration`](Examples/MultiModelGeneration).

## License

No license file is currently published in this repository.
