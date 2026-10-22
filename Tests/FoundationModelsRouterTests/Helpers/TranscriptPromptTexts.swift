import FoundationModels

@testable import FoundationModelsRouter

/// The read of the prompt texts of a ``Transcript`` that the suites which
/// examine what a session gave the model (`AgentMessagePromptTextTests`,
/// `PromptHookTests`, `RouterSessionDirectoryLauncherTests`,
/// `ReasoningTokenLimitTests` and others) share.
extension Transcript {
    /// The text of every `.prompt` entry of this transcript, in order: the
    /// content of the text segments of each prompt, joined with no separator
    /// (``TranscriptEntryMapper/flattenedText(_:)``).
    var promptTexts: [String] {
        compactMap { entry in
            guard case .prompt(let prompt) = entry else { return nil }
            return TranscriptEntryMapper.flattenedText(prompt)
        }
    }
}
