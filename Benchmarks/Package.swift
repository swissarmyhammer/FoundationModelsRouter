// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// The benchmarks live in this nested package, so no CI job builds or runs
// them. The shared swift-ci workflow builds the root package and the nested
// `IntegrationTests/` package (the one `integration-package-path` names), and
// nothing else. A benchmark downloads real weights and holds the GPU for
// minutes, and its numbers depend on the machine, so it has no pass or fail
// for CI to check.
//
// Run it from the repository root:
//
//     swift run -c release --package-path Benchmarks RouterBenchmark --model <ref>
//
// The manifest depends on the root package by path, as the `IntegrationTests/`
// manifest does.
let routerPackage = "FoundationModelsRouter"

let package = Package(
    name: "Benchmarks",
    // Commit to macOS 27 / FoundationModels v2, the same floor as the root
    // package.
    platforms: [
        .macOS("27.0")
    ],
    dependencies: [
        .package(path: ".."),
        // The logging API that the executable bootstraps to standard error.
        // The same pin as the root manifest.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
    ],
    targets: [
        // Times the generation of the `standard` model of a profile: the
        // prefill, the time to the first token and the decode rate. See
        // `RouterBenchmark/README.md`.
        .executableTarget(
            name: "RouterBenchmark",
            dependencies: [
                .product(name: routerPackage, package: routerPackage),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "RouterBenchmark",
            exclude: ["README.md"]
        )
    ]
)

// C++ interop on every target: the router links the Extras GGUF loader, whose
// llama.cpp modules require it in each module that imports the router (see the
// same loop at the end of the root manifest).
for target in package.targets where target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.interoperabilityMode(.Cxx)]
}
