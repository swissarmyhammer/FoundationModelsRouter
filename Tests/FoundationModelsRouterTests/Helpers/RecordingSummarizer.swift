import Foundation

@testable import FoundationModelsRouter

/// A ``CompactionSummarizer`` that records each call it gets and answers
/// every call with one fixed summary.
///
/// A test reads ``prompts`` to learn which text a compaction sent to the
/// summarizer, and ``maxTokens`` to learn the output ceiling of each call.
actor RecordingSummarizer: CompactionSummarizer {
    /// The fixed text every call answers with.
    let summary: String

    /// Every prompt this summarizer got, in order.
    private(set) var prompts: [String] = []

    /// The output ceiling of every call this summarizer got, in order.
    private(set) var maxTokens: [Int] = []

    /// Creates a summarizer that answers every call with `summary`.
    ///
    /// - Parameter summary: The fixed text every call answers with.
    init(summary: String) {
        self.summary = summary
    }

    /// Records `prompt` and `maxTokens`, and answers with ``summary``.
    ///
    /// - Parameters:
    ///   - prompt: The prompt the compaction sent.
    ///   - maxTokens: The ceiling the compaction put on the answer.
    /// - Returns: ``summary``.
    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        prompts.append(prompt)
        self.maxTokens.append(maxTokens)
        return summary
    }
}

/// A ``CompactionSummarizer`` that fails every call.
struct FailingSummarizer: CompactionSummarizer {
    /// The error every call throws.
    struct Failure: Error, Equatable {
        /// The name of the summarizer that failed, so a test can tell two
        /// failures apart.
        let name: String
    }

    /// The name every failure carries.
    let name: String

    /// Throws ``Failure``.
    ///
    /// - Parameters:
    ///   - prompt: The prompt the compaction sent. Not read.
    ///   - maxTokens: The ceiling the compaction put on the answer. Not read.
    /// - Returns: Never returns.
    /// - Throws: ``Failure`` with ``name``.
    func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        throw Failure(name: name)
    }
}
