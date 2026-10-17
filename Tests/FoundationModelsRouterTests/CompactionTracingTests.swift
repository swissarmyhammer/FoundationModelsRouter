import Foundation
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^jpt37jg: every compaction opens one OpenTelemetry span
/// through `swift-distributed-tracing`.
///
/// Both compaction paths reach the same span, so both are held to the same contract:
/// the caller-driven ``RoutedSession/compact(prompt:budget:)`` and the
/// automatic compaction the auto-compaction budget drives. This suite holds that
/// contract: the operation name, the span kind, the identity attributes, the
/// trigger that asked for the compaction, the compaction's own token counts, the
/// summarizer tier that actually ran, and the error status and the error type
/// on a compaction that throws.
///
/// The tier attribute names the tier that wrote the applied summary. On both
/// paths a failed flash tier falls to the session's own model, so that
/// degrade shows as the tier the span names and never as a failed span. A
/// compaction that applies no summary writes no tier. When the last tier
/// fails, the span records the type of its error. The answer of an automatic
/// compaction gets the error, and a requested compaction ends with
/// ``SessionEvent/compactionFailed(_:)``.
///
/// The rule that no attribute carries the caller's own content lives in
/// ``TelemetryContentSafetyTests``, which names no span and therefore already
/// measures this one.
///
/// Everything runs over stubs — a ``PerSlotModelLoader`` over two
/// ``ConfiguredLLMContainer``s and an `InMemoryTracer` — so the suite needs no
/// network, no GPU and no bootstrapped tracing backend.
@Suite("Compaction tracing")
struct CompactionTracingTests {
    /// The span name every compaction opens.
    private static let spanName = "FoundationModelsRouter.compact"

    /// The suite's temp-directory prefix, handed to
    /// ``AutoCompactionFixtures/makeTriggeredSession(budget:tools:tracer:samplingMode:tempDirPrefix:)``.
    private static let tempDirPrefix = "CompactionTracingTests"

    /// The prompt of the answer that triggers an automatic compaction — the answer
    /// after the warm-up, so its index continues the warm-up's own sequence.
    private static let triggeringPrompt = "message \(AutoCompactionFixtures.answerCount)"

    /// The one compaction span the driven work opened.
    ///
    /// Filtered by name rather than counted over the whole tracer: a warm-up
    /// answer opens a submission span of its own, and an automatic compaction runs inside
    /// the very answer whose submission span encloses it.
    ///
    /// - Parameter tracer: The tracer the driven work reported to.
    /// - Returns: The single finished compaction span.
    /// - Throws: When the tracer holds no compaction span, or more than one.
    private static func singleCompactionSpan(reportedTo tracer: InMemoryTracer) throws -> FinishedInMemorySpan {
        let spans = tracer.finishedSpans.filter { $0.operationName == spanName }
        try #require(spans.count == 1)
        return try #require(spans.first)
    }

