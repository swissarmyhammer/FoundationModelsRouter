import Foundation
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^jpt37jg: every compaction fold opens one OpenTelemetry span
/// through `swift-distributed-tracing`.
///
/// Both fold paths reach the same span, so both are held to the same contract:
/// the caller-driven ``RoutedSession/compact(prompt:budget:)`` and the
/// automatic fold the auto-compaction budget drives. This suite holds that
/// contract: the operation name, the span kind, the identity attributes, the
/// trigger that asked for the fold, the fold's own token counts, the
/// summarizer tier that actually ran, and the error record on a fold that
/// throws.
///
/// The tier attribute carries the whole of the automatic path's degrade. That
/// path never throws: a failed summarizer tier falls to the next one, and the
/// fold still returns. So a degrade must show as the tier the span names, and
/// never as a failed span — three of the tests below measure exactly that.
///
/// The rule that no attribute carries the caller's own content lives in
/// ``SpanContentSafetyTests``, which names no span and therefore already
/// measures this one.
///
/// Everything runs over stubs — a ``PerSlotModelLoader`` over two
/// ``ConfiguredLLMContainer``s and an `InMemoryTracer` — so the suite needs no
/// network, no GPU and no bootstrapped tracing backend.
@Suite("Compaction tracing")
struct CompactionTracingTests {
    /// The span name every fold opens.
    private static let spanName = "FoundationModelsRouter.compact"

    /// The suite's temp-directory prefix, handed to
    /// ``AutoCompactionFixtures/makeTriggeredSession(budget:tools:summarization:tracer:tempDirPrefix:)``.
    private static let tempDirPrefix = "CompactionTracingTests"

    /// The prompt the turn that triggers an automatic fold carries — the turn
    /// after the warm-up, so its index continues the warm-up's own sequence.
    private static let triggeringPrompt = "turn \(AutoCompactionFixtures.turnCount)"

    /// The one fold span the driven work opened.
    ///
    /// Filtered by name rather than counted over the whole tracer: a warm-up
    /// turn opens a turn span of its own, and an automatic fold runs inside
    /// the very turn whose span encloses it.
    ///
    /// - Parameter tracer: The tracer the driven work reported to.
    /// - Returns: The single finished fold span.
    /// - Throws: When the tracer holds no fold span, or more than one.
    private static func singleFoldSpan(reportedTo tracer: InMemoryTracer) throws -> FinishedInMemorySpan {
        let spans = tracer.finishedSpans.filter { $0.operationName == spanName }
        try #require(spans.count == 1)
        return try #require(spans.first)
    }

