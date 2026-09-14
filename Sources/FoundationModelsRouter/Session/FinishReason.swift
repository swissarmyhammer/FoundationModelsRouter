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
    /// attempt appended.
    ///
    /// Only the last `.response` entry decides. A truncated generation ends
    /// the attempt, so a flag on an earlier response that a later response
    /// follows does not describe how the attempt stopped.
    ///
    /// - Parameter entries: The entries the attempt appended, in transcript order.
    init(turnEntries entries: some BidirectionalCollection<Transcript.Entry>) {
        let lastResponse = entries.last { entry in
            guard case .response = entry else { return false }
            return true
        }
        guard case .response(let response) = lastResponse,
            Self.reportsIncompleteOutput(response)
        else {
            self = .completed
            return
        }
        self = .maxTokens
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
