import Foundation
import FoundationModelsExtras

extension RepoMetadata {
    /// The name of the file that gives the attention architecture of an MLX model.
    private static let configFileName = "config.json"

    /// The tree type of a file.
    private static let fileEntryType = "file"

    /// Parses sizing metadata from a model folder on the disk.
    ///
    /// The folder is read as the Extras `HubModelLoader` reads it. The names at
    /// the top of the folder decide the format with
    /// ``HubModelFormat/detect(paths:)``, as the loader decides it for an
    /// embedding model, and the sizes of the files decide the weight bytes with
    /// the rules that a Hub tree listing gets: the largest `.mlpackage` folder
    /// for Core ML, and the sum of the `*.safetensors` files at the top of the
    /// folder for MLX. No Hub call is made, and no file is downloaded.
    ///
    /// A symbolic link is followed, because a folder of a Hub snapshot holds
    /// links to its files.
    ///
    /// - Parameter directory: The absolute path of the model folder.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the folder
    ///   does not exist, is empty or cannot be read, or lacks sizing inputs as
    ///   ``init(raw:repo:)`` describes.
    init(localDirectory directory: URL) throws {
        let names = try Self.topLevelNames(of: directory)
        let configURL = directory.appending(path: Self.configFileName, directoryHint: .notDirectory)
        let configJSON = names.contains(Self.configFileName) ? try Data(contentsOf: configURL) : nil
        try self.init(
            entries: try Self.fileEntries(in: directory), format: HubModelFormat.detect(paths: names),
            configJSON: configJSON, repo: directory.path)
    }

    /// The names at the top of a model folder.
    ///
    /// - Parameter directory: The model folder.
    /// - Returns: The names of the files and folders at the top, never empty.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the folder
    ///   does not exist, cannot be read or is empty.
    private static func topLevelNames(of directory: URL) throws -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw RepoMetadataError.metadataUnavailable(
                "the local model folder \(directory.path) does not exist or cannot be read")
        }
        guard !names.isEmpty else {
            throw RepoMetadataError.metadataUnavailable("the local model folder \(directory.path) is empty")
        }
        return names
    }

    /// Every file under a model folder, with its size.
    ///
    /// - Parameter directory: The model folder.
    /// - Returns: One entry for each file at any depth, with its path relative
    ///   to the folder. A folder has no entry.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the
    ///   folder cannot be read.
    private static func fileEntries(in directory: URL) throws -> [TreeEntry] {
        do {
            return try FileManager.default.subpathsOfDirectory(atPath: directory.path).compactMap { subpath in
                let file = directory.appending(path: subpath, directoryHint: .notDirectory).resolvingSymlinksInPath()
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
                return TreeEntry(
                    type: fileEntryType, path: subpath, size: (attributes[.size] as? NSNumber)?.int64Value, lfs: nil)
            }
        } catch {
            throw RepoMetadataError.metadataUnavailable(
                "the files of the local model folder \(directory.path) cannot be read: \(error.localizedDescription)")
        }
    }
}
