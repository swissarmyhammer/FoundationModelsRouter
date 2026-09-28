import Foundation
import Testing

/// The layout rules of the telemetry of the repository (the OpenTelemetry
/// design of 2026-09-28): the library uses the telemetry APIs only, no
/// package depends on swift-otel, no source uses unified logging, and each
/// executable sends its log records to standard error.
///
/// Each test reads the files of the repository from the disk, from the root
/// that ``RepositoryRoot/url(from:)`` finds.
@Suite("The telemetry layout of the repository")
struct TelemetryLayoutTests {
    /// The repository root.
    private static let root = RepositoryRoot.url()

    /// The directories that hold Swift sources of the repository.
    private static let sourceDirectories = ["Sources", "Tests", "IntegrationTests", "Examples", "Tools"]

    /// The source text of each unified-logging API that the repository must
    /// not use. Each entry is split in two parts, so that this file does not
    /// hold the text that it looks for.
    private static let unifiedLoggingTexts = [
        "import " + "os\n", "import " + "OSLog", "os." + "Logger", "OSLog" + "Store", "OSSign" + "poster",
    ]

    /// The two forms in which a manifest names the swift-otel package as a
    /// dependency: in its URL, and as the package name of a product.
    private static let swiftOTelDependencyTexts = ["/swift-otel", "\"swift-otel\""]

    /// The main source file of each executable of the repository.
    private static let executableMainFiles = [
        "Examples/MultiModelGeneration/main.swift",
        "Examples/CompactionDemo/main.swift",
        "Tools/RecordCompactionFixture/main.swift",
    ]

    /// The call that sends the log records of an executable to standard
    /// error.
    private static let standardErrorBootstrap = "LoggingSystem.bootstrap(StreamLogHandler.standardError)"

    /// Each file under `directory` whose name ends with `suffix`, with no
    /// file of a build directory or of a hidden directory.
    ///
    /// - Parameters:
    ///   - directory: The directory to walk.
    ///   - suffix: The end of each file name to keep.
    /// - Returns: The files, in no fixed order.
    private static func files(under directory: URL, endingWith suffix: String) -> [URL] {
        let walk = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (walk?.allObjects as? [URL] ?? []).filter { file in
            file.lastPathComponent.hasSuffix(suffix) && !file.path.contains("/.build/")
        }
    }

    @Test("no Package.swift of the repository names swift-otel")
    func noManifestNamesSwiftOTel() throws {
        let manifests = Self.files(under: Self.root, endingWith: "Package.swift")
        #expect(manifests.count >= 2, "the walk found no nested manifest: \(manifests)")
        for manifest in manifests {
            let text = try String(contentsOf: manifest, encoding: .utf8)
            for dependency in Self.swiftOTelDependencyTexts {
                #expect(!text.contains(dependency), "\(manifest.path) names swift-otel as \(dependency)")
            }
        }
    }

    @Test("no Swift source of the repository uses unified logging")
    func noSourceUsesUnifiedLogging() throws {
        let sources = Self.sourceDirectories.flatMap { directory in
            Self.files(under: Self.root.appendingPathComponent(directory), endingWith: ".swift")
        }
        #expect(!sources.isEmpty)
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            for forbidden in Self.unifiedLoggingTexts {
                #expect(!text.contains(forbidden), "\(source.path) holds \(forbidden)")
            }
        }
    }

    @Test("each executable sends its log records to standard error")
    func eachExecutableLogsToStandardError() throws {
        for mainFile in Self.executableMainFiles {
            let text = try String(contentsOf: Self.root.appendingPathComponent(mainFile), encoding: .utf8)
            #expect(text.contains(Self.standardErrorBootstrap), "\(mainFile) does not bootstrap logging to stderr")
        }
    }
}
