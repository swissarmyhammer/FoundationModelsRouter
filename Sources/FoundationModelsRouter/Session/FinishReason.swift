import FoundationModels

/// Why one generate attempt stopped, carried by ``TokenUsage/finishReason``.
///
/// A turn that runs out of output tokens gives text and then stops, as a
/// finished turn does. This value tells the two apart, so a host can report
/// an honest stop reason.
public enum FinishReason: Sendable, Equatable {
    /// The model ended its response itself.
    case completed

    /// The response reached the token ceiling before the model ended it.
    case maxTokens
}

extension FinishReason {
    /// The response-entry metadata key a backend sets to `true` when the
    /// token budget ended before the output was complete.
    ///
    /// The MLX executor of `MLXFoundationModels` sets it when generation
    /// stops inside a reasoning block, and when a guided decode runs out of
    /// budget. `LanguageModelSession` keeps it in `Transcript.Response.metadata`.
    static let incompleteOutputMetadataKey = "incompleteOutput"

    /// Reads the finish reason of one attempt from the transcript entries the
    /// attempt appended and from the output token count of the attempt.
    ///
    /// The attempt ends at the token ceiling when one of these is true:
    ///
    /// - The last `.response` entry carries the `incompleteOutput` metadata.
    ///   Only the last response decides. A truncated generation ends the
    ///   attempt, so a flag on an earlier response that a later response
    ///   follows does not describe how the attempt stopped.
    /// - The attempt made one generation call, and its output token count is
    ///   equal to or more than the ceiling the attempt gave the backend. The
    ///   unconstrained MLX path stops at the ceiling inside the answer text
    ///   and sends no metadata, so the count is the only sign of that stop.
    ///
    /// An attempt that called a tool made more than one generation call, and
    /// its output token count is the sum of all those calls. That sum does not
    /// tell which call stopped, so the count does not decide for such an
    /// attempt. Only the metadata decides.
    ///
    /// - Parameters:
    ///   - entries: The entries the attempt appended, in transcript order.
    ///   - outputTokens: The output token count of the attempt, or `nil` when
    ///     the backend reported no usage.
    ///   - responseTokenCeiling: The ceiling the attempt gave the backend, or
    ///     `nil` when the attempt gave none.
    init(
        turnEntries entries: some BidirectionalCollection<Transcript.Entry>,
        outputTokens: Int?,
        responseTokenCeiling: Int?
    ) {
        let stoppedAtCeiling =
            Self.lastResponseReportsIncompleteOutput(entries)
            || Self.oneCallSpentCeiling(
                entries, outputTokens: outputTokens, responseTokenCeiling: responseTokenCeiling)
        self = stoppedAtCeiling ? .maxTokens : .completed
    }

    /// Whether the last `.response` entry of `entries` carries an
    /// `incompleteOutput` metadata value of `true`.
    ///
    /// - Parameter entries: The entries the attempt appended, in transcript order.
    /// - Returns: `false` when `entries` holds no `.response` entry.
    private static func lastResponseReportsIncompleteOutput(
        _ entries: some BidirectionalCollection<Transcript.Entry>
    ) -> Bool {
        let lastResponse = entries.last { entry in
            guard case .response = entry else { return false }
            return true
        }
        guard case .response(let response) = lastResponse else { return false }
        return reportsIncompleteOutput(response)
    }

    /// Whether the attempt made one generation call and that call spent the
    /// whole ceiling.
    ///
    /// - Parameters:
    ///   - entries: The entries the attempt appended, in transcript order.
    ///   - outputTokens: The output token count of the attempt, or `nil`.
    ///   - responseTokenCeiling: The ceiling the attempt gave the backend, or `nil`.
    /// - Returns: `false` when the count or the ceiling is unknown, when the
    ///   count is below the ceiling, or when the attempt called a tool.
    private static func oneCallSpentCeiling(
        _ entries: some BidirectionalCollection<Transcript.Entry>,
        outputTokens: Int?,
        responseTokenCeiling: Int?
    ) -> Bool {
        guard let outputTokens, let responseTokenCeiling else { return false }
        guard outputTokens >= responseTokenCeiling else { return false }
        return !generationCalledTool(entries)
    }

    /// Whether the generation of the attempt appended a `.toolCalls` entry.
    ///
    /// The generation starts at the last `.prompt` entry. Entries before that
    /// prompt, such as the seeded entries of discovery priming, are not the
    /// output of a generation call.
    ///
    /// - Parameter entries: The entries the attempt appended, in transcript order.
    /// - Returns: `true` when a `.toolCalls` entry follows the last `.prompt`
    ///   entry, or follows the start when there is no `.prompt` entry.
    private static func generationCalledTool(
        _ entries: some BidirectionalCollection<Transcript.Entry>
    ) -> Bool {
        let lastPrompt = entries.lastIndex { entry in
            guard case .prompt = entry else { return false }
            return true
        }
        let generated = lastPrompt.map { entries[$0...] } ?? entries[...]
        return generated.contains { entry in
            guard case .toolCalls = entry else { return false }
            return true
        }
    }

    /// Whether `response` carries an `incompleteOutput` metadata value of `true`.
    ///
    /// - Parameter response: The response entry to read.
    /// - Returns: `true` only for a Boolean `true` under the key.
    private static func reportsIncompleteOutput(_ response: Transcript.Response) -> Bool {
        guard let flag = response.metadata[incompleteOutputMetadataKey] else { return false }
        return (try? flag.value(Bool.self)) ?? false
    }
}
