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

    /// The part of ``tokensIn`` that the prompt cache of the backend reused,
    /// or `nil` when the backend reports no cache count. The tokens the call
    /// prefilled are ``tokensIn`` minus this count.
    public let tokensCached: Int?

    /// The tokens the call generated.
    public let tokensOut: Int

    /// The time of the prefill of the call: from its start to its first
    /// output token, reasoning included. `nil` when the session saw no output
    /// token of the call, for example on a backend that reports no passes.
    ///
    /// The prefill rate of the call is ``tokensIn`` minus ``tokensCached``,
    /// divided by this time.
    public let timeToFirstToken: Duration?

    /// The time of the decode of the call: from its first output token to its
    /// end. `nil` by the rule of ``timeToFirstToken``. The decode rate of the
    /// call is ``tokensOut`` divided by this time.
    ///
    /// The transcript shows the arguments of a tool call only when the call
    /// ends, so a call whose only output is one tool call has a decode time
    /// near zero.
    public let decodeTime: Duration?

    /// Why the call stopped. ``FinishReason/maxTokens`` when the call spent
    /// its token ceiling, ``FinishReason/endedInsideReasoning`` when its
    /// output ended inside the reasoning before the ceiling, and
    /// ``FinishReason/completed`` when the model ended it.
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
    ///   - tokensCached: The part of `tokensIn` the prompt cache reused, or
    ///     `nil` (the default) when the backend reports no cache count.
    ///   - timeToFirstToken: The time from the start of the call to its first
    ///     output token, or `nil` (the default) when the session saw no such
    ///     token.
    ///   - decodeTime: The time from the first output token of the call to
    ///     its end, or `nil` (the default) when the session saw no such token.
    public init(
        tokensIn: Int,
        tokensOut: Int,
        finishReason: FinishReason,
        entryKind: GenerationCallEntryKind,
        contextFill: Double,
        tokensCached: Int? = nil,
        timeToFirstToken: Duration? = nil,
        decodeTime: Duration? = nil
    ) {
        self.tokensIn = tokensIn
        self.tokensCached = tokensCached
        self.timeToFirstToken = timeToFirstToken
        self.decodeTime = decodeTime
        self.tokensOut = tokensOut
        self.finishReason = finishReason
        self.entryKind = entryKind
        self.contextFill = contextFill
    }
}

extension GenerationCallUsage: CustomStringConvertible {
    /// One line that names every field, for the run journal.
    public var description: String {
        "fed \(tokensIn) tokens\(cachedDescription), generated \(tokensOut) tokens, \(stopDescription), "
            + "left \(entryDescription), context \(contextTokens) tokens"
    }

    /// The words for ``tokensCached``, or nothing when the backend reports no
    /// cache count.
    private var cachedDescription: String {
        tokensCached.map { " (\($0) cached)" } ?? ""
    }

    /// The words for ``finishReason``.
    private var stopDescription: String {
        switch finishReason {
        case .completed:
            return "ended by the model"
        case .maxTokens:
            return "stopped at the token ceiling"
        case .endedInsideReasoning:
            return "ended inside the reasoning before the ceiling"
        case .repeatedLines:
            return "stopped by the session because it repeated its lines"
        case .reasoningTokenLimit:
            return "stopped by the session because its reasoning reached the reasoning token limit"
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
