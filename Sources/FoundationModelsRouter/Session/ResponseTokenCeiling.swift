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

    /// The ceiling to give the backend, as
    /// ``RoutedSessionActor/responseTokenCeiling(requested:contextTokens:)``
    /// derives it, or `nil` when the caller named none and the context is
    /// unknown.
    let resolved: Int?

    /// Resolves the ceiling of a submission.
    ///
    /// - Parameters:
    ///   - requested: The ceiling the caller named, or `nil`.
    ///   - contextTokens: The resolved working context of the session, in tokens.
    init(requested: Int?, contextTokens: Int) {
        self.requested = requested
        self.resolved = RoutedSessionActor.responseTokenCeiling(requested: requested, contextTokens: contextTokens)
    }
}
