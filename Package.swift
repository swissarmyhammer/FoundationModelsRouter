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
// The fork is referenced by URL on its `stable` branch (see the `dependencies`
// list), so every checkout of the router — this machine, another machine, CI —
// builds against the same published fork rather than whatever working copy
// happens to sit beside it.
let mlxProducts: [Target.Dependency] = [
    .product(name: "MLXLMCommon", package: mlxPackage),
    .product(name: "MLXLLM", package: mlxPackage),
    // Linked for its model registry, not for vision. `loadModelContainer`
    // finds a factory through `ModelFactoryRegistry`, which resolves its
    // built-in trampolines with `NSClassFromString` — so a factory reaches
    // the registry only when its module is linked into the binary. Muse
    // Glimmer (`muse_glimmer`) is registered in `VLMModelFactory` alone, and
    // it is the model the gated suites load, so the router must link MLXVLM
    // or the id fails with `unsupportedModelType` after the full download.
    .product(name: "MLXVLM", package: mlxPackage),
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
            branch: "stable"
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
            path: "Sources/\(packageName)",
            // The DocC catalog (task ^j0pp9yp) is documentation input for
            // `docc`, not build input; the Swift Build backend does not
            // consume it, so it is excluded to keep the build warning-free.
            exclude: ["\(packageName).docc"]
        ),
        // Depends on the RealModelSupport target below as well, because the
        // hermetic proofs of that target's machinery — `RealModelHarnessTests`,
        // `ScriptedTurnSizingTests`, `RecordedFixtureRedactionTests` — load no
        // model and therefore live HERE, where every
        // `swift test --skip IntegrationTests` run measures them (task
        // ^cvsh3m9).
        .testTarget(
            name: "\(packageName)Tests",
            dependencies: [
                .target(name: packageName), .target(name: "\(packageName)TestSupport"),
                .target(name: "\(packageName)RealModelSupport"),
            ] + mlxProducts,
            path: "Tests/\(packageName)Tests"
        ),
        // Test-only support shared by the two real-model targets below. It
        // exists because `MetalLibraryTestBootstrap` has to run inside *each*
        // test process — `swift test` builds one `.xctest` per test target and
        // runs each in its own process, and the symlink it installs is placed
        // beside the running binary — while SwiftPM cannot share source
        // between two `.testTarget`s directly, and a `.testTarget` another
        // target depends on is compiled by `swift build -c release`, where its
        // `@testable import` cannot resolve. A plain `.target` both can
        // depend on is the only way to keep one copy of that code. It is
        // deliberately not part of any `product`, so nothing outside this
        // package can import it. It also carries `ToolTurnScenario` — the one
        // tool-using scenario, its transcript normalization, and the outcome
        // shape — which the ungated scripted suite and the gated real-model
        // suite each run and then compare against the other (task ^w8dzvee),
        // so the unit test target depends on it too.
        .target(
            name: "\(packageName)TestSupport",
            dependencies: [.target(name: packageName)],
            path: "Tests/\(packageName)TestSupport"
        ),
        // Test-only support for the suites that drive a REAL model (task
        // ^cvsh3m9): the load/profile harness (`RealModelContainer`,
        // `RealModelHarness`), the model roster (`RealModels`), the fold
        // wiring (`CompactionFold`), the round-trip script
        // (`CompactionRoundTripFixture`) and the checked-in recording
        // (`CompactionRecordingFixture`). A plain `.target` for the same
        // reason `\(packageName)TestSupport` is one: the two real-model test
        // targets below and the hermetic unit target all read these, SwiftPM
        // cannot share source between test targets, and a `.testTarget` that
        // another target depends on is compiled by `swift build -c release`,
        // where `@testable import` cannot resolve. The router symbols this
        // target needs beyond the public surface are `package`, which stops
        // at this package's own boundary — so, like its two sibling support
        // targets, it is deliberately not part of any `product` and nothing
        // outside this package can import it. It links the Hub client +
        // tokenizer products because `RealModelContainer` constructs a live
        // `LiveModelLoader` through the `MLXHuggingFace` macros.
        //
        // `Fixtures` is the checked-in recording
        // `RecordedTranscriptCompactionIntegrationTests` folds and
        // `RecordedFixtureRedactionTests` scans (tasks ^pfdrppj, ^4bb3mjv).
        // It lives here so both of those suites — one gated, one hermetic,
        // in two different test targets — read ONE copy through
        // `CompactionRecordingFixture`. `.copy` rather than `.process`,
        // because the directory nesting IS the recording's structure —
        // `TranscriptTree.load(under:)` reads a session's id from its own
        // directory name and its parent from the directory it nests under,
        // so a rule that flattened or renamed anything would make the
        // fixture unreadable. `Fixtures/CompactionRecording/README.md`
        // states the layout and points at `RecordCompactionFixture`, the
        // tool that records the fixture again.
        .target(
            name: "\(packageName)RealModelSupport",
            dependencies: [
                .target(name: packageName)
            ] + mlxProducts + hubProducts,
            path: "Tests/\(packageName)RealModelSupport",
            resources: [.copy("Fixtures")]
        ),
        // The real-model suites (milestone 7): they download real models and run
        // them end to end. The TARGET is what selects them, and no suite inside
        // reads an environment variable — `swift test --filter
        // IntegrationTests` asks for them and `swift test --skip
        // IntegrationTests` leaves them out, one name for the whole set
        // because `FoundationModelsRouterEvalIntegrationTests` below shares
        // the `IntegrationTests` suffix. See `README.md` for the exact
        // commands and for what CI
        // runs. It links the Hub client + tokenizer products to construct a live
        // `LiveModelLoader` through the `MLXHuggingFace` macros.
        .testTarget(
            name: "\(packageName)IntegrationTests",
            dependencies: [
                .target(name: packageName), .target(name: "\(packageName)TestSupport"),
                .target(name: "\(packageName)RealModelSupport"),
            ] + mlxProducts + hubProducts,
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
        // §4), with real tool traffic (task 4ce0a1k): open a `RoutedSession`
        // vended with sample tools (`SampleTools.swift`) and a tiny
        // auto-compaction `TokenBudget` (task 8213x39), drive scripted turns
        // — fixture reads and explicit tool calls — while `contextFill`
        // climbs, let the budget fold automatically at the 0.80 trigger, keep
        // talking to the same session, then restore it from disk. `Fixtures`
        // is excluded alongside `README.md` — the demo reads those files from
        // disk at run time (relative to its own source file) rather than
        // bundling them as SwiftPM resources. Links the same Hub client +
        // tokenizer products as `MultiModelGeneration`, since it also
        // resolves a real profile through `LiveModelLoader`.
        .executableTarget(
            name: "CompactionDemo",
            dependencies: [.target(name: packageName)] + mlxProducts + hubProducts,
            path: "Examples/CompactionDemo",
            exclude: ["README.md", "Fixtures"]
        ),
        // The regeneration tool for the checked-in compaction recording (task
        // ^4bb3mjv): `swift run RecordCompactionFixture` records the fixture
        // under `Tests/.../Fixtures/CompactionRecording/` again — the six
        // scripted turns, the redaction settings and the redaction scan are
        // code here rather than prose in the fixture's README. An executable
        // rather than a test, because the run drives the 30B real model for
        // minutes, and every integration test must finish in under two. It
        // depends on the TestSupport target for the shared redaction scan and
        // entry-kind vocabulary the integration suites also read, and links
        // the same Hub client + tokenizer products as the demos, since it
        // resolves a real profile through `LiveModelLoader`.
        .executableTarget(
            name: "RecordCompactionFixture",
            dependencies: [
                .target(name: packageName), .target(name: "\(packageName)TestSupport"),
            ] + mlxProducts + hubProducts,
            path: "Tools/RecordCompactionFixture",
            exclude: ["README.md"]
        ),
        // The compaction evals' machinery (compaction_plan.md §5):
        // `CompactionEvaluation` plants facts in the head of hand-written seed
        // transcripts, folds with the `CompactionPrompt` under test, resumes a
        // session over the result, and asks a question answerable only from the
        // folded content — plus the datasets, the fact-retention report, the
        // progress log and the measured tier limits.
        //
        // A plain `.target` rather than part of either eval test target below,
        // because BOTH of them read it: the hermetic tests hold the machinery to
        // its own contract, and the real-model tier runs it against a model.
        // SwiftPM refuses to share a source file between two targets
        // (`has overlapping sources`), and a `.testTarget` that another target
        // depends on is compiled by `swift build -c release`, where a
        // `@testable import` cannot resolve — so a plain target is the only
        // shape that serves both. Nothing here uses `@testable`; the two router
        // symbols it needs beyond the public surface — `TranscriptTurns` and
        // `Compactor.estimatedTokenCount(of:)` — are `package`, which stops at
        // this package's own boundary.
        //
        // `import Evaluations` needs no extra linker/search-path configuration:
        // the toolchain's test-only framework search path reaches a plain
        // `.target` as well as a `.testTarget` (measured on a throwaway package,
        // which builds a bare `import Evaluations` in each with zero unsafe
        // flags).
        .target(
            name: "\(packageName)EvalSupport",
            dependencies: [.target(name: packageName)],
            path: "Tests/\(packageName)EvalSupport"
        ),
        // The evals' hermetic tests: they hold the machinery above to its own
        // contract — the dataset's shape, the report's classification, the
        // progress lines, the seed sizing and the tier thresholds — with no real
        // model anywhere. They run on every `swift test`. TestSupport is a
        // dependency for `ConcurrencyPeakObserver`, the one concurrency counter
        // every suite that must measure overlap uses.
        .testTarget(
            name: "FoundationModelsRouterEvals",
            dependencies: [
                .target(name: packageName), .target(name: "\(packageName)TestSupport"),
                .target(name: "\(packageName)EvalSupport"),
            ] + mlxProducts,
            path: "Tests/FoundationModelsRouterEvals"
        ),
        // The evals' real-model tiers, selected by target exactly as
        // `FoundationModelsRouterIntegrationTests` is: this name shares the
        // `IntegrationTests` suffix, so one `--filter` asks for
        // both targets and one `--skip` leaves both out. A target of its own
        // rather than suites inside the target above, because each `.xctest`
        // runs in its own process and `GatedEvalSerialGate` bounds residency
        // within a process — one target for the evals keeps that gate covering
        // exactly the suites it was measured against. Links the same Hub client
        // + tokenizer products as the other real-model target, since a real eval
        // also resolves a real profile through `LiveModelLoader`.
        .testTarget(
            name: "\(packageName)EvalIntegrationTests",
            dependencies: [
                .target(name: packageName), .target(name: "\(packageName)TestSupport"),
                .target(name: "\(packageName)EvalSupport"),
            ] + mlxProducts + hubProducts,
            path: "Tests/\(packageName)EvalIntegrationTests"
        ),
    ]
)
