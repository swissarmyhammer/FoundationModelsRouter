import Foundation

@testable import FoundationModelsRouter

/// Builds a fake Hugging Face cache folder for the tests of the live model
/// loader. The layout is the one that the Extras `HubModelLoader` reads:
/// `models--<org>--<name>/refs/main` names a commit, and
/// `models--<org>--<name>/snapshots/<commit>` holds the files.
///
/// Every suite that needs a fake cache calls ``make(ref:commit:files:)``, so
/// the layout lives in one place.
enum FakeHubCache {
    /// The ref file that the loader reads when a model names no revision.
    private static let mainRefName = "main"

    /// Makes a temporary cache folder that holds a fake snapshot of `ref`: a
    /// `main` ref file that names `commit`, and the given files in the
    /// snapshot of that commit.
    ///
    /// - Parameters:
    ///   - ref: The model of the fake snapshot.
    ///   - commit: The commit that the `main` ref file names.
    ///   - files: The path of each file in the snapshot, relative to the
    ///     snapshot, and its bytes.
    /// - Returns: The cache folder. The caller removes it.
    /// - Throws: The error of a file write, after the removal of the folder.
    static func make(ref: ModelRef, commit: String, files: [String: Int]) throws -> URL {
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
            try Data(commit.utf8).write(to: refs.appendingPathComponent(mainRefName, isDirectory: false))
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
