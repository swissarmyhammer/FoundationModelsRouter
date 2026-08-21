import FoundationModelsRouter
import Testing

/// Gives one gated real-model suite exclusive residency for its whole run,
/// installs the metallib symlink every gated suite needs before it touches the
/// GPU, prints a wall clock, and does whatever teardown the suite's own target
/// asks for as the suite ends.
///
/// ## One trait, two targets
///
/// Both gated real-model test targets carry this trait on every `@Suite` they
/// declare — `FoundationModelsRouterIntegrationTests` through its own
/// `.exclusiveRealModel`, and `FoundationModelsRouterEvalIntegrationTests`
/// through its own `.exclusiveResidentModel(of:)`. The two used to be two
/// types with the same three jobs in them, and the copies were free to drift.
/// The jobs stand here once, and what genuinely differs between the targets is
/// an argument:
///
/// - ``permit`` is each target's OWN value-1 permit, and the two must stay
///   separate. `swift test` builds one `.xctest` for each test target and runs
///   each in its own process, so a permit in one process cannot bound the
///   other, and one shared permit would bound neither.
/// - ``measurement`` says which step carries the clock. The integration target
///   measures each `@Test`, because its suites hold many; the eval target
///   measures the whole suite, because each of its suites holds exactly one
///   `@Test` whose work `.evaluates(...)` runs ahead of the body.
/// - ``measurementLabel`` is each target's own tag, so one `grep` collects one
///   target's whole run.
/// - ``whenSuiteEnds`` is each target's own teardown. The eval target evicts
///   its runner's resident model there; the integration target asks for
///   nothing.
///
/// This type is in this module because `swift test` builds one `.xctest` for
/// each test target and SwiftPM cannot share source between two test targets.
/// ``GatedWallClock``, ``GatedRealModelBudget`` and ``MetalLibraryTestBootstrap``
/// are here for the same reason.
///
/// ## Why all of it sits in one suite-scoped trait
///
/// Each job used to rest on convention: every gated `@Test` body opened by
/// reading its target's permit, which took the permit and — through that
/// property's initializer — installed the symlink. Twenty test bodies all
/// remembered to, and nothing enforced it. A new gated `@Test` written without
/// that line did not fail an assertion: mlx-swift cannot find its shader
/// library under a plain `swift test` until the symlink exists, so the first
/// GPU-device `MLXArray` evaluation aborted the whole test process, taking
/// every other suite's results with it, under an error naming mlx rather than
/// the missing line. A `SuiteTrait` written once per `@Suite` cannot be
/// forgotten by a test the suite later gains.
///
/// The same argument covers the measurement and the teardown. A suite that
/// gains a test gains the measurement with it, and a body that forgets the line
/// cannot go unmeasured; a body's own clock would also miss whatever a
/// test-level trait spends ahead of the body. Teardown from inside a `@Test`
/// body gave no guarantee at all: the body does not run when a test-level trait
/// itself throws, and an early `try` inside it skips the rest.
///
/// ## Ordering against test-level traits
///
/// A `SuiteTrait`'s scope opens on the suite's own plan step, before any child
/// step exists, so it encloses every test-level trait no matter where among the
/// suite's own traits it is written. That matters for any trait that reaches
/// the GPU ahead of the `@Test` body — `.evaluates(...)` in the eval target is
/// exactly such a trait, and it runs the entire evaluation, model load
/// included.
///
/// That freedom covers the suite/test boundary only. Written order still
/// decides nesting *within* one declaration's own trait list, where the first
/// trait written is the outermost — so a second suite trait that itself reached
/// the GPU would have to be written after this one on the `@Suite` line to run
/// inside its scope.
public struct GatedRealModelSuiteTrait: SuiteTrait, TestTrait, TestScoping {
    /// Which step of a gated suite's run carries the wall clock.
    public enum Measurement: Sendable {
        /// Each `@Test` of the suite is measured on its own step, and the
        /// printed line names the test.
        ///
        /// The budget is stated per test and Swift Testing charges
        /// `.timeLimit` per test, so this is the measurement that can be read
        /// straight against the budget. It needs ``isRecursive``, and therefore
        /// the `TestTrait` conformance that makes recursion legal.
        case eachTest

        /// The suite's whole run is measured as one step, and the printed line
        /// names the suite.
        ///
        /// For a suite whose single `@Test` has its work done by a test-level
        /// `TestScoping` trait ahead of the body — `.evaluates(...)` is the one
        /// this repository has — the suite's clock IS that test's clock, and a
        /// clock started in the body would measure nothing.
        case wholeSuite
    }

    /// The tag the printed line opens with, in brackets.
    ///
    /// One tag for each target, so a `grep` collects that target's whole run
    /// and the two targets' lines never have to be told apart by hand.
    private let measurementLabel: String

    /// Which step carries the wall clock.
    private let measurement: Measurement

    /// The target-wide value-1 permit the suite holds for its whole duration.
    ///
    /// Taken and released here, never by a `@Test` body: a body that took it
    /// again while its own suite still held it would deadlock on it.
    private let permit: AsyncSemaphore

    /// The teardown the suite's target asks for as the suite ends, or `nil`
    /// when it asks for none.
    ///
    /// It runs however the suite ended — success or throw — and before the
    /// permit is handed back, so the next suite can never acquire the permit
    /// while the previous suite's teardown is still outstanding.
    private let whenSuiteEnds: (@Sendable () async -> Void)?