    /// The first fold result `events` reported.
    ///
    /// - Parameter events: One turn's events, in production order.
    /// - Returns: The fold the turn ran.
    /// - Throws: When no event reported a fold.
    private static func foldResult(in events: [SessionEvent]) throws -> CompactionResult {
        try #require(
            events.compactMap { event -> CompactionResult? in
                guard case .compaction(let result) = event else { return nil }
                return result
            }.first)
    }

    /// Drains one turn's `streamEvents(to:)` into an array, in production
    /// order.
    ///
    /// - Parameters:
    ///   - session: The session to drive the turn on.
    ///   - prompt: The turn's prompt.
    /// - Returns: Every event the turn produced.
    /// - Throws: Whatever the turn throws.
    private static func drive(_ session: RoutedSession, prompt: String) async throws -> [SessionEvent] {
        var events: [SessionEvent] = []
        for try await event in await session.streamEvents(to: prompt, maxTokens: nil) {
            events.append(event)
        }
        return events
    }

    // MARK: - The caller-driven fold

    @Test("one caller-driven compact opens one internal fold span carrying the documented attributes")
    func callerDrivenFoldOpensOneInternalSpanWithAttributes() async throws {
        let tracer = InMemoryTracer()
        // No budget: the caller's own compact() is then the only fold that
        // runs, so the tracer holds exactly one fold span to read.
        let (session, _, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)

        let result = try await session.compact(budget: AutoCompactionFixtures.fixedBudget)

        let span = try Self.singleFoldSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("session.id") == .string(session.id.description))
        #expect(span.attributes.get("model.ref") == .string("org/std-a"))
        #expect(span.attributes.get("compaction.trigger") == .string("caller"))
        #expect(span.errors.isEmpty)

        // The fixed budget's target sits below the recency floor, so the fold
        // needed the model-assisted stage and the session's own model wrote
        // the summary that applied.
        #expect(result.summarizerModel == "org/std-a")
        #expect(span.attributes.get("compaction.tier") == .string("own-model"))
    }

    @Test("a fold span carries the fold's own before and after token estimates")
    func foldSpanCarriesTheFoldsOwnTokenCounts() async throws {
        let tracer = InMemoryTracer()
        let (session, _, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)

        let result = try await session.compact(budget: AutoCompactionFixtures.fixedBudget)

        let span = try Self.singleFoldSpan(reportedTo: tracer)
        #expect(span.attributes.get("tokens.before") == .int64(Int64(result.tokensBefore)))
        #expect(span.attributes.get("tokens.after") == .int64(Int64(result.tokensAfter)))
        // A fold that shrank nothing would make the two assertions above pass
        // over one number, proving nothing about which is which.
        #expect(result.tokensAfter < result.tokensBefore)
    }

    @Test("a caller-driven fold no summarizer served names the deterministic tier")
    func callerDrivenDeterministicFoldNamesTheDeterministicTier() async throws {
        let tracer = InMemoryTracer()
        let (session, _, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)

        // A target between the recency floor and the full estimate, so
        // TurnTruncation alone lands under it and no summarizer ever runs.
        let result = try await session.compact(
            budget: deterministicFoldBudget(for: AutoCompactionFixtures.expectedWarmUpEntries()))
        #expect(result.summarizerModel == nil)
        #expect(result.tokensAfter < result.tokensBefore)

        let span = try Self.singleFoldSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.trigger") == .string("caller"))
        #expect(span.attributes.get("compaction.tier") == .string("deterministic"))
        #expect(span.errors.isEmpty)
    }

    @Test("a caller-driven fold whose summarizer fails keeps its span, with the error recorded")
    func callerDrivenFoldThatThrowsRecordsTheErrorOnItsSpan() async throws {
        let tracer = InMemoryTracer()
        let (session, standard, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        // The live backend, not the container: the caller's fold builds its
        // summarizer from the backend the session already holds.
        standard.lastBackend?.shouldThrow = true

        await #expect(throws: StubSessionBackend.StubError.boom) {
            _ = try await session.compact(budget: AutoCompactionFixtures.fixedBudget)
        }

        let span = try Self.singleFoldSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.trigger") == .string("caller"))
        #expect(span.errors.count == 1)
    }

    // MARK: - The automatic fold

    @Test("one automatic fold opens one fold span naming the auto trigger and the flash tier")
    @MainActor
    func automaticFoldNamesTheAutoTriggerAndTheFlashTier() async throws {
        let tracer = InMemoryTracer()
        let (session, _, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)

        let events = try await Self.drive(session, prompt: Self.triggeringPrompt)
        let result = try Self.foldResult(in: events)
        #expect(result.summarizerModel == "org/flash-a")

        let span = try Self.singleFoldSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("session.id") == .string(session.id.description))
        #expect(span.attributes.get("model.ref") == .string("org/std-a"))
        #expect(span.attributes.get("compaction.trigger") == .string("auto"))
        #expect(span.attributes.get("compaction.tier") == .string("flash"))
        #expect(span.attributes.get("tokens.before") == .int64(Int64(result.tokensBefore)))
        #expect(span.attributes.get("tokens.after") == .int64(Int64(result.tokensAfter)))
        #expect(span.errors.isEmpty)
    }

    @Test("an automatic fold that degrades to the session's own model says so in the tier, not as a failed span")
    @MainActor
    func automaticFoldDegradedToTheOwnModelTierKeepsACleanSpan() async throws {
        let tracer = InMemoryTracer()
        let (session, standard, flash) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        // Every backend the flash slot vends from now on fails, so the flash
        // tier throws and the fold falls to the session's own model.
        flash.shouldThrow = true
        #expect(standard.lastBackend?.shouldThrow == false)

        let events = try await Self.drive(session, prompt: Self.triggeringPrompt)
        #expect(try Self.foldResult(in: events).summarizerModel == "org/std-a")

        let span = try Self.singleFoldSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.trigger") == .string("auto"))
        #expect(span.attributes.get("compaction.tier") == .string("own-model"))
        #expect(span.errors.isEmpty)
    }

    @Test("an automatic fold that degrades all the way to the deterministic tier says so in the tier, not as a failed span")
    @MainActor
    func automaticFoldDegradedToTheDeterministicTierKeepsACleanSpan() async throws {
        let tracer = InMemoryTracer()
        let (session, standard, flash) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        // Both model-assisted tiers fail, so only the deterministic pipeline
        // is left. The session's own model then cannot serve the triggering
        // turn's own generation either, which is what the turn throws below —
        // the fold itself never throws.
        flash.shouldThrow = true
        standard.lastBackend?.shouldThrow = true

        await #expect(throws: StubSessionBackend.StubError.boom) {
            _ = try await Self.drive(session, prompt: Self.triggeringPrompt)
        }

        let span = try Self.singleFoldSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.trigger") == .string("auto"))
        #expect(span.attributes.get("compaction.tier") == .string("deterministic"))
        #expect(span.errors.isEmpty)
    }

    @Test("a fold with no tracer injected and no backend bootstrapped folds normally")
    func untracedFoldFoldsNormally() async throws {
        let (session, _, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tempDirPrefix: Self.tempDirPrefix)

        let result = try await session.compact(budget: AutoCompactionFixtures.fixedBudget)

        #expect(result.summarizerModel == "org/std-a")
        #expect(result.tokensAfter < result.tokensBefore)
    }
}
