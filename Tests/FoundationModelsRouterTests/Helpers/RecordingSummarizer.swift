import Foundation

@testable import FoundationModelsRouter

/// A ``CompactionSummarizer`` that records each prompt it gets and answers
/// every call with one fixed summary.
///
/// A test reads ``prompts`` to learn which text a fold sent to the
/// summarizer, and which text it did not send.
actor RecordingSummarizer: CompactionSummarizer {
    /// The fixed text every call answers with.
    let summary: String

    /// Every prompt this summarizer got, in order.
    private(set) var prompts: [String] = []

    /// Creates a summarizer that answers every call with `summary`.
    ///
    /// - Parameter summary: The fixed text every call answers with.
    init(summary: String) {
        self.summary = summary
    }

    /// Records `prompt` and answers with ``summary``.
    ///
    /// - Parameters:
    ///   - prompt: The prompt the fold sent.
    ///   - maxTokens: The ceiling the fold put on the answer. Not read.
    /// - Returns: ``summary``.
    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        prompts.append(prompt)
        return summary
    }
}
