// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Products from the controlled fork of mlx-swift-lm that the router builds on.
// The fork is pinned to the `mlx-foundationmodels` branch and locked to a
// specific commit via Package.resolved (committed, not ignored).
let mlxProducts: [Target.Dependency] = [
    .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
    .product(name: "MLXLLM", package: "mlx-swift-lm"),
    .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
    .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
    .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
    .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
]

let package = Package(
    name: "FoundationModelsRouter",
    // Commit to macOS 27 / FoundationModels v2; no pre-27 fallback.
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(
            name: "FoundationModelsRouter",
            targets: ["FoundationModelsRouter"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/swissarmyhammer/mlx-swift-lm",
            branch: "mlx-foundationmodels"
        )
    ],
    targets: [
        .target(
            name: "FoundationModelsRouter",
            dependencies: mlxProducts,
            path: "Sources/FoundationModelsRouter"
        ),
        .testTarget(
            name: "FoundationModelsRouterTests",
            dependencies: ["FoundationModelsRouter"] + mlxProducts,
            path: "Tests/FoundationModelsRouterTests"
        ),
        // Gated, real-model suite (milestone 7). Placeholder for now; the
        // integration tests that exercise real model downloads live here.
        .testTarget(
            name: "FoundationModelsRouterIntegrationTests",
            dependencies: ["FoundationModelsRouter"] + mlxProducts,
            path: "Tests/FoundationModelsRouterIntegrationTests"
        ),
    ]
)
