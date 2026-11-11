import Foundation
import FoundationModelsDecision
import FoundationModelsExtras

/// Gives the prompt format of a decision model from the `decider_config.json`
/// file of its repository (decision D13 of the decision plan).
///
/// The pool downloads only the GGUF file of a decision model, so this type
/// reads the configuration file through the ``MetadataSource`` that also gave
/// the tree listing of the repository. The tree listing tells whether the
/// file is there (``RepoMetadata/deciderConfigurationByteCount``), so a
/// repository with no such file costs no read. ``DecisionFormatSelection``
/// then turns the bytes of the file into the format.
enum DecisionFormatLoader {
    /// Gives the prompt format of a decision model.
    ///
    /// A reference to a local model folder (see ``LocalModelPath``) reads the
    /// file from the folder, with no call to `source`. A reference to a Hub
    /// repository reads the whole file at the revision of the reference.
    ///
    /// An error is an error of the decision slot only: the caller logs it and
    /// uses its fallback. It never stops the resolve of the profile.
    ///
    /// - Parameters:
    ///   - ref: The reference of the decision model.
    ///   - metadata: The metadata of `ref`, which records the
    ///     `decider_config.json` file at the root of the repository.
    ///   - source: The metadata source that reads the file of a Hub repository.
    /// - Returns: A ``DeciderPromptFormat`` with the configuration of the file
    ///   when the repository has the file, else a ``GenericPromptFormat``.
    /// - Throws: The error of the read of the file, or `DecodingError` when
    ///   the file is not a valid `decider_config.json` file.
    static func format(
        for ref: ModelRef, metadata: RepoMetadata, source: any MetadataSource
    ) async throws -> any DecisionPromptFormat {
        guard let byteCount = metadata.deciderConfigurationByteCount else {
            return try DecisionFormatSelection.format(deciderConfiguration: nil)
        }
        let configuration = try await deciderConfiguration(of: ref, byteCount: byteCount, source: source)
        return try DecisionFormatSelection.format(deciderConfiguration: configuration)
    }

    /// Reads the whole `decider_config.json` file of a repository.
    ///
    /// - Parameters:
    ///   - ref: The reference of the decision model.
    ///   - byteCount: The size of the file, from the tree listing.
    ///   - source: The metadata source that reads the file of a Hub repository.
    /// - Returns: The bytes of the file.
    /// - Throws: The error of the read.
    private static func deciderConfiguration(
        of ref: ModelRef, byteCount: Int64, source: any MetadataSource
    ) async throws -> Data {
        let fileName = RepoMetadata.deciderConfigurationFileName
        if let directory = LocalModelPath.directory(of: ref.repo) {
            return try Data(contentsOf: directory.appending(path: fileName, directoryHint: .notDirectory))
        }
        // A malformed listing can give a negative size. The clamp keeps the
        // range valid; the empty read then fails the decode.
        let length = Int(clamping: max(byteCount, 0))
        return try await source.fetchFileBytes(
            repo: ref.repo, revision: ref.revision, path: fileName, range: 0..<length)
    }
}
