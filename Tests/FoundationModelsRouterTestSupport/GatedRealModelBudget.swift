/// The per-turn generation budget for the gated real-model suites.
///
/// Both gated test targets read this constant. One shared value prevents drift
/// between the many turn sites.
///
/// The constant is in this module because `swift test` builds one `.xctest` for
/// each test target, and SwiftPM cannot share source between two test targets.
/// ``MetalLibraryTestBootstrap`` is here for the same reason.
public enum GatedRealModelBudget {
    /// The largest number of response tokens one gated turn can generate.
    ///
    /// The gated model always reasons. It writes a `<think>` block first, then
    /// it writes the answer after that block. This ceiling must give space to
    /// the `<think>` block and to the answer.
    ///
    /// A ceiling with space for the answer alone is not sufficient. The
    /// `<think>` block uses all of it, generation stops in the middle of the
    /// reasoning, and the turn records an empty response. An empty response
    /// makes each later check fail: a reply that is not empty, a recalled fact,
    /// a `.response` as the last transcript entry, and a token count that is
    /// more than zero.
    ///
    /// This value is a ceiling, not a target. Generation still stops at the
    /// model's end-of-sequence token, and a turn that stops early costs only
    /// the tokens it generated. A larger ceiling therefore gives space to the
    /// `<think>` block, and it does not make a short turn longer.
    ///
    /// Measurement gives this value. `PropagationProbeIntegrationTests` fails
    /// with `512`: its `responseContent` is empty, and its transcript ends with
    /// `[…, toolCalls, toolOutput, response, reasoning]`. The same test passes
    /// with `4096` in 27 seconds, with the same transcript shape and an answer
    /// that is not empty.
    public static let responseTokenCeiling = 4096
}
