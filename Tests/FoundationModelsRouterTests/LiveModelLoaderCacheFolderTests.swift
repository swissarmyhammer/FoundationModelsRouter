import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Proves which Hugging Face cache folder a ``LiveModelLoader`` uses (task
/// ^1056ce6). A host gives the folder, for example a folder in Application
/// Support, and the Extras `MLXModelLoader` of the live loader downloads to
/// that folder and reads the weights from it.
///
/// No test downloads. Each test writes a fake snapshot into a temporary
/// folder and measures it through the public `footprintBytes(of:)` of the
/// model loader, which reads the same cache as the download.
///
/// The suite is serialized: one test sets `HF_HUB_CACHE` and `HF_HOME` for
/// the process while it makes its loader, and the other test reads the
/// default cache, which these variables select.
@Suite("Cache folder of the live loader", .serialized)
struct LiveModelLoaderCacheFolderTests {
    // MARK: - Fixed values

    /// The model of the fake snapshot. The default Hugging Face cache does
    /// not hold it.
    private static let ref: ModelRef = "router-tests/cache-folder-model"

    /// The commit of the fake snapshot. The `main` ref file names it.
    private static let commit = "0123456789abcdef0123456789abcdef01234567"

    /// The bytes of the weight file in the folder that the host gives.
    private static let givenFolderWeightBytes = 4_321

    /// The bytes of the weight file in the folder that the environment
    /// names. They are not ``givenFolderWeightBytes``, thus the measure tells
    /// which folder the loader read.
    private static let environmentFolderWeightBytes = 8_765

    /// The name of the one weight file. The loader measures each file with
    /// the `safetensors` extension.
    private static let weightFileName = "model.safetensors"

    /// The ref that the loader reads when the model names no revision.
    private static let mainRef = "main"

    /// The environment variables that select the default Hugging Face cache.
    private static let cacheVariables = ["HF_HUB_CACHE", "HF_HOME"]

    /// The pool key of the fake model.
    private static var key: ModelPoolKey { ModelPoolKey(ref: ref, role: .llm) }

    // MARK: - Tests

    @Test("a live loader with a cache folder measures the weights in that folder, also when HF_HOME names another")
    func cacheFolderHoldsTheWeights() async throws {
        let given = try Self.makeCacheWithSnapshot(weightBytes: Self.givenFolderWeightBytes)
        defer { try? FileManager.default.removeItem(at: given) }
        let other = try Self.makeCacheWithSnapshot(weightBytes: Self.environmentFolderWeightBytes)
        defer { try? FileManager.default.removeItem(at: other) }
        let loader = Self.withCacheVariables(naming: other) { LiveModelLoader(cacheDirectory: given) }

        let bytes = try await Self.mlxLoader(of: loader).footprintBytes(of: Self.key)

        #expect(bytes == Int64(Self.givenFolderWeightBytes))
    }

    @Test("a live loader with no cache folder does not read a snapshot in another folder")
    func noCacheFolderUsesTheDefaultCache() async throws {
        let folder = try Self.makeCacheWithSnapshot(weightBytes: Self.givenFolderWeightBytes)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loader = LiveModelLoader()

        await #expect(throws: MLXModelLoaderError.notInCache(key: Self.key, revision: Self.mainRef)) {
            try await Self.mlxLoader(of: loader).footprintBytes(of: Self.key)
        }
    }

    // MARK: - Fixtures

    /// The Extras model loader of `loader`.
    ///
    /// - Parameter loader: A live loader that the public init made.
    /// - Returns: Its `MLXModelLoader`.
    /// - Throws: When the model loader of `loader` is not an `MLXModelLoader`.
    private static func mlxLoader(of loader: LiveModelLoader) throws -> MLXModelLoader {
        try #require(loader.modelLoader as? MLXModelLoader)
    }

    /// Runs `body` while each of ``cacheVariables`` names `folder`, and then
    /// sets each variable back to its earlier value.
    ///
    /// - Parameters:
    ///   - folder: The folder that the variables name.
    ///   - body: The step that runs while the variables name `folder`.
    /// - Returns: What `body` returns.
    private static func withCacheVariables<Value>(naming folder: URL, _ body: () -> Value) -> Value {
        let earlier = cacheVariables.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for name in cacheVariables {
            setenv(name, folder.path, 1)
        }
        defer {
            for (name, value) in earlier {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        return body()
    }

    /// Makes a temporary Hugging Face cache folder that holds a fake snapshot
    /// of ``ref``: a `main` ref file that names ``commit``, and one weight
    /// file of `weightBytes` in the snapshot of that commit.
    ///
    /// - Parameter weightBytes: The bytes of the weight file.
    /// - Returns: The cache folder. The caller removes it.
    /// - Throws: The error of a file write, after the removal of the folder.
    private static func makeCacheWithSnapshot(weightBytes: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repo = folder.appendingPathComponent(
            "models--" + ref.repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
        let refs = repo.appendingPathComponent("refs", isDirectory: true)
        let snapshot = repo.appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(commit, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try Data(commit.utf8).write(to: refs.appendingPathComponent(mainRef, isDirectory: false))
            try Data(repeating: 0, count: weightBytes)
                .write(to: snapshot.appendingPathComponent(weightFileName, isDirectory: false))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }
}
