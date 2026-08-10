import Foundation

/// Installs the `mlx.metallib` symlink that lets mlx-swift find its compiled
/// shaders when this package's gated suites run under a plain `swift test`.
///
/// mlx-swift's Metal backend (`Cmlx`, `mlx/backend/metal/device.cpp`,
/// `load_default_library`) locates its shader library by probing, in order:
/// (1) `<binary-dir>/mlx.metallib`, where `<binary-dir>` comes from a `dladdr`
/// lookup on the statically-linked `Cmlx` code — that is, whichever Mach-O
/// binary that code was linked into, here the executing test binary;
/// (2) `<binary-dir>/Resources/mlx.metallib`; (3) a SwiftPM resource bundle
/// reachable from the main bundle or from any bundle in `Bundle.allBundles` /
/// `Bundle.allFrameworks`; (4) `<binary-dir>/Resources/default.metallib`;
/// (5) a working-directory-relative `default.metallib`.
///
/// SwiftPM builds the shader library into
/// `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`, colocated with
/// each `.xctest` bundle. Under `xcodebuild test` the launched process's main
/// bundle and working directory satisfy one of the probes above, so loading
/// just works. Under a plain `swift test` the running binary sits at
/// `<Target>.xctest/Contents/MacOS/<Target>`, two directory levels away from
/// `<Target>.xctest/Contents/Resources/mlx-swift_Cmlx.bundle/…` — every probe
/// misses, and the first GPU-device `MLXArray` evaluation aborts the whole
/// test process with "MLX error: Failed to load the default metallib". That is
/// precisely what `FM_ROUTER_INTEGRATION_TESTS=1 swift test` used to hit the
/// moment a gated suite resolved a live model.
///
/// This bootstrap closes the gap at its source: it finds the resource bundle
/// SwiftPM already built and creates the `mlx.metallib` symlink probe (1)
/// looks for. It is idempotent (an existing symlink is left alone) and a
/// harmless no-op under `xcodebuild`, where an earlier probe already wins.
///
/// The symlink goes beside the binary that reads this property, so each gated
/// test target has to trigger it from inside its own process. This module
/// exists so both of them share one implementation: `swift test` builds a
/// separate `.xctest` per test target and runs each in its own process, and
/// SwiftPM cannot share source between two test targets directly.
///
/// Ported from the sibling `FoundationModelsMultitool` package, which resolves
/// the same `mlx-swift`/`Cmlx` dependency and so carries the same defect.
public enum MetalLibraryTestBootstrap {

    /// Installs the symlink exactly once per test process.
    ///
    /// Reading this property is the trigger — `static let` gives Swift's
    /// once-only, thread-safe initialization, so repeat reads cost nothing. It
    /// must be read before anything in the process evaluates a GPU-device
    /// `MLXArray`.
    ///
    /// Each gated target reads it from exactly one place, and that place is a
    /// suite-scoped `TestScoping` trait rather than a test body:
    /// `GatedRealModelSuiteTrait` in `FoundationModelsRouterIntegrationTests`
    /// and `GatedEvalResidencyTrait` in `FoundationModelsRouterEvals`. A trait
    /// written once on the `@Suite` line cannot be forgotten by a test the
    /// suite later gains, and a suite's scope wraps every test-level trait, so
    /// the symlink is in place even for a trait that reaches the GPU ahead of
    /// the `@Test` body — which is what `.evaluates(...)` does.
    public static let ensureColocatedMetallib: Void = {
        do {
            try installSymlinkIfNeeded()
        } catch {
            // Best-effort: without the symlink, mlx's own "Failed to load the
            // default metallib" error surfaces on the first GPU evaluation,
            // exactly as it did before this bootstrap existed.
            logError("MetalLibraryTestBootstrap: \(error)")
        }
    }()

