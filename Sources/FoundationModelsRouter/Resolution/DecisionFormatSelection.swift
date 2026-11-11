import Foundation
import FoundationModelsDecision

/// Selects the prompt format of a decision model (decision D13 of the
/// decision plan).
///
/// The rule: a repository with a `decider_config.json` file uses the decider
/// format with the configuration of that file. A repository with no such file
/// uses the generic format, which works with any instruct model. The fetch of
/// the file is not part of this type.
enum DecisionFormatSelection {
    /// Gives the prompt format of a decision model.
    ///
    /// - Parameter deciderConfiguration: The contents of the
    ///   `decider_config.json` file of the repository, or `nil` when the
    ///   repository has no such file.
    /// - Returns: A ``DeciderPromptFormat`` with the decoded configuration
    ///   when `deciderConfiguration` is present, else a
    ///   ``GenericPromptFormat``.
    /// - Throws: `DecodingError` when `deciderConfiguration` is not a valid
    ///   `decider_config.json` file.
    static func format(deciderConfiguration: Data?) throws -> any DecisionPromptFormat {
        guard let deciderConfiguration else { return GenericPromptFormat() }
        let configuration = try JSONDecoder().decode(DeciderConfiguration.self, from: deciderConfiguration)
        return DeciderPromptFormat(configuration: configuration)
    }
}
