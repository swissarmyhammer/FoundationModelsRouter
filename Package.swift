// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Repeated identifiers extracted to named constants so the manifest has a single
// source of truth: the dependency package names and this package's own name.
let mlxPackage = "mlx-swift-lm"
let ulidPackage = "ULID.swift"
let packageName = "FoundationModelsRouter"

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
// The fork is pinned to the `mlx-foundationmodels` branch and locked to a
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
            url: "https://github.com/swissarmyhammer/\(mlxPackage)",
            branch: "mlx-foundationmodels"
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
            dependencies: mlxProducts + [ulidProduct],
            path: "Sources/\(packageName)"
        ),
        .testTarget(
            name: "\(packageName)Tests",
            dependencies: [.target(name: packageName)] + mlxProducts,
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
    ]
)
