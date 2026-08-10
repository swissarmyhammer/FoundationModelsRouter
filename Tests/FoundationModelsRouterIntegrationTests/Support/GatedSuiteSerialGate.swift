import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Process-wide mutual exclusion across every gated real-model suite in this
/// target.
///
/// Each suite here is independently `.serialized` (Swift Testing serializes
/// *within* a `@Suite`), but distinct `@Suite` types still run concurrently
/// with each other by default — every gated suite in this target is one of
/// them, and nothing previously stopped them all from resolving/loading real
/// models at the same time. With real ~15-20GB models in the
/// `.standard`/`.flash` slots (replacing the former tiny `SmolLM-135M`
/// placeholder), that concurrency is a real RAM risk. Every gated suite in
/// this target holds this single value-1 permit for its duration, making the
/// whole gated tier serial across files, not just within one.
///
/// The permit covers this target only. `FoundationModelsRouterEvals` is a
/// separate test target — a separate module and a separate `swift test`
/// process — so it cannot see this gate, and its own gated evals are not
/// serialized against these suites.
enum GatedSuiteSerialGate {
    /// The target-wide permit every gated suite holds for its duration.
    ///
    /// Taken and released by ``GatedRealModelSuiteTrait``, never by a `@Test`
    /// body: a body that took it again while its own suite still held it would
    /// deadlock on this value-1 permit.
    static let shared = AsyncSemaphore(value: 1)
}

/// Gives one gated real-model suite exclusive residency for its whole run, and
/// installs the metallib symlink every suite in this target needs before it
/// touches the GPU.
///
/// ## Why both concerns sit in one suite-scoped trait
///
/// Both used to rest on convention: every gated `@Test` body opened by reading
/// ``GatedSuiteSerialGate/shared``, which took the permit and — through that
/// property's initializer — installed the symlink. Twenty test bodies all
/// remembered to, and nothing enforced it. A new gated `@Test` written without
/// that line did not fail an assertion: mlx-swift cannot find its shader
/// library under a plain `swift test` until the symlink exists, so the first
/// GPU-device `MLXArray` evaluation aborted the whole test process, taking
/// every other suite's results with it, under an error naming mlx rather than
/// the missing line. A `SuiteTrait` written once per `@Suite` cannot be
/// forgotten by a test the suite later gains.
///
/// ## Ordering against test-level traits
///
/// A `SuiteTrait`'s scope wraps the suite's entire plan step, so it sits
/// outside every test-level trait whatever order the traits are written in.
/// That matters for any trait that reaches the GPU ahead of the `@Test` body —
/// `.evaluates(...)` in `FoundationModelsRouterEvals` is exactly such a trait,
/// which is why its sibling ``GatedEvalResidencyTrait`` is suite-scoped too.
/// Nothing in this target carries such a trait today; being suite-scoped means
/// nothing here has to.
struct GatedRealModelSuiteTrait: SuiteTrait, TestScoping {
    /// Provides the scope for the suite itself, and for nothing else.
    ///
    /// Stated rather than inherited: a scope provided per test case as well
    /// would take the same value-1 permit a second time while the suite still
    /// held it, and deadlock.
    ///
    /// - Parameters:
    ///   - test: The test the trait is deciding a scope for.
    ///   - testCase: The test case, if `test` is a function rather than a
    ///     suite. Unused — the suite is the only scope this trait provides.
    /// - Returns: This trait when `test` is the suite, or `nil` otherwise.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? self : nil
    }

    /// Installs the metallib symlink, then runs the suite holding
    /// ``GatedSuiteSerialGate/shared``.
    ///
    /// This scope is the whole target's single metallib trigger, and the
    /// single place its permit is taken.
    ///
    /// - Parameters:
    ///   - test: The suite being run.
    ///   - testCase: Always `nil` here; ``scopeProvider(for:testCase:)``
    ///     provides no per-test-case scope.
    ///   - function: The suite's own work.
    /// - Throws: Whatever `function` throws, rethrown once the permit is back.
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        try await GatedSuiteSerialGate.shared.withPermit {
            try await function()
        }
    }
}

extension Trait where Self == GatedRealModelSuiteTrait {
    /// Serializes this suite against every other gated real-model suite in the
    /// target, and installs the metallib symlink before the suite runs.
    ///
    /// - Returns: The trait.
    static var exclusiveRealModel: Self {
        GatedRealModelSuiteTrait()
    }
}
