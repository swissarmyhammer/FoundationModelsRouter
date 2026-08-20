// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// The real-model test targets live in this nested package, and the root
// package declares no integration target. The package boundary is what
// separates the hermetic tests from the real-model tests:
//
// - `swift test` at the repository root runs ONLY the hermetic tests, by
//   construction — no `--skip`, no name regex, and no guard script.
// - `swift test --package-path IntegrationTests` runs the real-model tests.
//   Use `--filter` inside this package to run one tier.
//
// The dependency pins below restate the root manifest's pins because SwiftPM
// manifests cannot import each other. The two manifests must converge on one
// resolution: this package depends on the root package by path, so a pin here
// that conflicted with the root's would fail to resolve.
let routerPackage = "FoundationModelsRouter"
let mlxPackage = "mlx-swift-lm"
let huggingFacePackage = "swift-huggingface"
let transformersPackage = "swift-transformers"

// The router package's products: the library under test and the three test
// support libraries the root package publishes for this package (see the
// root manifest's `products` list).
let routerProducts: [Target.Dependency] = [
    .product(name: routerPackage, package: routerPackage),
    .product(name: "\(routerPackage)TestSupport", package: routerPackage),
    .product(name: "\(routerPackage)RealModelSupport", package: routerPackage),
]

// Products from the controlled fork of mlx-swift-lm, the same list the root
// package's test targets link. See the root manifest for what each one is for.
let mlxProducts: [Target.Dependency] = [
    .product(name: "MLXLMCommon", package: mlxPackage),
    .product(name: "MLXLLM", package: mlxPackage),
    .product(name: "MLXVLM", package: mlxPackage),
    .product(name: "MLXEmbedders", package: mlxPackage),
    .product(name: "MLXHuggingFace", package: mlxPackage),
    .product(name: "MLXFoundationModels", package: mlxPackage),
    .product(name: "MLXGuidedGeneration", package: mlxPackage),
]

// The Hub client + tokenizer products every real-model target links, to
// construct a live `LiveModelLoader` through the `MLXHuggingFace` macros.
let hubProducts: [Target.Dependency] = [
    .product(name: "HuggingFace", package: huggingFacePackage),
    .product(name: "Tokenizers", package: transformersPackage),
]

let package = Package(
    name: "IntegrationTests",
    // Commit to macOS 27 / FoundationModels v2, the same floor as the root
    // package.
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: ".."),
        .package(
            url: "https://github.com/swissarmyhammer/\(mlxPackage)",
            branch: "stable"
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
        // The real-model suites (milestone 7): they download real models and
        // run them end to end. Selection is structural: this target exists
        // only in this package, so a root `swift test` cannot see it.
        .testTarget(
            name: "\(routerPackage)IntegrationTests",
            dependencies: routerProducts + mlxProducts + hubProducts,
            path: "Tests/\(routerPackage)IntegrationTests"
        ),
        // The evals' real-model tiers. A target of its own rather than suites
        // inside the target above, because each `.xctest` runs in its own
        // process and `GatedEvalSerialGate` bounds residency within a process —
        // one target for the evals keeps that gate covering exactly the suites
        // it was measured against.
        .testTarget(
            name: "\(routerPackage)EvalIntegrationTests",
            dependencies: routerProducts + [
                .product(name: "\(routerPackage)EvalSupport", package: routerPackage)
            ] + mlxProducts + hubProducts,
            path: "Tests/\(routerPackage)EvalIntegrationTests"
        ),
    ]
)