    /// Anchor whose only job is to give `Bundle(for:)` a class defined in this
    /// test binary, identifying the `.xctest` bundle the binary was built into.
    ///
    /// `Bundle(for:)` accepts any class, so this need not be a test case. A
    /// class (not a `struct`) is required because `Bundle(for:)` takes an
    /// `AnyClass`.
    private final class BundleAnchor {}

    /// Name of the SwiftPM resource bundle mlx-swift builds its shaders into.
    private static let resourceBundleName = "mlx-swift_Cmlx.bundle"

    /// Path of the shader library inside ``resourceBundleName``.
    private static let metallibRelativePath = "Contents/Resources/default.metallib"

    /// Name mlx's first probe looks for beside the running binary.
    private static let colocatedMetallibName = "mlx.metallib"

    /// Creates the colocated symlink unless it is already there.
    ///
    /// Each unmet precondition logs and returns rather than throwing, so a
    /// layout this bootstrap does not recognize degrades to the pre-existing
    /// mlx failure instead of masking it behind a bootstrap error.
    private static func installSymlinkIfNeeded() throws {
        guard let binaryDirectory = currentTestBinaryDirectory() else {
            logError(
                """
                MetalLibraryTestBootstrap: could not determine the running test \
                binary's directory; GPU-device tests may crash with "Failed to \
                load the default metallib".
                """)
            return
        }
        let symlinkURL = binaryDirectory.appendingPathComponent(colocatedMetallibName)
        if FileManager.default.fileExists(atPath: symlinkURL.path) { return }
        guard let metallibURL = locateDefaultMetallib(testBundle: Bundle(for: BundleAnchor.self))
        else {
            logError(
                """
                MetalLibraryTestBootstrap: could not locate \
                \(resourceBundleName)/default.metallib; GPU-device tests may crash \
                with "Failed to load the default metallib".
                """)
            return
        }
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: metallibURL)
    }

    /// Writes `message` to standard error, followed by a newline.
    private static func logError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// The directory holding the running test binary.
    ///
    /// Mirrors mlx's own `current_binary_dir()`, whose `dladdr` lookup on the
    /// statically-linked `Cmlx` code resolves to this very test executable.
    private static func currentTestBinaryDirectory() -> URL? {
        let bundle = Bundle(for: BundleAnchor.self)
        if let executableURL = bundle.executableURL {
            return executableURL.deletingLastPathComponent()
        }
        // Every macOS test/app bundle uses this layout; fall back to it if
        // `executableURL` is somehow unavailable.
        return bundle.bundleURL.appendingPathComponent("Contents/MacOS")
    }

    /// Finds `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`.
    ///
    /// Tries the fast, common case first — the bundle SwiftPM colocates inside
    /// `testBundle`'s own `Contents/Resources/` — then falls back to scanning
    /// every loaded bundle and framework the same way mlx's own
    /// `load_swiftpm_library` does. The fallback is what keeps this working
    /// across build layouts: `swift test` and `xcodebuild` place the bundle
    /// differently, as do different SwiftPM versions.
    ///
    /// - Parameter testBundle: The `.xctest` bundle the running binary belongs to.
    /// - Returns: The shader library's location, or `nil` if no candidate holds one.
    private static func locateDefaultMetallib(testBundle: Bundle) -> URL? {
        var candidateBases: [URL] = [
            testBundle.bundleURL.appendingPathComponent("Contents/Resources")
        ]
        candidateBases += Bundle.allBundles.map { $0.bundleURL }
        candidateBases += Bundle.allBundles.compactMap { $0.resourceURL }
        candidateBases += Bundle.allFrameworks.map { $0.bundleURL }
        candidateBases += Bundle.allFrameworks.compactMap { $0.resourceURL }

        for base in candidateBases {
            let metallibURL =
                base
                .appendingPathComponent(resourceBundleName)
                .appendingPathComponent(metallibRelativePath)
            if FileManager.default.fileExists(atPath: metallibURL.path) {
                return metallibURL
            }
        }
        return nil
    }
}
