// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Repeated identifiers extracted to named constants so the manifest has a single
// source of truth: the dependency package names and this package's own name.
let mlxPackage = "mlx-swift-lm"
let ulidPackage = "ULID.swift"
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

// Time-sortable identifier library (yaslab/ULID.swift). Our `Core/ULID.swift`
// re-exports this module and adds a thin compatibility shim, so the router's
// `ULID` API surface stays the same while correctness lives in the library.
let ulidProduct: Target.Dependency = .product(name: "ULID", package: ulidPackage)

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
        // Gated, real-model suite (milestone 7). Placeholder for now; the
        // integration tests that exercise real model downloads live here.
        .testTarget(
            name: "\(packageName)IntegrationTests",
            dependencies: [.target(name: packageName)] + mlxProducts,
            path: "Tests/\(packageName)IntegrationTests"
        ),
    ]
)
