import Foundation
import FoundationModelsRouter
import Testing

/// The wall-clock ceiling this suite runs under.
///
/// One minute rather than the shared ``integrationTestBudgetMinutes`` the
/// model-loading suites take: this suite loads no model, touches no GPU, and
/// reads one key path.
private let contextTokensSurfaceTimeLimitMinutes = 1

/// The reach proof for `RoutedLLM.contextTokens` (Ask 3).
///
/// This file imports the Router with a plain `import`, from a package that is
/// not the Router's own. The root test target lives in the Router's package,
/// where a `package` symbol is reachable with a plain `import`, so only this
/// package can prove that a symbol is `public`. The body is the proof: the
/// compiler must type-check `model.contextTokens` as an `Int` and pass it to
/// `TokenBudget.init(limit:)` here. This is the budget the ACP agent builds at
/// `session/new`, before it calls `makeSession`.
///
/// - Parameter model: The resolved generation handle the budget is sized to.
/// - Returns: A budget whose `limit` is the handle's resolved working context.
private func makeSessionBudget(for model: RoutedLLM) -> TokenBudget {
    TokenBudget(limit: model.contextTokens)
}

// MARK: - Suite

/// The public surface a consumer reaches when it sizes a `TokenBudget` to a
/// resolved handle's working context (Ask 3).
///
/// Not gated: the suite loads no model and touches no GPU, so it needs neither
/// the target-wide permit nor the metallib bootstrap.
@Suite(
    "Ask 3 surface: RoutedLLM.contextTokens is public",
    .timeLimit(.minutes(contextTokensSurfaceTimeLimitMinutes))
)
struct RoutedModelContextTokensSurfaceTests {
    @Test("a plain import reads RoutedLLM.contextTokens as an Int and sizes TokenBudget(limit:) from it")
    func contextTokensReachesTokenBudgetFromAPlainImport() {
        // The compiler is the assertion. Both bindings type-check only when
        // `contextTokens` is `public` and is an `Int`. No hermetic test can
        // construct a `RoutedLLM`, so the builder is bound, never called.
        let contextTokens: KeyPath<RoutedLLM, Int> = \.contextTokens
        let buildBudget: (RoutedLLM) -> TokenBudget = makeSessionBudget(for:)

        #expect(contextTokens == \RoutedLLM.contextTokens)
        _ = buildBudget
    }
}
