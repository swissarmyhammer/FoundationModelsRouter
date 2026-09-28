# FoundationModelsRouter

[![CI](https://github.com/swissarmyhammer/FoundationModelsRouter/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsRouter/actions/workflows/ci.yml)

A Swift router for local MLX language models on Apple silicon. Author a
`ProfileDefinition` listing candidate models per role (`standard`, `flash`,
`embedding`); `Router.resolve` measures the host's real RAM/GPU budget, picks
the biggest candidate that fits each slot, and hands back a resident,
sessionable, transcript-recording profile. Residency is pooled: several
profiles can be resident together, they share one machine budget, and profiles
that name the same model share its loaded copy. The model pool of
`FoundationModelsExtras` keeps the holds of each model. It evicts a model only
when no hold of that model remains.

```swift
import Foundation
import FoundationModelsRouter
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

// The router records every transcript under this directory.
let recordingsDir = URL.documentsDirectory.appending(path: "RouterTranscripts")

// The two `MLXHuggingFace` macros expand to code that calls `HuggingFace`,
// `MLXLMCommon` and `Tokenizers`. The example imports all three modules above.
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
// progress as an AsyncSequence, ending on its own at ready/failed/cancelled.
let progress = ResolutionProgress()
let progressTask = Task { @MainActor in
    for await transition in progress.phases {
        print("resolve: \(transition.phase)")
    }
}

let profile = try await router.resolve(profile: coding, reporting: progress)
await progressTask.value

let session = profile.standard.makeSession(instructions: "You are a terse Swift expert.")
let answer = try await session.respond(
    to: "Which Swift keyword marks a class that cannot be subclassed?"
)
print(answer)
```

A second, smaller `flash` model resolves alongside `standard` from the same
call, so cheap work (triage, classification) can route to it while `standard`
handles the heavy answers — see `Examples/MultiModelGeneration` for a runnable,
two-model demo.

## `standard` and `flash` are always two different models

The `standard` and `flash` slots of one resolved profile never use the same
model. A synchronous tool call, for example the multitool `searchTools`, runs a
selection call on `flash` inside an open submission on `standard`. Each model
has one FIFO work queue, so one model in both slots would wait on itself.

`Router.resolve` skips, in the `flash` list, the model that `standard` chose,
and takes the next `flash` candidate. When the `standard` and `flash` lists
name only the same one model, `Router.resolve` throws before it loads a model.
Give the `flash` slot at least one candidate that is not the `standard` model.

## Residency is process-wide

The model pool and the model hold come from the core `FoundationModelsExtras`
package: `ModelPool` and `ModelHold`. `FoundationModelsRouter` exports the
name `ModelPool`, so `import FoundationModelsRouter` is sufficient to write
`ModelPool.shared` or `Router(pool: ModelPool())`.

One pool serves the whole process by default: `ModelPool.shared`. The router
is one user of that pool. The tool registry and the multitool of
`FoundationModelsExtras` are other users. All users share the same loaded
models: when two users name one model, the pool loads that model one time and
counts its weights one time. The first loader of a model wins. A later user
gets the container of that loader.

Each load of a new model and each eviction is one job in the FIFO admission
queue of the pool. `Router.resolve` measures the footprint of the pool, fits
the profile, and loads each slot in one admission job. Thus no other load and
no eviction occurs between the measurement and the loads.

Each handle of a resolved profile keeps the three model holds of its resolve.
A model stays resident while a profile, a handle of that profile, or a hold
of another user still exists anywhere in the process. There is no release
call. When the last hold of a model goes, the pool submits an eviction job. A
dropped `Router` frees nothing. Read `ModelPool.residentModelCount` to see how
many models the process holds.

The last release puts the eviction job in the admission queue of the pool in
the same step. A resolve that starts immediately after the drop of the last
reference thus runs after the eviction, and sees the freed memory. A
synchronous read of `ModelPool.residentModelCount` immediately after the drop
can still count the model, because the eviction job has not run yet. To see
the freed memory, read the footprint in an admission job:
`try await pool.admit { $0.footprint }`.

Pass a fresh pool to `Router(pool:)` to give a router an isolated pool and an
isolated budget. Pass `Router(samplingMode:)` to set the decoding strategy of
a router; two routers over one shared model each decode with their own mode.
Forks are not counted: any number of forks over one model can exist at once.

## Install

The package needs macOS 27 or later. Declare that floor in your `Package.swift`:

```swift
platforms: [.macOS("27.0")],
```

SwiftPM applies macOS 12.0 when your manifest states no floor. The build then
fails.

The example above needs three packages. Add them to the `dependencies` list in
`Package.swift`:

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsRouter", branch: "main"),
.package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
.package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
```

Then link three products from your own target:

```swift
.product(name: "FoundationModelsRouter", package: "FoundationModelsRouter"),
.product(name: "HuggingFace", package: "swift-huggingface"),
.product(name: "Tokenizers", package: "swift-transformers"),
```

The `#hubDownloader()` and `#huggingFaceTokenizerLoader()` macros expand to code
that calls `HuggingFace` and `Tokenizers`. Your target must link both products.
The router package does not link them for you.

## Documentation

Every public API has a worked example in
[`Tests/FoundationModelsRouterTests/ExamplesTests.swift`](Tests/FoundationModelsRouterTests/ExamplesTests.swift) —
resolution, sessions, streaming, guided (grammar-constrained) generation,
embeddings, forking, and residency. A runnable, real-model demo lives in
[`Examples/MultiModelGeneration`](Examples/MultiModelGeneration).

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
