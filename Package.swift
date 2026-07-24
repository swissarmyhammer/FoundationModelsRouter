// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Repeated identifiers extracted to named constants so the manifest has a single
// source of truth: the dependency package names and this package's own name.
let mlxPackage = "mlx-swift-lm"
let ulidPackage = "ULID.swift"
let packageName = "FoundationModelsRouter"

// The tool-events substrate (`OperationEvent`/`OperationEventSink`/
// `EventEmittingTool`): host-neutral vocabulary a `SessionOutbox` stores and a
// long-running `OperationTool` posts through, with no dependency back on this
// package (host -> substrate direction only). Lightweight — only the
// `Operations` product (protocols and plain value types) is needed, never
// `OperationsCLI`.
let operationToolPackage = "FoundationModelsOperationTool"
let operationsProduct: Target.Dependency = .product(name: "Operations", package: operationToolPackage)

// Hugging Face Hub client and tokenizer packages. The `mlx-foundationmodels`
// fork bundles no default Hub client: its `MLXHuggingFace` macros
// (`#hubDownloader()` / `#huggingFaceTokenizerLoader()`) expand to code that
// references `HuggingFace.HubClient` and `Tokenizers.AutoTokenizer`, so an
// integrator must supply these two packages to construct a live `Downloader` /
// `TokenizerLoader`. They are needed only by the gated integration suite that
// does real downloads (milestone 7); the library target injects the resulting
// loader and never imports these modules. Package/version pins mirror the fork's
// own `IntegrationTesting.xcodeproj`.
let huggingFacePackage = "swift-huggingface"
let transformersPackage = "swift-transformers"

// Products from the controlled fork of mlx-swift-lm that the router builds on.
// The fork is pinned to the `foundationmodels-fixes` branch and locked to a
// specific commit via Package.resolved (committed, not ignored).
let mlxProducts: [Target.Dependency] = [
    .product(name: "MLXLMCommon", package: mlxPackage),
    .product(name: "MLXLLM", package: mlxPackage),
    .product(name: "MLXEmbedders", package: mlxPackage),
    .product(name: "MLXHuggingFace", package: mlxPackage),
    .product(name: "MLXFoundationModels", package: mlxPackage),
    .product(name: "MLXGuidedGeneration", package: mlxPackage),
]

// Time-sortable identifier library (yaslab/ULID.swift). Our `Core/ULID.swift`
// re-exports this module and adds a thin compatibility shim, so the router's
// `ULID` API surface stays the same while correctness lives in the library.
let ulidProduct: Target.Dependency = .product(name: "ULID", package: ulidPackage)

// The Hub client + tokenizer products the gated integration suite injects into a
// live `LiveModelLoader` (via the `MLXHuggingFace` macros). Only the integration
// test target links these.
let hubProducts: [Target.Dependency] = [
    .product(name: "HuggingFace", package: huggingFacePackage),
    .product(name: "Tokenizers", package: transformersPackage),
]

let package = Package(
    name: packageName,
    // Commit to macOS 27 / FoundationModels v2; no pre-27 fallback.
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(
            name: packageName,
            targets: [packageName]
        )
    ],
    dependencies: [
        .package(
            url: "git@github.com:swissarmyhammer/\(mlxPackage).git",
            branch: "foundationmodels-fixes"
        ),
        .package(
            url: "git@github.com:swissarmyhammer/\(operationToolPackage).git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/yaslab/\(ulidPackage).git",
            from: "1.3.1"
        ),
        .package(
            url: "https://github.com/huggingface/\(huggingFacePackage)",
            from: "0.9.0"
        ),
        .package(
            url: "https://github.com/huggingface/\(transformersPackage)",
            from: "1.3.0"
        ),
    ],
    targets: [
        .target(
            name: packageName,
            dependencies: mlxProducts + [ulidProduct, operationsProduct],
            path: "Sources/\(packageName)"
        ),
        .testTarget(
            name: "\(packageName)Tests",
            dependencies: [.target(name: packageName)] + mlxProducts + [operationsProduct],
            path: "Tests/\(packageName)Tests"
        ),
        // Gated, real-model suite (milestone 7): downloads deliberately tiny
        // real models and runs them end to end, behind an opt-in env var so it
        // never fires on a network/GPU-less box. It links the Hub client +
        // tokenizer products to construct a live `LiveModelLoader` through the
        // `MLXHuggingFace` macros.
        .testTarget(
            name: "\(packageName)IntegrationTests",
            dependencies: [.target(name: packageName)] + mlxProducts + hubProducts,
            path: "Tests/\(packageName)IntegrationTests"
        ),
        // Runnable demo (live twin of the offline `ExamplesTests` example): one
        // `Router.resolve` makes two local generation models co-resident and the
        // program routes a quick turn to `profile.flash` and a heavyweight turn to
        // `profile.standard`. Links the same Hub client + tokenizer products as
        // the gated integration test target, since it also constructs a live
        // `LiveModelLoader` through the `MLXHuggingFace` macros.
        .executableTarget(
            name: "MultiModelGeneration",
            dependencies: [.target(name: packageName)] + mlxProducts + hubProducts,
            path: "Examples/MultiModelGeneration",
            exclude: ["README.md"]
        ),
        // Runnable demo of the compaction loop end to end (compaction_plan.md
        // §4): open a `RoutedSession`, drive scripted turns that read fixture
        // documents into the conversation while `contextFill` climbs, fold
        // with `session.compact()` at the 0.80 trigger, keep talking to the
        // same session, then restore it from disk. `Fixtures` is excluded
        // alongside `README.md` — the demo reads those files from disk at
        // run time (relative to its own source file) rather than bundling
        // them as SwiftPM resources. Links the same Hub client + tokenizer
        // products as `MultiModelGeneration`, since it also resolves a real
        // profile through `LiveModelLoader`.
        .executableTarget(
            name: "CompactionDemo",
            dependencies: [.target(name: packageName)] + mlxProducts + hubProducts,
            path: "Examples/CompactionDemo",
            exclude: ["README.md", "Fixtures"]
        ),
        // Compaction-quality evals (compaction_plan.md §5), on Apple's
        // Evaluations framework: `CompactionEvaluation` plants facts in the
        // head of hand-written seed transcripts, folds with the
        // `CompactionPrompt` under test, resumes a session over the result,
        // and asks a question answerable only from the folded content.
        // `import Evaluations` needs no extra linker/search-path
        // configuration here — SwiftPM's `.testTarget` automatically adds
        // the toolchain's test-only framework search path (the same one
        // that makes `import Testing`/`XCTest` work), which is where
        // `Evaluations.framework` itself lives (verified empirically: a
        // throwaway SwiftPM package with a bare `import Evaluations` in a
        // `.testTarget` builds and runs with zero unsafe flags). The one
        // real-model `@Test` inside is runtime-gated on
        // `FM_ROUTER_INTEGRATION_TESTS`, exactly like every other gated
        // suite in `FoundationModelsRouterIntegrationTests` — the target
        // itself always builds and its hermetic wiring tests always run
        // under a plain `swift test`. Links the same Hub client + tokenizer
        // products as the other gated suites, since the gated eval also
        // resolves a real profile through `LiveModelLoader`.
        .testTarget(
            name: "FoundationModelsRouterEvals",
            dependencies: [.target(name: packageName)] + mlxProducts + hubProducts,
            path: "Tests/FoundationModelsRouterEvals"
        ),
    ]
)
