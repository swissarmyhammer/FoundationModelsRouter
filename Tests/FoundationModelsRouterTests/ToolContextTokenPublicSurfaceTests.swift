import Foundation
import Testing

import FoundationModelsRouter

/// Exercises ``ToolContext/makeCompletionToken()`` — the one public entry point
/// a package outside this one mints a run's completion token through.
///
/// The import is plain, with no `@testable`, so the compiler is the first
/// assertion here: were that entry point to lose `public`, this file would stop
/// compiling before a single test ran. That is the assertion that matters,
/// because the consumer of this surface lives in another package, where
/// `@testable` is not available to it.
///
/// The mint itself is the internal `SessionMailbox`, which a plain import cannot
/// see. So this suite states only what an outside caller can state: that each
/// token is its own, and that the expression such a caller writes resolves.
@Suite("ToolContext.makeCompletionToken: mint a completion token over the public surface")
struct ToolContextTokenPublicSurfaceTests {
    /// The number of tokens the uniqueness case mints. Well above the two the
    /// contract names, so a mint that repeated itself only now and then — a
    /// clock read without the random low bits, say — is caught as well as one
    /// that answers with a constant.
    private static let mintedTokenCount = 64

    // MARK: - Uniqueness

    @Test("each call mints a token of its own")
    func eachCallMintsADistinctToken() {
        let tokens = (0..<Self.mintedTokenCount).map { _ in ToolContext.makeCompletionToken() }

        #expect(Set(tokens).count == Self.mintedTokenCount)
        #expect(tokens.allSatisfy { !$0.isEmpty })
    }

    // MARK: - The consumer's expression

    @Test("with no context bound, the consumer's expression falls back to a fresh mint")
    func theConsumerExpressionFallsBackToAFreshMint() {
        // The expression a tool outside this package writes, verbatim: take the
        // run the session already tracks when there is one, and mint an identity
        // of one's own when there is not.
        let commandID = ToolContext.current?.completionToken ?? ToolContext.makeCompletionToken()
        let laterCommandID = ToolContext.current?.completionToken ?? ToolContext.makeCompletionToken()

        // Nothing binds the ambient context here, so the fallback is the branch
        // both evaluations took. Asserting that first is what makes the two
        // assertions below statements about the mint rather than about a token
        // some enclosing run supplied.
        #expect(ToolContext.current?.completionToken == nil)
        #expect(!commandID.isEmpty)
        #expect(commandID != laterCommandID)
    }
}
