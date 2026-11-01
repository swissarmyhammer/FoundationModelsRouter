import Foundation
import FoundationModelsExtras

/// The rule that tells a local model path from a Hub repo id.
///
/// A ``ModelRef`` names a folder on the disk when its `repo` has one of three
/// forms: an absolute path (`/models/qwen`), a path under the home folder
/// (`~` or `~/models/qwen`), or a path under the working folder
/// (`./models/qwen`). A Hub repo id (`org/name`) has none of these forms, so
/// the two never mix. A plain relative name such as `models` is a Hub repo id,
/// not a path, even when a folder of that name exists.
///
/// The Extras loaders load a folder when the `repo` of the reference is the
/// absolute path of an existing folder. The router therefore changes the `~`
/// and `./` forms to an absolute path before it sizes or loads a model; see
/// ``resolved(_:home:workingDirectory:)``.
enum LocalModelPath {
    /// The start of an absolute path.
    private static let rootPrefix = "/"

    /// The start of a path under the home folder.
    private static let homePrefix = "~"

    /// The start of a path under the working folder.
    private static let workingDirectoryPrefix = "./"

    /// The folder that a path under the home folder starts from, when the
    /// path continues past `~`.
    private static let homeSeparatorPrefix = "~/"

    /// The folder named by a repo string, or `nil` when the string is a Hub
    /// repo id.
    ///
    /// The folder is not checked for existence. Only the form of the string
    /// decides.
    ///
    /// - Parameters:
    ///   - repo: The `repo` of a ``ModelRef``.
    ///   - home: The home folder. It is the home folder of the user by default.
    ///   - workingDirectory: The folder that `./` starts from. It is the
    ///     working folder of the process by default.
    /// - Returns: The absolute folder of a local path, or `nil` for a Hub repo id.
    static func directory(
        of repo: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    ) -> URL? {
        if repo.hasPrefix(rootPrefix) {
            return URL(filePath: repo, directoryHint: .isDirectory).standardizedFileURL
        }
        if repo == homePrefix {
            return home
        }
        if repo.hasPrefix(homeSeparatorPrefix) {
            return home.appending(path: String(repo.dropFirst(homeSeparatorPrefix.count)), directoryHint: .isDirectory)
                .standardizedFileURL
        }
        if repo.hasPrefix(workingDirectoryPrefix) {
            return URL(filePath: repo, directoryHint: .isDirectory, relativeTo: workingDirectory).standardizedFileURL
        }
        return nil
    }

    /// The same reference with a local path changed to an absolute path.
    ///
    /// A Hub repo id is not changed. The revision is kept, and so is the
    /// drafter, which is resolved the same way.
    ///
    /// - Parameters:
    ///   - ref: The reference to resolve.
    ///   - home: The home folder. It is the home folder of the user by default.
    ///   - workingDirectory: The folder that `./` starts from. It is the
    ///     working folder of the process by default.
    /// - Returns: A reference whose `repo` is the absolute path of the folder,
    ///   or `ref` when it names a Hub repo.
    static func resolved(
        _ ref: ModelRef,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    ) -> ModelRef {
        ModelRef(
            repo: directory(of: ref.repo, home: home, workingDirectory: workingDirectory)?.path ?? ref.repo,
            revision: ref.revision,
            drafter: ref.drafter.map { resolved($0, home: home, workingDirectory: workingDirectory) })
    }
}

extension ProfileDefinition {
    /// The same profile with every local model path changed to an absolute
    /// path, in each slot.
    ///
    /// - Parameters:
    ///   - home: The home folder. It is the home folder of the user by default.
    ///   - workingDirectory: The folder that `./` starts from. It is the
    ///     working folder of the process by default.
    /// - Returns: The profile with resolved references. A Hub repo id is not changed.
    func resolvingLocalModelPaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    ) -> ProfileDefinition {
        func resolve(_ refs: [ModelRef]) -> [ModelRef] {
            refs.map { LocalModelPath.resolved($0, home: home, workingDirectory: workingDirectory) }
        }
        return ProfileDefinition(
            name: name, description: description,
            standard: resolve(standard), flash: resolve(flash), embedding: resolve(embedding),
            context: context)
    }
}
