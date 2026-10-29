import FoundationModels

/// What MTP speculative decoding did in one generation call, carried by
/// ``GenerationCallUsage/speculativeDecoding``.
///
/// The MLX executor of `MLXFoundationModels` sends it as metadata on the
/// response entry of each call of a model that names an MTP drafter
/// (``ModelRef/drafter``), and `LanguageModelSession` keeps it in
/// `Transcript.Response.metadata`. A model with no drafter sends none, and its
/// calls carry no outcome. A bench run reads ``speculated`` to prove that MTP
/// ran, and ``fallbackReason`` to learn why it did not.
public struct SpeculativeDecodingOutcome: Sendable, Equatable {
    /// The metadata key of ``speculated``.
    static let speculatedKey = "speculativeDecoding"

    /// The metadata key of ``fallbackReason``.
    static let fallbackReasonKey = "speculativeDecodingFallbackReason"

    /// The metadata key of ``acceptedDraftTokenCount``.
    static let acceptedDraftTokenCountKey = "acceptedDraftTokenCount"

    /// The metadata key of ``draftedTokenCount``.
    static let draftedTokenCountKey = "draftedTokenCount"

    /// Whether the drafter drafted in at least one round of the call.
    public let speculated: Bool

    /// Why the call fell back to plain decode: the name of a
    /// `SpeculativeDecodingFallbackReason` case of MLX, such as
    /// `incompatibleDrafter` or `memoryBudgetExceeded`. `nil` when nothing
    /// fell back.
    public let fallbackReason: String?

    /// The drafted tokens that the target accepted, over every pass of the
    /// call.
    public let acceptedDraftTokenCount: Int

    /// The tokens that the drafter drafted, over every pass of the call.
    public let draftedTokenCount: Int

    /// The part of the drafted tokens that the target accepted, or `nil`
    /// when the drafter drafted none.
    public var acceptanceRate: Double? {
        draftedTokenCount > 0 ? Double(acceptedDraftTokenCount) / Double(draftedTokenCount) : nil
    }

    /// Creates the outcome of one call.
    ///
    /// - Parameters:
    ///   - speculated: Whether the drafter drafted in at least one round.
    ///   - fallbackReason: Why the call fell back to plain decode, or `nil`.
    ///   - acceptedDraftTokenCount: The drafted tokens the target accepted.
    ///   - draftedTokenCount: The tokens the drafter drafted.
    public init(speculated: Bool, fallbackReason: String?, acceptedDraftTokenCount: Int, draftedTokenCount: Int) {
        self.speculated = speculated
        self.fallbackReason = fallbackReason
        self.acceptedDraftTokenCount = acceptedDraftTokenCount
        self.draftedTokenCount = draftedTokenCount
    }

    /// Reads the outcome from the metadata of `response`.
    ///
    /// - Parameter response: The response entry of a call.
    /// - Returns: `nil` when the response carries no ``speculatedKey``, which
    ///   is the case of every call of a model with no drafter.
    init?(response: Transcript.Response) {
        let metadata = response.metadata
        guard let speculated = try? metadata[Self.speculatedKey]?.value(Bool.self) else { return nil }
        self.init(
            speculated: speculated,
            fallbackReason: try? metadata[Self.fallbackReasonKey]?.value(String.self),
            acceptedDraftTokenCount: (try? metadata[Self.acceptedDraftTokenCountKey]?.value(Int.self)) ?? 0,
            draftedTokenCount: (try? metadata[Self.draftedTokenCountKey]?.value(Int.self)) ?? 0)
    }

    /// The outcome of the newest response in `entries` that carries one,
    /// unless an earlier call already took that response.
    ///
    /// A call that ends at a tool call may leave no response entry of its
    /// own. Its newest response is then the response of an earlier call,
    /// whose outcome that call already reported, so the response named by
    /// `takenEntryID` gives nothing.
    ///
    /// - Parameters:
    ///   - entries: The entries the attempt appended, in transcript order.
    ///   - takenEntryID: The id of the response whose outcome the last call
    ///     took, or `nil` when no call took one.
    /// - Returns: The outcome and the id of its response, or `nil`.
    static func newest(
        in entries: some BidirectionalCollection<Transcript.Entry>, after takenEntryID: String?
    ) -> (outcome: SpeculativeDecodingOutcome, entryID: String)? {
        for entry in entries.reversed() {
            guard case .response(let response) = entry, let outcome = SpeculativeDecodingOutcome(response: response)
            else { continue }
            return response.id == takenEntryID ? nil : (outcome, response.id)
        }
        return nil
    }
}

extension SpeculativeDecodingOutcome: CustomStringConvertible {
    /// The words of the outcome for the journal line of the call.
    public var description: String {
        if let fallbackReason {
            return "MTP fell back to plain decode: \(fallbackReason)"
        }
        return "MTP accepted \(acceptedDraftTokenCount) of \(draftedTokenCount) drafted tokens"
    }
}
