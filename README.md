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

// `ResolutionProgress` binds into SwiftUI; `progress.phases` is the same
// progress as an AsyncSequence, ending on its own at ready/failed.
let progress = ResolutionProgress()
let progressTask = Task { @MainActor in
    for await transition in progress.phases {
        print("resolve: \(transition.phase)")
    }
}

let profile = try await router.resolve(coding, reporting: progress)
await progressTask.value

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

## Public API

`python3 scripts/symboldiff.py FoundationModelsRouter . HEAD` lists every symbol
this package publishes, members included, read off the compiler's own symbol
graph. Give it two revisions instead of one and it states what the change did to
that surface, and exits non-zero on a removal. A card that narrows an access
level runs it first — [`scripts/README.md`](scripts/README.md) says how.

## Tests

The tests are split by what they need, and the split is a package boundary
rather than an environment variable or a name filter. The root package
declares no integration target, so a plain `swift test` runs only the
hermetic tests by construction. The real-model targets live in the nested
[`IntegrationTests/`](IntegrationTests) package.

```sh
# Everyday: hermetic, no network, no GPU, seconds.
swift test

# Real models: downloads weights and generates on the GPU. Tens of minutes.
swift test --package-path IntegrationTests

# The real-model smoke tier alone — does compaction work at all? Seconds.
swift test --package-path IntegrationTests --filter 'CompactionSmokeIntegrationTests|AutoCompactionTriggerIntegrationTests|RecordedTranscriptCompactionIntegrationTests'
```

`FoundationModelsRouterIntegrationTests` and `FoundationModelsRouterEvalIntegrationTests`
hold every suite that reaches a real model, and no suite in either one reads an
environment variable or can skip itself. Both targets exist only in the nested
package, so a root `swift test` cannot see them, and a run of the nested
package executes every suite in it — no command can silently match nothing.
CI runs the same two commands.

## License

No license file is currently published in this repository.
