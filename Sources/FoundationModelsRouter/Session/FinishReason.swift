import FoundationModels

/// Why one generate attempt stopped, carried by ``TokenUsage/finishReason``.
///
/// A turn that runs out of output tokens gives text and then stops, as a
/// finished turn does. This value tells the two apart, so a host can report
/// an honest stop reason.
public enum FinishReason: Sendable, Equatable {
    /// The model ended its response itself.
    case completed

    /// The last generation call of the attempt spent its whole token ceiling
    /// before the model ended the response.
    case maxTokens

    /// The output ended inside the reasoning before the ceiling.
    ///
    /// The backend marked the output as incomplete, but the last generation
    /// call did not spend its token ceiling, or its count is not known. The
    /// reasoning ends without a close, and the response can be empty. The
    /// stop came from the model or from the engine, not from the ceiling. A
    /// session does not compact after this stop and does not send a
    /// continuation prompt, because more room does not help this output.
    case endedInsideReasoning
}

extension FinishReason {
    /// The response-entry metadata key a backend sets to `true` when the
    /// output ended before it was complete.
    ///
    /// The MLX executor of `MLXFoundationModels` sets it when generation
    /// stops inside a reasoning block, and when a guided decode runs out of
    /// budget. The flag does not tell why the generation stopped: at the
    /// ceiling, or below it at a stop token. `LanguageModelSession` keeps it
    /// in `Transcript.Response.metadata`.
    static let incompleteOutputMetadataKey = "incompleteOutput"

    /// Reads the finish reason of one attempt from the transcript entries the
    /// attempt appended and from the output token counts of the attempt.
    ///
    /// The attempt ends at the token ceiling (``maxTokens``) only when the
    /// last generation call of the attempt spent an output token count equal
    /// to or more than the ceiling the attempt gave the backend. The MLX
    /// executor stops at the ceiling inside the answer text and sends no
    /// metadata, on the unconstrained path and on the tool path, so the count
    /// is the only sign of that stop.
    ///
    /// Otherwise the attempt ends inside the reasoning
    /// (``endedInsideReasoning``) when the last `.response` entry carries the
    /// `incompleteOutput` metadata. Only the last response decides. A
    /// truncated generation ends the attempt, so a flag on an earlier
    /// response that a later response follows does not describe how the
    /// attempt stopped. All other attempts are ``completed``.
    ///
    /// The count of the last call comes from `lastCallOutputTokens`. When the
    /// backend gives no such count, an attempt with one generation call uses
    /// its own output token count, because that one call is the whole attempt.
    /// An attempt that called a tool made more than one call, and its own
    /// count is the sum of all those calls. That sum does not tell which call
    /// stopped, so such an attempt does not end at the ceiling, and only the
    /// metadata then decides.
    ///
    /// - Parameters:
    ///   - entries: The entries the attempt appended, in transcript order.
    ///   - outputTokens: The output token count of the attempt, or `nil` when
    ///     the backend reported no usage.
    ///   - lastCallOutputTokens: The output token count of the last generation
    ///     call, as ``LanguageModelSessionBackend/lastGenerationCallOutputTokenCount()``
    ///     gives it, or `nil` when the backend gives none.
    ///   - responseTokenCeiling: The ceiling the attempt gave the backend, or
    ///     `nil` when the attempt gave none.
    init(
        turnEntries entries: some BidirectionalCollection<Transcript.Entry>,
        outputTokens: Int?,
        lastCallOutputTokens: Int?,
        responseTokenCeiling: Int?
    ) {
        let lastCallTokens = Self.lastCallOutputTokens(
            entries, outputTokens: outputTokens, reportedLastCallTokens: lastCallOutputTokens)
        if Self.lastCallSpentCeiling(lastCallTokens, responseTokenCeiling: responseTokenCeiling) {
            self = .maxTokens
        } else if Self.lastResponseReportsIncompleteOutput(entries) {
            self = .endedInsideReasoning
        } else {
            self = .completed
        }
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

    /// Whether the last generation call of the attempt spent the whole ceiling.
    ///
    /// - Parameters:
    ///   - lastCallTokens: The output token count of the last call, or `nil`.
    ///   - responseTokenCeiling: The ceiling the attempt gave the backend, or `nil`.
    /// - Returns: `false` when the count or the ceiling is unknown, or when the
    ///   count is below the ceiling.
    private static func lastCallSpentCeiling(_ lastCallTokens: Int?, responseTokenCeiling: Int?) -> Bool {
        guard let lastCallTokens, let responseTokenCeiling else { return false }
        return lastCallTokens >= responseTokenCeiling
    }

    /// The output token count of the last generation call of the attempt.
    ///
    /// The count the backend reports is a count of this attempt only when it
    /// is not more than the output token count of the attempt, because the
    /// last call is one part of the attempt. A larger count is of an earlier
    /// generating method, for example when the attempt failed before it
    /// reached the backend, so it does not decide.
    ///
    /// - Parameters:
    ///   - entries: The entries the attempt appended, in transcript order.
    ///   - outputTokens: The output token count of the attempt, or `nil`.
    ///   - reportedLastCallTokens: The count the backend reports for its last
    ///     call, or `nil`.
    /// - Returns: The reported count when it belongs to the attempt. Otherwise
    ///   the output token count of the attempt when the attempt made one
    ///   call, and `nil` when the attempt called a tool or its count is unknown.
    private static func lastCallOutputTokens(
        _ entries: some BidirectionalCollection<Transcript.Entry>,
        outputTokens: Int?,
        reportedLastCallTokens: Int?
    ) -> Int? {
        guard let outputTokens else { return nil }
        if let reportedLastCallTokens, reportedLastCallTokens <= outputTokens {
            return reportedLastCallTokens
        }
        return generationCalledTool(entries) ? nil : outputTokens
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
