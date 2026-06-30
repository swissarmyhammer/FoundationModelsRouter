// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Repeated identifiers extracted to named constants so the manifest has a single
// source of truth: the dependency package name and this package's own name.
let mlxPackage = "mlx-swift-lm"
let packageName = "FoundationModelsRouter"

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
        )
    ],
    targets: [
        .target(
            name: packageName,
            dependencies: mlxProducts,
            path: "Sources/\(packageName)"
        ),
        .testTarget(
            name: "\(packageName)Tests",
            dependencies: [.target(name: packageName)] + mlxProducts,
            path: "Tests/\(packageName)Tests"
        ),
        // Gated, real-model suite (milestone 7). Placeholder for now; the
        // integration tests that exercise real model downloads live here.
        .testTarget(
            name: "\(packageName)IntegrationTests",
            dependencies: [.target(name: packageName)] + mlxProducts,
            path: "Tests/\(packageName)IntegrationTests"
        ),
    ]
)