    /// Creates the trait one gated real-model suite carries.
    ///
    /// - Parameters:
    ///   - measurementLabel: The bracketed tag every printed line of this
    ///     target opens with.
    ///   - measurement: Which step carries the wall clock.
    ///   - permit: The target's own value-1 permit. Each gated target has one
    ///     of its own, because each runs in its own `swift test` process.
    ///   - whenSuiteEnds: Teardown to run as the suite ends, however it ended,
    ///     before the permit is handed back. Defaults to none.
    public init(
        measurementLabel: String,
        measuring measurement: Measurement,
        holding permit: AsyncSemaphore,
        whenSuiteEnds: (@Sendable () async -> Void)? = nil
    ) {
        self.measurementLabel = measurementLabel
        self.measurement = measurement
        self.permit = permit
        self.whenSuiteEnds = whenSuiteEnds
    }

    /// Applies this trait to each `@Test` of the suite as well as to the suite
    /// itself, when — and only when — the clock is per test.
    ///
    /// A `SuiteTrait` is asked for a scope on its own suite's step only, unless
    /// it says so here. The permit wants the suite's step and nothing more, so
    /// ``Measurement/wholeSuite`` leaves this at `false`; a
    /// ``Measurement/eachTest`` clock has to reach each test's own step to
    /// measure it. Measured on 2026-08-20: with this left at `false` the
    /// integration target's trait ran on the suite alone, and the whole target
    /// printed no measurement at all.
    ///
    /// A recursive `SuiteTrait` has to conform to `TestTrait` as well, and that
    /// is a hard requirement rather than a matter of taste: `SuiteTrait` alone
    /// plus this override traps the run inside
    /// `Runner.Plan._recursivelyApplyTraits(_:to:)` on `SIGTRAP`, before any
    /// test starts and with no diagnostic. The conformance is what lets the
    /// plan carry the trait down onto a test.
    public var isRecursive: Bool {
        switch measurement {
        case .eachTest: true
        case .wholeSuite: false
        }
    }

    /// Provides the scope for the steps this trait measures or gates, and for
    /// no test CASE's step.
    ///
    /// A test case's step is left alone in both modes. Under
    /// ``Measurement/eachTest`` no gated `@Test` is parameterized — each holds
    /// exactly one case, so a scope there would print the same measurement a
    /// second time. Under ``Measurement/wholeSuite`` a scope there would take
    /// the same value-1 permit a second time while the suite still held it, and
    /// deadlock.
    ///
    /// - Parameters:
    ///   - test: The test the trait is deciding a scope for.
    ///   - testCase: The test case, if this is a test case's own step rather
    ///     than a suite's or a test's.
    /// - Returns: This trait for a step it measures or gates, or `nil`.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        guard testCase == nil else { return nil }
        switch measurement {
        case .eachTest: return self
        case .wholeSuite: return test.isSuite ? self : nil
        }
    }

    /// Runs one step: the suite itself under the permit, or one of its tests
    /// under a clock.
    ///
    /// The SUITE's step installs the metallib symlink and takes ``permit``.
    /// That scope is its target's single metallib trigger, and the single place
    /// its permit is taken. Under ``Measurement/wholeSuite`` it also carries the
    /// clock, which is started inside the permit so a wait on another suite is
    /// not charged against the measurement.
    ///
    /// A TEST's step — reached under ``Measurement/eachTest`` alone — takes no
    /// permit, because its suite already holds one. It prints the test's own
    /// wall clock however the test ended, so a run past the target's budget
    /// states what it cost as well as failing.
    ///
    /// - Parameters:
    ///   - test: The suite or the test this step belongs to.
    ///   - testCase: Always `nil` here; ``scopeProvider(for:testCase:)``
    ///     provides no per-test-case scope.
    ///   - function: The step's own work.
    /// - Throws: Whatever `function` throws, rethrown once the permit is back,
    ///   the teardown has run, and the measurement is printed.
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        guard test.isSuite else {
            try await measuring(test) {
                try await function()
            }
            return
        }
        _ = MetalLibraryTestBootstrap.ensureColocatedMetallib
        try await permit.withPermit {
            switch measurement {
            case .eachTest:
                try await tearingDown(after: function)
            case .wholeSuite:
                try await measuring(test) {
                    try await tearingDown(after: function)
                }
            }
        }
    }

    /// Runs `work` and prints how long it took, tagged for this target and
    /// naming `test`.
    ///
    /// - Parameters:
    ///   - test: The suite or test the printed line names.
    ///   - work: The step itself.
    /// - Throws: Whatever `work` throws, rethrown once the measurement is
    ///   printed.
    private func measuring(
        _ test: Test,
        _ work: () async throws -> Void
    ) async throws {
        let subjectKey =
            switch measurement {
            case .eachTest: "test"
            case .wholeSuite: "suite"
            }
        try await GatedWallClock.printing(
            label: measurementLabel,
            subject: "\(subjectKey)=\(test.displayName ?? test.name)"
        ) {
            try await work()
        }
    }

    /// Runs the suite's own work, then ``whenSuiteEnds`` however that work
    /// ended, then reports what the work did.
    ///
    /// The outcome is held rather than rethrown straight away, so a suite that
    /// threw still gets its teardown before the error leaves this scope.
    ///
    /// - Parameter function: The suite's own work.
    /// - Throws: Whatever `function` throws, rethrown after the teardown.
    private func tearingDown(
        after function: @Sendable () async throws -> Void
    ) async throws {
        guard let whenSuiteEnds else {
            try await function()
            return
        }
        let outcome: Result<Void, any Error>
        do {
            try await function()
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await whenSuiteEnds()
        try outcome.get()
    }
}
