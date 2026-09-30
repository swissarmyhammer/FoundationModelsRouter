import Foundation
import InMemoryTracing
import Logging
import TelemetryTestSupport
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises task ^ffkvyj8, rule 8 of the OpenTelemetry design of
/// 2026-09-28 (hang detection): a span that can suspend for a long time also
/// writes one "enter" log record when it starts.
///
/// A tracing backend exports a span only when the span ends, so a call that
/// hangs gives no span. The "enter" record is exported at once, so a hung
/// submission, load or resolve shows in the logs. The record has the format
/// of the record of `TracedCall` of FoundationModelsExtras: the message
/// `enter <span name>`, and the W3C ids of the span under `trace.id` and
/// `span.id`. The span writes nothing when it ends.
///
/// Each test runs in a `TelemetryCapture`, whose tracer injects W3C
/// `traceparent` values, so each record holds the ids of its span and the
/// test matches each record to its span. The admission job of a resolve and
/// the pump of a session run on tasks of their own, where the capture of the
/// test does not reach, so the router and the session get the logger of the
/// capture as their explicit logger, and the router gets the tracer of the
/// capture as its explicit tracer.
@Suite("Enter records", .timeLimit(.minutes(1)))
struct EnterRecordTests {
    /// The text before the span name in the message of an "enter" record, as
    /// `TracedCall` of FoundationModelsExtras writes it.
    private static let enterPrefix = "enter "

    /// The metadata key of the W3C trace id of the span of a record.
    private static let traceIDKey = "trace.id"

    /// The metadata key of the W3C span id of the span of a record.
    private static let spanIDKey = "span.id"

    /// The names of the spans that write an "enter" record.
    private static let enteredSpanNames: Set<String> = [
        RouterTelemetry.SpanName.submission, RouterTelemetry.SpanName.resolve, RouterTelemetry.SpanName.load,
    ]

    /// How many slots one profile resolves, and thus how many models a fresh
    /// router loads.
    private static let slotCount = 3

    /// The prompt every driven answer carries.
    private static let prompt = "drive one answer"

    /// The trace id and the span id of one span.
    private struct SpanIDs: Hashable, CustomStringConvertible {
        /// The W3C trace id.
        let traceID: String

        /// The W3C span id.
        let spanID: String

        var description: String { "trace \(traceID), span \(spanID)" }
    }

    /// Builds a router over the shared stub fixtures that traces to the
    /// tracer of `context` and logs to the logger of `context`.
    ///
    /// - Parameters:
    ///   - context: The capture of the test.
    ///   - cacheDir: The router's per-test cache directory.
    ///   - loader: The model loader the resolve loads through.
    /// - Returns: The router.
    private static func makeRouter(
        in context: TelemetryCapture.Context,
        cacheDir: URL,
        loader: any ModelLoader
    ) async -> Router {
        let router = RouterTestFixtures.makeRouter(cacheDir: cacheDir, loader: loader, tracer: context.tracer)
        await router.useLogger(context.logger)
        return router
    }

    /// The loader that vends `container` for each generation slot and never
    /// fails.
    ///
    /// - Parameter container: The generation container of each slot.
    /// - Returns: The loader.
    private static func succeedingLoader(
        vending container: any LoadedLLMContainer = UndrivenLanguageModelContainer()
    ) -> StubModelLoader {
        StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
    }

    /// Resolves the shared test profile on `router`.
    ///
    /// - Parameter router: The router to resolve against.
    /// - Returns: The resolved, resident profile.
    /// - Throws: Whatever the resolve throws.
    private static func resolve(on router: Router) async throws -> LanguageModelProfile {
        try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
    }

    /// The "enter" records of the capture for the spans named `spanName`, as
    /// the ids that each record holds.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - context: The capture of the test.
    /// - Returns: The ids of each record, in the order of the records. A
    ///   record with no id gives empty ids, which match no span.
    private static func enterRecordIDs(
        of spanName: String,
        in context: TelemetryCapture.Context
    ) -> [SpanIDs] {
        context.logRecords
            .filter { "\($0.message)" == enterPrefix + spanName }
            .map { SpanIDs(traceID: text(of: $0, key: traceIDKey), spanID: text(of: $0, key: spanIDKey)) }
    }

    /// The text of one metadata value of a record.
    ///
    /// - Parameters:
    ///   - record: The log record.
    ///   - key: The metadata key.
    /// - Returns: The text of the value, or an empty string when the record
    ///   has no value under `key`.
    private static func text(of record: TelemetryCapture.LogRecord, key: String) -> String {
        record.metadata[key].map { "\($0)" } ?? ""
    }

    /// The ids of each finished span named `spanName`, in the order the
    /// spans ended.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - context: The capture of the test.
    /// - Returns: The ids of each span.
    private static func finishedSpanIDs(
        of spanName: String,
        in context: TelemetryCapture.Context
    ) -> [SpanIDs] {
        context.spans
            .filter { $0.operationName == spanName }
            .map { SpanIDs(traceID: $0.traceID, spanID: $0.spanID) }
    }

