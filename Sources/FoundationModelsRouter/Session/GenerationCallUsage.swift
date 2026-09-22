import Foundation

/// What one generation call left in the transcript when it ended.
public enum GenerationCallEntryKind: String, Sendable, Equatable, Codable {
    /// The call ended with response text. The attempt then ended too.
    case text

    /// The call ended with a tool call. The session ran the tool and made
    /// one more generation call in the same attempt.
    case toolCall
}

/// The measured usage of one generation call inside one generate attempt,
/// carried by ``SessionEvent/generationCall(_:)``.
///
/// An attempt that calls a tool makes more than one generation call. The
/// ``TokenUsage`` of the attempt sums those calls, so it cannot tell a model
/// that generated for a long time from a context that filled up. One of these
/// values describes one call alone.
public struct GenerationCallUsage: Sendable, Equatable {
    /// The tokens the call fed the model: the whole context of the call.
    public let tokensIn: Int

    /// The tokens the call generated.
    public let tokensOut: Int

    /// Why the call stopped. ``FinishReason/maxTokens`` when the call spent
    /// its token ceiling, ``FinishReason/completed`` when the model ended it.
    public let finishReason: FinishReason

    /// What the call left in the transcript.
    public let entryKind: GenerationCallEntryKind

    /// The measured context after the call, as a fraction of the working
    /// context of the session. The numerator is ``contextTokens``.
    public let contextFill: Double

    /// The measured context after the call, in tokens: the fed tokens and the
    /// generated tokens together.
    public var contextTokens: Int {
        tokensIn + tokensOut
    }

    /// Creates the usage of one generation call.
    ///
    /// - Parameters:
    ///   - tokensIn: The tokens the call fed the model.
    ///   - tokensOut: The tokens the call generated.
    ///   - finishReason: Why the call stopped.
    ///   - entryKind: What the call left in the transcript.
    ///   - contextFill: The measured context after the call, as a fraction of
    ///     the working context.
    public init(
        tokensIn: Int,
        tokensOut: Int,
        finishReason: FinishReason,
        entryKind: GenerationCallEntryKind,
        contextFill: Double
    ) {
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.finishReason = finishReason
        self.entryKind = entryKind
        self.contextFill = contextFill
    }
}

extension GenerationCallUsage: CustomStringConvertible {
    /// One line that names every field, for the run journal.
    public var description: String {
        "fed \(tokensIn) tokens, generated \(tokensOut) tokens, \(stopDescription), "
            + "left \(entryDescription), context \(contextTokens) tokens"
    }

    /// The words for ``finishReason``.
    private var stopDescription: String {
        switch finishReason {
        case .completed:
            return "ended by the model"
        case .maxTokens:
            return "stopped at the token ceiling"
        }
    }

    /// The words for ``entryKind``.
    private var entryDescription: String {
        switch entryKind {
        case .text:
            return "text"
        case .toolCall:
            return "a tool call"
        }
    }
}
