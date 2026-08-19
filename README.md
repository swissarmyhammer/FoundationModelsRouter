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

## Tests

The tests are split by what they need, and the split is a package target rather
than an environment variable, so one command names one target.

```sh
# Everyday: hermetic, no network, no GPU, seconds.
swift test --skip IntegrationTests

# Real models: downloads weights and generates on the GPU. Tens of minutes.
swift test --filter IntegrationTests --skip CompactionEvalFullDataset

# The real-model smoke tier alone — does compaction work at all? Seconds.
swift test --filter 'CompactionSmokeIntegrationTests|AutoCompactionTriggerIntegrationTests|RecordedTranscriptCompactionIntegrationTests'

# The whole-dataset compaction eval, a superset of the tier the line above
# measures. Its own limit is two hours.
swift test --filter CompactionEvalFullDataset
```

`FoundationModelsRouterIntegrationTests` and `FoundationModelsRouterEvalIntegrationTests`
hold every suite that reaches a real model, and no suite in either one reads an
environment variable or can skip itself. `--filter` and `--skip` take a regular
expression over `<test-target>.<test-case>`, so the shared
`IntegrationTests` suffix selects both targets at once.

`swift test` answers 0 when a `--filter` matches nothing, printing only
`warning: No matching test cases were run`. Run the commands through
`Scripts/swift-test.sh`, as CI does, to turn that warning into a failure:

```sh
Scripts/swift-test.sh --skip IntegrationTests
```

## License

No license file is currently published in this repository.