    /// Expects that the spans named `spanName` wrote one "enter" record each,
    /// with the ids of the span, and no other record.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - expectedCount: How many spans of that name the test opened.
    ///   - context: The capture of the test.
    ///   - sourceLocation: The source location that an issue names.
    private static func expectOneEnterRecordForEachSpan(
        named spanName: String,
        count expectedCount: Int,
        in context: TelemetryCapture.Context,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let spans = finishedSpanIDs(of: spanName, in: context)
        let records = enterRecordIDs(of: spanName, in: context)
        #expect(spans.count == expectedCount, sourceLocation: sourceLocation)
        #expect(
            Set(records) == Set(spans) && records.count == spans.count,
            "the enter records \(records) of \(spanName) are not one for each span \(spans)",
            sourceLocation: sourceLocation)
    }

    /// Expects that no "enter" record names a span that the router does not
    /// mark for hang detection.
    ///
    /// - Parameter context: The capture of the test.
    private static func expectNoOtherEnterRecord(in context: TelemetryCapture.Context) {
        let otherRecords = context.logRecords.filter { record in
            let message = "\(record.message)"
            return message.hasPrefix(enterPrefix)
                && !enteredSpanNames.contains(String(message.dropFirst(enterPrefix.count)))
        }
        #expect(otherRecords.isEmpty, "unexpected enter records: \(otherRecords)")
    }

    @Test("a resolve writes one enter record for itself and one for each load, with the ids of each span")
    func resolveAndEachLoadWriteOneEnterRecord() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let dir = RouterTestFixtures.makeTempDir(prefix: "EnterRecordTests")
            defer { try? FileManager.default.removeItem(at: dir) }
            let router = await Self.makeRouter(in: context, cacheDir: dir, loader: Self.succeedingLoader())

            _ = try await Self.resolve(on: router)

            Self.expectOneEnterRecordForEachSpan(named: RouterTelemetry.SpanName.resolve, count: 1, in: context)
            Self.expectOneEnterRecordForEachSpan(
                named: RouterTelemetry.SpanName.load, count: Self.slotCount, in: context)
            Self.expectNoOtherEnterRecord(in: context)
        }
    }

    @Test("a resolve whose load fails still wrote the enter records of the resolve and of that load")
    func failedLoadKeepsItsEnterRecord() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let dir = RouterTestFixtures.makeTempDir(prefix: "EnterRecordTests")
            defer { try? FileManager.default.removeItem(at: dir) }
            // `UnconfiguredModelLoader` throws at load time, so the first load
            // fails and the resolve stops there.
            let router = await Self.makeRouter(in: context, cacheDir: dir, loader: UnconfiguredModelLoader())

            await #expect(throws: ModelLoaderError.self) {
                _ = try await Self.resolve(on: router)
            }

            Self.expectOneEnterRecordForEachSpan(named: RouterTelemetry.SpanName.resolve, count: 1, in: context)
            Self.expectOneEnterRecordForEachSpan(named: RouterTelemetry.SpanName.load, count: 1, in: context)
        }
    }

    @Test("a resolve with no explicit logger writes its enter record on the task of the caller")
    func resolveWithNoExplicitLoggerReachesTheCaller() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let dir = RouterTestFixtures.makeTempDir(prefix: "EnterRecordTests")
            defer { try? FileManager.default.removeItem(at: dir) }
            let router = RouterTestFixtures.makeRouter(
                cacheDir: dir, loader: Self.succeedingLoader(), tracer: context.tracer)

            _ = try await Self.resolve(on: router)

            Self.expectOneEnterRecordForEachSpan(named: RouterTelemetry.SpanName.resolve, count: 1, in: context)
        }
    }

    @Test("each submission writes one enter record, with the ids of its span")
    func eachSubmissionWritesOneEnterRecord() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let dir = RouterTestFixtures.makeTempDir(prefix: "EnterRecordTests")
            defer { try? FileManager.default.removeItem(at: dir) }
            let container = SharedBackendContainer(backend: StubSessionBackend())
            let router = await Self.makeRouter(
                in: context, cacheDir: dir, loader: Self.succeedingLoader(vending: container))
            let profile = try await Self.resolve(on: router)
            let session = profile.standard.makeSession()
            await session.useCaptureLogger(for: context.logger)

            _ = try await session.respond(to: Self.prompt)
            _ = try await session.respond(to: Self.prompt)

            Self.expectOneEnterRecordForEachSpan(named: RouterTelemetry.SpanName.submission, count: 2, in: context)
            Self.expectNoOtherEnterRecord(in: context)
        }
    }

    @Test("a submission whose backend does not return already wrote its enter record")
    func hungSubmissionHasItsEnterRecord() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            let dir = RouterTestFixtures.makeTempDir(prefix: "EnterRecordTests")
            defer { try? FileManager.default.removeItem(at: dir) }
            let backend = HeldSessionBackend()
            let router = await Self.makeRouter(
                in: context, cacheDir: dir,
                loader: Self.succeedingLoader(vending: SharedBackendContainer(backend: backend)))
            let profile = try await Self.resolve(on: router)
            let session = profile.standard.makeSession()
            await session.useCaptureLogger(for: context.logger)

            let answer = Task { try await session.respond(to: Self.prompt) }
            try await backend.entered.wait()

            // The submission waits in the backend: its span is open, and its
            // enter record names that open span.
            let openSpans = context.tracer.activeSpans
                .filter { $0.operationName == RouterTelemetry.SpanName.submission }
                .map { SpanIDs(traceID: $0.spanContext.traceID, spanID: $0.spanContext.spanID) }
            #expect(openSpans.count == 1)
            #expect(Self.finishedSpanIDs(of: RouterTelemetry.SpanName.submission, in: context).isEmpty)
            #expect(Self.enterRecordIDs(of: RouterTelemetry.SpanName.submission, in: context) == openSpans)

            backend.release.signal()
            _ = try await answer.value

            // The end of the span writes no second record.
            Self.expectOneEnterRecordForEachSpan(named: RouterTelemetry.SpanName.submission, count: 1, in: context)
        }
    }
}
