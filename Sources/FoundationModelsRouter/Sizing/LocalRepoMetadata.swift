import Foundation
import FoundationModelsExtras

extension RepoMetadata {
    /// The name of the file that gives the attention architecture of an MLX model.
    private static let configFileName = "config.json"

    /// The tree type of a file.
    private static let fileEntryType = "file"

    /// Parses sizing metadata from a model on the disk: a `.gguf` file, a
    /// folder of GGUF files, or a folder of an MLX or a Core ML model.
    ///
    /// A `.gguf` file, and a folder whose files at any depth are GGUF as the
    /// Extras `HubModelFormat.detect(paths:)` rule decides, are sized by
    /// ``init(localGGUF:)``. Any other folder is sized by
    /// ``init(localDirectory:names:entries:)``. No Hub call is made.
    ///
    /// - Parameter location: The absolute path of the file or the folder.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the
    ///   location is a file that is not a `.gguf` file, or as the two
    ///   initializers describe.
    init(localLocation location: URL) async throws {
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: location.path, isDirectory: &isFolder)
        if exists && !isFolder.boolValue {
            guard location.pathExtension == GGUFFileSet.fileExtension else {
                throw RepoMetadataError.metadataUnavailable(
                    "the local model \(location.path) is a file that is not a .\(GGUFFileSet.fileExtension) file")
            }
            try await self.init(localGGUF: location)
            return
        }
        let names = try Self.topLevelNames(of: location)
        let entries = try Self.fileEntries(in: location)
        if HubModelFormat.detect(paths: entries.map(\.path)) == .gguf {
            try await self.init(localGGUF: location)
            return
        }
        try self.init(localDirectory: location, names: names, entries: entries)
    }

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
    /// - Parameters:
    ///   - directory: The absolute path of the model folder.
    ///   - names: The names at the top of the folder.
    ///   - entries: Every file under the folder, with its size.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the
    ///   folder lacks sizing inputs as ``init(raw:repo:)`` describes, or
    ///   `config.json` cannot be read.
    private init(localDirectory directory: URL, names: [String], entries: [TreeEntry]) throws {
        let configURL = directory.appending(path: Self.configFileName, directoryHint: .notDirectory)
        let configJSON = names.contains(Self.configFileName) ? try Data(contentsOf: configURL) : nil
        try self.init(
            entries: entries, format: HubModelFormat.detect(paths: names),
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
