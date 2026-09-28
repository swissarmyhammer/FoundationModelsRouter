/// The token ceiling a submission gives its backend, and the ceiling the caller named.
///
/// The backend reads ``resolved``. The retry after a context overflow reads
/// ``requested``: when the caller named a ceiling, the retry compacts to the
/// room the submission needs, and when the caller named none, the retry compacts to
/// the configured target (see ``OverflowRetryTarget``). The resolved value
/// alone cannot tell the two cases apart, because a caller can name a ceiling
/// equal to the window.
struct ResponseTokenCeiling: Sendable, Equatable {
    /// The ceiling the caller named, in tokens, or `nil` when the caller named none.
    let requested: Int?

    /// The ceiling to give the backend: the ceiling the caller named, or else
    /// the smaller of the ceiling that
    /// ``RoutedSessionActor/responseTokenCeiling(requested:contextTokens:)``
    /// derives from the context and the pass token limit in force
    /// (``RepetitionDetection/passTokenLimitInForce``). It is `nil` when the
    /// caller named none, the context is unknown, and no limit is in force.
    let resolved: Int?

    /// Resolves the ceiling of a submission.
    ///
    /// - Parameters:
    ///   - requested: The ceiling the caller named, or `nil`.
    ///   - contextTokens: The resolved working context of the session, in tokens.
    ///   - repetitionDetection: The repetition detection of the session, whose
    ///     pass token limit bounds a submission with no ceiling from the
    ///     caller (task ^dzw15st).
    init(requested: Int?, contextTokens: Int, repetitionDetection: RepetitionDetection) {
        self.requested = requested
        let fromContext = RoutedSessionActor.responseTokenCeiling(requested: requested, contextTokens: contextTokens)
        self.resolved = Self.bounded(fromContext, requested: requested, by: repetitionDetection.passTokenLimitInForce)
    }

    /// `ceiling` bounded by `limit` when the caller named no ceiling.
    ///
    /// - Parameters:
    ///   - ceiling: The ceiling before the limit, or `nil` when none is known.
    ///   - requested: The ceiling the caller named, or `nil`.
    ///   - limit: The pass token limit in force, or `nil`.
    /// - Returns: `ceiling` when the caller named a ceiling or no limit is in
    ///   force; else the smaller of `ceiling` and `limit`, or `limit` when
    ///   `ceiling` is `nil`.
    private static func bounded(_ ceiling: Int?, requested: Int?, by limit: Int?) -> Int? {
        guard requested == nil, let limit else { return ceiling }
        guard let ceiling else { return limit }
        return min(ceiling, limit)
    }
}
