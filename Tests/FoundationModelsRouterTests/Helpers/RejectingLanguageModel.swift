import FoundationModels
@testable import FoundationModelsRouter
import MLXLMCommon
import Synchronization

/// The transcripts a ``RejectingLanguageModel`` was handed, one for each
/// generation call, in call order.
///
/// A class behind a lock, because the SDK generates on a task of its own while
/// the test reads the log on the task that drove the answer. It is `Hashable` by
/// identity, so it can be part of the executor cache key.
final class RejectingModelLog: Sendable, Hashable {
    /// The text of each transcript seen so far, one array for each call.
    private let transcripts: Mutex<[[String]]> = Mutex([])

    /// The text of the transcript of each generation call, in call order. Each
    /// element holds the text of every text segment of that transcript.
    var transcriptTexts: [[String]] {
        transcripts.withLock { $0 }
    }

    /// Records the transcript of one generation call.
    ///
    /// - Parameter transcript: The transcript the call was handed.
    /// - Returns: The zero-based position of this call in the log.
    func record(transcript: Transcript) -> Int {
        let texts = transcript.flatMap(Self.texts(of:))
        return transcripts.withLock { transcripts in
            transcripts.append(texts)
            return transcripts.count - 1
        }
    }

    /// The content of every text segment of `entry`, in order.
    ///
    /// - Parameter entry: One transcript entry.
    /// - Returns: The text contents. A tool-calls entry and a reasoning entry
    ///   give none: the rejection note never goes into either kind.
    private static func texts(of entry: Transcript.Entry) -> [String] {
        let segments: [Transcript.Segment]
        switch entry {
        case .instructions(let instructions): segments = instructions.segments
        case .prompt(let prompt): segments = prompt.segments
        case .toolOutput(let output): segments = output.segments
        case .response(let response): segments = response.segments
        case .toolCalls, .reasoning: segments = []
        @unknown default: segments = []
        }
        return segments.compactMap { segment in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
    }

    /// Two logs are equal only when they are the same log.
    static func == (lhs: RejectingModelLog, rhs: RejectingModelLog) -> Bool {
        lhs === rhs
    }

    /// Hashes the identity of the log.
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// A deterministic `LanguageModel` that writes a tool call the parser rejects
/// on its first ``rejectionCount`` generation calls, and then answers.
///
/// A rejected call ends the generation call with `RejectedToolCallError`, as
/// `MLXLanguageModel` does when it cannot parse the tool call the model wrote.
/// Each call records the transcript it was handed, so a test can read what
/// the model saw on each attempt.
struct RejectingLanguageModel: FoundationModels.LanguageModel {
    /// How many generation calls end with a rejected tool call before a call
    /// answers.
    let rejectionCount: Int

    /// The log each generation call writes its transcript into.
    let log: RejectingModelLog

    /// Declares tool calling, the one capability a tool-calling model needs.
    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling])
    }

    /// Builds the executor cache key from the rejection count and the log.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(rejectionCount: rejectionCount, log: log)
    }

    /// The executor that records the transcript and rejects or answers.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by.
        struct Configuration: Sendable, Hashable {
            /// How many generation calls end with a rejected tool call.
            let rejectionCount: Int

            /// The log to write each transcript into.
            let log: RejectingModelLog
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = RejectingLanguageModel

        /// The token count every emitted fragment reports.
        private static let emittedTokenCount = 1

        /// The name of the tool the rejected call names.
        static let rejectedToolName = "runCode"

        /// The raw text of the rejected call. It stands for argument values
        /// that can be sensitive, so a test can prove that no copy of it
        /// reaches the transcript.
        static let rejectedRawText = #"<tool_call>{"name": "runCode", "arguments": "{ \"code\": \"SECRET-ARGUMENT-VALUE\\q\" }"}</tool_call>"#

        /// The safe summary the rejection carries, in the words the MLX parser
        /// uses for a ``RejectedToolCall/Reason/invalidArguments`` rejection.
        private static let rejectionDetail = "The function arguments were not a JSON object."

        /// The rejection every rejecting call ends with.
        static let rejection = RejectedToolCall(
            reason: .invalidArguments,
            format: .json,
            toolName: rejectedToolName,
            rawText: rejectedRawText,
            detail: rejectionDetail
        )

        /// The answer text a call sends when it does not reject.
        static let answerText = "The answer after the retry."

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The rejection count and the log.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Records the transcript, then rejects the call or answers.
        ///
        /// - Parameters:
        ///   - request: The generation request, carrying the transcript.
        ///   - model: The model this executor runs for. Unread.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: `RejectedToolCallError` while the call is one of the
        ///   first ``Configuration/rejectionCount`` calls.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model _: RejectingLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let callIndex = configuration.log.record(transcript: request.transcript)
            guard callIndex >= configuration.rejectionCount else {
                throw RejectedToolCallError(Self.rejection)
            }
            await channel.send(
                .response(action: .appendText(Self.answerText, tokenCount: Self.emittedTokenCount))
            )
        }
    }
}
