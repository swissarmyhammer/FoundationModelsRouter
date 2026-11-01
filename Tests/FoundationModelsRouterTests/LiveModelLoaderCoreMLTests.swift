import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Proves that the live loader loads a Core ML repository: the public init
/// makes the Extras `HubModelLoader`, which routes an embedding key to Core ML
/// when the repository holds a `.mlpackage` folder and no `safetensors` file,
/// and everything else to MLX.
///
/// No test downloads and no test loads a model. Each test writes a fake
/// snapshot into a temporary Hugging Face cache and measures it through the
/// public `footprintBytes(of:)` of the model loader, which picks the loader of
/// the snapshot by its files.
@Suite("Core ML in the live loader")
struct LiveModelLoaderCoreMLTests {
    /// The model of the fake snapshot.
    private static let ref: ModelRef = "router-tests/coreml-embedder"

    /// The commit of the fake snapshot. The `main` ref file names it.
    private static let commit = "0123456789abcdef0123456789abcdef01234567"

    /// The ref that the loader reads when the model names no revision.
    private static let mainRef = "main"

    /// The bytes of the weight file of the fake package.
    private static let packageWeightBytes = 2_048

    /// The bytes of the `safetensors` file of the MLX snapshot.
    private static let safetensorsBytes = 4_096

    /// The files of a fake Core ML package, relative to the snapshot. The
    /// loader measures each `.bin` file in a `weights` folder.
    private static let packageWeightPath = "embed.mlpackage/Data/com.apple.CoreML/weights/weight.bin"

    /// The name of a `safetensors` file of an MLX snapshot.
    private static let safetensorsPath = "model.safetensors"

    @Test("the public init of the live loader makes the Extras HubModelLoader")
    func publicInitMakesAHubModelLoader() throws {
        _ = try LiveModelLoader().requireHubModelLoader()
    }

    @Test("an embedding key whose cached repository holds a .mlpackage folder is measured by its package")
    func coreMLSnapshotIsMeasuredAsAPackage() async throws {
        let cache = try Self.makeCache(files: [Self.packageWeightPath: Self.packageWeightBytes])
        defer { try? FileManager.default.removeItem(at: cache) }
        let loader = LiveModelLoader(cacheDirectory: cache)

        let bytes = try await loader.footprintBytes(of: ModelPoolKey(ref: Self.ref, role: .embedding))

        #expect(bytes == Int64(Self.packageWeightBytes))
    }

    @Test("an embedding key whose cached repository holds safetensors weights is measured as an MLX model")
    func safetensorsSnapshotIsMeasuredAsMLX() async throws {
        let cache = try Self.makeCache(files: [Self.safetensorsPath: Self.safetensorsBytes])
        defer { try? FileManager.default.removeItem(at: cache) }
        let loader = LiveModelLoader(cacheDirectory: cache)

        let bytes = try await loader.footprintBytes(of: ModelPoolKey(ref: Self.ref, role: .embedding))

        #expect(bytes == Int64(Self.safetensorsBytes))
    }

    @Test("a generation key is measured as an MLX model, also when the repository holds a .mlpackage folder")
    func generationKeyIsAlwaysMLX() async throws {
        let cache = try Self.makeCache(files: [
            Self.packageWeightPath: Self.packageWeightBytes, Self.safetensorsPath: Self.safetensorsBytes,
        ])
        defer { try? FileManager.default.removeItem(at: cache) }
        let loader = LiveModelLoader(cacheDirectory: cache)

        let bytes = try await loader.footprintBytes(of: ModelPoolKey(ref: Self.ref, role: .llm))

        #expect(bytes == Int64(Self.safetensorsBytes))
    }

    // MARK: - Fixtures

    /// Makes a temporary Hugging Face cache folder that holds a fake snapshot
    /// of ``ref``: a `main` ref file that names ``commit``, and the given
    /// files in the snapshot of that commit.
    ///
    /// - Parameter files: The path of each file in the snapshot, relative to
    ///   the snapshot, and its bytes.
    /// - Returns: The cache folder. The caller removes it.
    /// - Throws: The error of a file write, after the removal of the folder.
    private static func makeCache(files: [String: Int]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repo = folder.appendingPathComponent(
            "models--" + ref.repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        let refs = repo.appendingPathComponent("refs", isDirectory: true)
        let snapshot = repo.appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(commit, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            try Data(commit.utf8).write(to: refs.appendingPathComponent(mainRef, isDirectory: false))
            for (path, bytes) in files {
                let file = snapshot.appendingPathComponent(path, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0, count: bytes).write(to: file)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }
}