    /// The first compaction result `events` reported.
    ///
    /// - Parameter events: The events of one answer, in production order.
    /// - Returns: The compaction the answer ran.
    /// - Throws: When no event reported a compaction.
    private static func compactionResult(in events: [SessionEvent]) throws -> CompactionResult {
        try #require(
            events.compactMap { event -> CompactionResult? in
                guard case .compaction(let result) = event else { return nil }
                return result
            }.first)
    }

    /// Drains the `streamEvents(to:)` of one answer into an array, in production
    /// order.
    ///
    /// - Parameters:
    ///   - session: The session to drive the answer on.
    ///   - prompt: The prompt of the answer.
    /// - Returns: Every event the answer produced.
    /// - Throws: Whatever the answer throws.
    private static func drive(_ session: any RoutedSession, prompt: String) async throws -> [SessionEvent] {
        var events: [SessionEvent] = []
        for try await event in await session.streamEvents(to: prompt, maxTokens: nil) {
            events.append(event)
        }
        return events
    }

    // MARK: - The caller-driven compaction

    @Test("one caller-driven compaction opens one internal compaction span carrying the documented attributes")
    func callerDrivenCompactionOpensOneInternalSpanWithAttributes() async throws {
        let tracer = InMemoryTracer()
        // No budget: the caller's own compact() is then the only compaction that
        // runs, so the tracer holds exactly one compaction span to read.
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let session = fixture.session

        let result = try await session.compactAndAwait(budget: AutoCompactionFixtures.fixedBudget)

        let span = try Self.singleCompactionSpan(reportedTo: tracer)
        #expect(span.operationName == Self.spanName)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("session.id") == .string(session.id.description))
        #expect(span.attributes.get("model.ref") == .string("org/std-a"))
        #expect(span.attributes.get("compaction.trigger") == .string("caller"))
        #expect(span.errors.isEmpty)

        // The fixed budget's target is under the warm-up transcript, so the
        // compaction made its one call. A requested compaction offers the
        // flash slot first, and the flash slot wrote the summary that applied.
        #expect(result.summarizerModel == "org/flash-a")
        #expect(span.attributes.get("compaction.tier") == .string("flash"))
    }

    @Test("a compaction span carries the compaction's own before and after token estimates")
    func compactionSpanCarriesItsOwnTokenCounts() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let session = fixture.session

        let result = try await session.compactAndAwait(budget: AutoCompactionFixtures.fixedBudget)

        let span = try Self.singleCompactionSpan(reportedTo: tracer)
        #expect(span.attributes.get("tokens.before") == .int64(Int64(result.tokensBefore)))
        #expect(span.attributes.get("tokens.after") == .int64(Int64(result.tokensAfter)))
        // A compaction that shrank nothing would make the two assertions above pass
        // over one number, proving nothing about which is which.
        #expect(result.tokensAfter < result.tokensBefore)
    }

    @Test("a caller-driven compaction that applies no summary writes no tier on its span")
    func callerDrivenCompactionWithNoSummaryWritesNoTier() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let session = fixture.session

        // A target as large as the whole warm-up transcript: the live context
        // is already under it, so no summarizer runs and no summary applies.
        let warmUpTokens = characterCount(of: AutoCompactionFixtures.expectedWarmUpEntries())
        let result = try await session.compactAndAwait(budget: TokenBudget(limit: warmUpTokens, target: 1))
        #expect(result.summarizerTier == nil)
        #expect(result.summarizerModel == nil)
        #expect(result.tokensAfter == result.tokensBefore)

        let span = try Self.singleCompactionSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.trigger") == .string("caller"))
        #expect(span.attributes.get("compaction.tier") == nil)
        #expect(span.errors.isEmpty)
    }

    @Test("a caller-driven compaction whose summarizer fails keeps its span, with the error type recorded")
    func callerDrivenCompactionThatThrowsRecordsTheErrorOnItsSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let (session, standard, flash) = (fixture.session, fixture.standard, fixture.flash)
        // Both summarizer tiers fail. The flash slot vends a failing backend,
        // and the own-model tier builds its summarizer from the live backend
        // of the session, not from the container.
        flash.shouldThrow = true
        standard.lastBackend?.shouldThrow = true

        let thrown = await #expect(throws: CompactionDidNotComplete.self) {
            _ = try await session.compactAndAwait(budget: AutoCompactionFixtures.fixedBudget)
        }
        #expect(thrown?.failure.outcome == .failed(String(describing: StubSessionBackend.StubError.boom)))

        let span = try Self.singleCompactionSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.trigger") == .string("caller"))
        #expect(span.failureType == "\(StubSessionBackend.StubError.self)")
    }

    // MARK: - The automatic compaction

    @Test("one automatic compaction opens one compaction span naming the auto trigger and the flash tier")
    @MainActor
    func automaticCompactionNamesTheAutoTriggerAndTheFlashTier() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let session = fixture.session

        let events = try await Self.drive(session, prompt: Self.triggeringPrompt)
        let result = try Self.compactionResult(in: events)
        #expect(result.summarizerModel == "org/flash-a")

        let span = try Self.singleCompactionSpan(reportedTo: tracer)
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

    @Test("an automatic compaction that degrades to the session's own model says so in the tier, not as a failed span")
    @MainActor
    func automaticCompactionDegradedToTheOwnModelTierKeepsACleanSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let (session, standard, flash) = (fixture.session, fixture.standard, fixture.flash)
        // Every backend the flash slot vends from now on fails, so the flash
        // tier throws and the compaction falls to the session's own model.
        flash.shouldThrow = true
        #expect(standard.lastBackend?.shouldThrow == false)

        let events = try await Self.drive(session, prompt: Self.triggeringPrompt)
        #expect(try Self.compactionResult(in: events).summarizerModel == "org/std-a")

        let span = try Self.singleCompactionSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.trigger") == .string("auto"))
        #expect(span.attributes.get("compaction.tier") == .string("own-model"))
        #expect(span.errors.isEmpty)
    }

    @Test("an automatic compaction whose every tier fails records the error type on its span and writes no tier")
    @MainActor
    func automaticCompactionWhoseEveryTierFailsRecordsTheError() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let (session, standard, flash) = (fixture.session, fixture.standard, fixture.flash)
        // Both summarizer tiers fail. The last tier's failure reaches the
        // caller, and no summary applies.
        flash.shouldThrow = true
        standard.lastBackend?.shouldThrow = true

        await #expect(throws: StubSessionBackend.StubError.boom) {
            _ = try await Self.drive(session, prompt: Self.triggeringPrompt)
        }

        let span = try Self.singleCompactionSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.trigger") == .string("auto"))
        #expect(span.attributes.get("compaction.tier") == nil)
        #expect(span.failureType == "\(StubSessionBackend.StubError.self)")
    }

    // MARK: - The reason and the signal

    @Test("a requested compaction writes its reason and the id of its signal on its span")
    func requestedCompactionSpanCarriesItsReasonAndSignal() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let session = fixture.session

        let signal = session.compact(budget: AutoCompactionFixtures.fixedBudget)
        _ = try await session.awaitTerminal(of: signal)

        let span = try Self.singleCompactionSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.reason") == .string(CompactionReason.requested.rawValue))
        #expect(span.attributes.get("signal.id") == .string(signal.description))
    }

    @Test("an automatic compaction writes its reason and the id of its signal on its span")
    @MainActor
    func automaticCompactionSpanCarriesItsReasonAndSignal() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, tracer: tracer, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let session = fixture.session

        let result = try Self.compactionResult(in: try await Self.drive(session, prompt: Self.triggeringPrompt))

        let span = try Self.singleCompactionSpan(reportedTo: tracer)
        #expect(span.attributes.get("compaction.reason") == .string(CompactionReason.triggerReached.rawValue))
        #expect(span.attributes.get("signal.id") == .string(result.id))
    }

    @Test("a compaction with no tracer injected and no backend bootstrapped compacts normally")
    func untracedCompactionRunsNormally() async throws {
        let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }
        let session = fixture.session

        let result = try await session.compactAndAwait(budget: AutoCompactionFixtures.fixedBudget)

        #expect(result.summarizerModel == "org/flash-a")
        #expect(result.tokensAfter < result.tokensBefore)
    }
}
